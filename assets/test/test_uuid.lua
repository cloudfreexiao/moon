local moon = require("moon")
local uuid = require("uuid")

local TYPE_MAX          = 1023
local SERVERID_MAX      = 65535
local CHANNEL_MAX       = 255
local SEQUENCE_MAX      = (1 << 37) - 1
local UID_SEQUENCE_MAX  = (1 << 24) - 1
local SEQUENCE_MARGIN   = 10000000
local UID_SEQUENCE_MARGIN = 100000

-- Independent reference decoders, used only to validate `uuid.split`. Every
-- other block relies on `uuid.split` directly.
local function decode_player(uid)
    local channel  = (uid >> 40) & 0xFF
    local serverid = (uid >> 24) & 0xFFFF
    local sequence = uid & 0xFFFFFF
    return channel, serverid, sequence
end

local function decode_uuid(u)
    local typ      = (u >> 53) & 0x3FF
    local serverid = (u >> 37) & 0xFFFF
    local sequence = u & 0x1FFFFFFFFF
    return typ, serverid, sequence
end

do
    -- next before init must error
    local ok = pcall(uuid.next, 0)
    assert(not ok, "next before init should error")
end

do
    -- init argument validation
    assert(not pcall(uuid.init, 0, 100), "channel 0 rejected")
    assert(not pcall(uuid.init, CHANNEL_MAX + 1, 100), "channel too big rejected")
    assert(not pcall(uuid.init, 1, 0), "serverid 0 rejected")
    assert(not pcall(uuid.init, 1, SERVERID_MAX + 1), "serverid too big rejected")
    assert(not pcall(uuid.init, 1, 100, { 1, 2, 3 }), "bad seqs length rejected")
    assert(pcall(uuid.init, 1, 100, {}), "empty seqs accepted")
end

do
    -- player UID layout + monotonic sequence starting at 1
    uuid.init(7, 100)
    local a = uuid.next(0)
    local b = uuid.next() -- default type == 0
    local typA, sidA, seqA, chA = uuid.split(a)
    local typB, sidB, seqB, chB = uuid.split(b)
    assert(typA == 0 and chA == 7 and sidA == 100 and seqA == 1, "first player uid fields")
    assert(typB == 0 and chB == 7 and sidB == 100 and seqB == 2, "second player uid fields")
    assert(b > a, "player uids are increasing")
    assert(uuid.is_uid(a), "player uid is a uid")
    assert(uuid.serverid(a) == 100, "player uid serverid")
    assert((a >> 53) == 0, "player uid high bits clear")
end

do
    -- UUID layout + type/serverid decode
    uuid.init(1, 42)
    local u = uuid.next(5)
    local typ, sid, seq, ch = uuid.split(u)
    assert(typ == 5 and sid == 42 and seq == 1 and ch == 0, "first uuid fields")
    assert(uuid.type(u) == 5, "uuid.type")
    assert(uuid.serverid(u) == 42, "uuid.serverid")
    assert(not uuid.is_uid(u), "uuid is not a player uid")
    assert(u > 0, "uuid stays non-negative")

    -- max type stays within the sign bit
    local top = uuid.next(TYPE_MAX)
    assert(uuid.type(top) == TYPE_MAX, "max type decode")
    assert(top > 0, "max-type uuid stays non-negative")
end

do
    -- type() on a player UID errors; is_uid distinguishes the kinds
    uuid.init(1, 100)
    local player = uuid.next(0)
    assert(not pcall(uuid.type, player), "type() on player uid errors")
    assert(not uuid.is_uid(0), "zero is not a uid")
    -- a uuid with type >= 1 is never a player uid
    assert(not uuid.is_uid(uuid.next(1)), "uuid is not a player uid")
end

do
    -- split() decodes both kinds, matching the manual decode helpers
    uuid.init(7, 100)

    local player = uuid.next(0)
    local ptyp, psid, pseq, pch = uuid.split(player)
    local pc, ps, pq = decode_player(player)
    assert(ptyp == 0, "player split type is 0")
    assert(pch == pc and psid == ps and pseq == pq,
        "player split matches manual decode")

    local u = uuid.next(5)
    local utyp, usid, useq, uch = uuid.split(u)
    local ut, us, uq = decode_uuid(u)
    assert(utyp == ut and usid == us and useq == uq,
        "uuid split matches manual decode")
    assert(uch == 0, "uuid split channel is 0")
end

do
    -- explicit sequence (UUID only) bypasses the counter, range-checked both ends
    uuid.init(1, 100)
    local u = uuid.next(3, 42)
    local typ, _, seq = uuid.split(u)
    assert(typ == 3 and seq == 42, "explicit sequence encoded")

    -- explicit does not advance the counter: auto-issue still starts at 1
    local auto = uuid.next(3)
    assert(select(3, uuid.split(auto)) == 1, "explicit does not advance counter")

    assert(pcall(uuid.next, 1, SEQUENCE_MAX), "explicit at cap ok")
    assert(not pcall(uuid.next, 1, SEQUENCE_MAX + 1), "explicit over cap rejected")
    assert(not pcall(uuid.next, 1, -1), "negative explicit rejected")
end

do
    -- type range validation
    uuid.init(1, 100)
    assert(not pcall(uuid.next, -1), "negative type rejected")
    assert(not pcall(uuid.next, TYPE_MAX + 1), "type over max rejected")
end

do
    -- dump: shape, real vs periodic margin, serverid
    uuid.init(1, 100)
    uuid.next(0); uuid.next(0) -- type 0 counter -> 3
    uuid.next(5)               -- type 5 counter -> 2

    local seqs, pct, sid = uuid.dump(false)
    assert(#seqs == TYPE_MAX + 1, "dump has 1024 entries")
    assert(seqs[1] == 3, "type 0 next value")
    assert(seqs[6] == 2, "type 5 next value")
    assert(sid == 100, "dumped serverid")
    assert(pct >= 0.0 and pct <= 1.0, "percent in range")

    local pseqs = uuid.dump(true)
    assert(pseqs[1] == 3 + UID_SEQUENCE_MARGIN, "player uid periodic margin")
    assert(pseqs[6] == 2 + SEQUENCE_MARGIN, "uuid periodic margin")
end

do
    -- persistence round-trip: restart resumes beyond issued ids, with jitter
    uuid.init(1, 100)
    for _ = 1, 10 do uuid.next(0) end -- issued sequences 1..10, counter -> 11

    local seqs = uuid.dump(false)
    assert(seqs[1] == 11, "counter is next value after 10 issues")

    uuid.init(1, 100, seqs) -- simulate restart with persisted counters
    local resumed = uuid.next(0)
    local _, _, seq = uuid.split(resumed)
    -- start = 11 + jitter(1000..=10000); first issued value is `start`.
    assert(seq >= 11 + 1000 and seq <= 11 + 10000,
        string.format("resumed sequence %d must be jittered beyond 11", seq))
end

print("test_uuid passed")
moon.exit(0)
