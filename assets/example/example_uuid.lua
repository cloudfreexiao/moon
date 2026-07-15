local moon = require("moon")
local uuid = require("uuid")

-- Stand-in for a database. In a real service `uuid.dump` results would be
-- written to and loaded from persistent storage.
local fake_db = {
    seqs = nil, ---@type integer[]|nil
    save = function(self, seqs)
        self.seqs = seqs
    end,
    load = function(self)
        return self.seqs
    end,
}

local CHANNEL = 1
local SERVERID = 100

moon.async(function()
    -- First boot: no persisted counters, every type seeds at 1.
    uuid.init(CHANNEL, SERVERID, fake_db:load())

    ------------------------------------------------------------------
    -- 1. Player UID (type 0) and UUID (type >= 1)
    ------------------------------------------------------------------
    local player = uuid.next(0)     -- or simply uuid.next()
    local item = uuid.next(5)       -- UUID of type 5
    local item2 = uuid.next(5, 42)  -- UUID of type 5 with explicit sequence 42

    print("player uid  :", player)
    print("item uuid   :", item)
    print("explicit    :", item2)

    ------------------------------------------------------------------
    -- 2. Decode helpers
    ------------------------------------------------------------------
    print("is_uid(player):", uuid.is_uid(player))  -- true
    print("is_uid(item)  :", uuid.is_uid(item))    -- false
    print("type(item)    :", uuid.type(item))      -- 5
    print("serverid      :", uuid.serverid(player), uuid.serverid(item)) -- 100, 100

    -- split() decodes an id into all its fields at once (channel is 0 for UUIDs).
    local ptyp, psid, pseq, pch = uuid.split(player)
    print(string.format("split(player): type=%d serverid=%d sequence=%d channel=%d",
        ptyp, psid, pseq, pch))
    local ityp, isid, iseq = uuid.split(item)
    print(string.format("split(item)  : type=%d serverid=%d sequence=%d",
        ityp, isid, iseq))

    -- uuid.type on a player UID raises an error; guard with is_uid first.
    local ok, err = pcall(uuid.type, player)
    assert(not ok)
    print("type(player) errors as expected:", err)

    ------------------------------------------------------------------
    -- 3. Persistence round-trip (simulate a restart)
    ------------------------------------------------------------------
    -- Clean-shutdown dump reports the real counters.
    local seqs, pct, sid = uuid.dump(false)
    print(string.format("dump: serverid=%d max_percent=%.6f type0_next=%d type5_next=%d",
        sid, pct, seqs[1], seqs[6]))
    fake_db:save(seqs)

    local before = uuid.next(0)

    -- Re-init with the persisted table simulates a process restart. Each stored
    -- counter is jittered by a random 1000..=10000, so ids resume beyond every
    -- id issued before "restart" (no reuse) without a predictable stride.
    uuid.init(CHANNEL, SERVERID, fake_db:load())
    local after = uuid.next(0)
    print("before restart:", before, " after restart:", after)
    assert(after > before, "restart must not reissue ids")

    moon.exit(0)
end)

------------------------------------------------------------------
-- 4. Periodic persistence (timer-driven) with a safety margin
------------------------------------------------------------------
-- moon.timeout is one-shot; re-arm it to save on an interval. The periodic dump
-- reports counter + margin, so a crash between saves never reissues ids.
local SAVE_INTERVAL = 60 * 1000 -- 60s
local function schedule_save()
    moon.timeout(SAVE_INTERVAL, function()
        local seqs, pct = uuid.dump(true) -- periodic = true
        fake_db:save(seqs)
        if pct > 0.8 then
            moon.error(string.format("uuid space %.1f%% used", pct * 100))
        end
        schedule_save()
    end)
end
schedule_save()

------------------------------------------------------------------
-- 5. Clean shutdown: persist the real counters (no margin, no gaps)
------------------------------------------------------------------
moon.shutdown(function()
    fake_db:save((uuid.dump(false)))
    moon.quit()
end)
