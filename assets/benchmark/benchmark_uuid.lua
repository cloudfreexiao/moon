---
--- benchmark_uuid.lua — Throughput/latency benchmark for the native `uuid`.
---
--- Benchmarks id generation (player UID / UUID / explicit sequence) and the
--- decode helpers (type / is_uid / serverid / split), plus a full dump, reporting
--- ops/sec and average per-op latency.
---
--- Run:  moon_rs assets/benchmark/benchmark_uuid.lua [OPS]
---       moon_rs assets/benchmark/benchmark_uuid.lua 5000000
---

local moon = require("moon")
local uuid = require("uuid")

moon.loglevel("INFO")

-- moon_rs moon.args() returns { arg1, arg2, ... } (no script path at [1]).
local args = moon.args()
local OPS  = tonumber(args[1]) or 5000000

local clock = moon.clock
local rows = {}

-- Time `count` invocations of `fn(count)` and record throughput + avg latency.
local function bench(label, count, fn)
    local bt = clock()
    fn(count)
    local elapsed = clock() - bt
    rows[#rows + 1] = {
        label  = label,
        count  = count,
        ms     = elapsed * 1000,
        ops    = count / elapsed,
        avg_ns = (elapsed / count) * 1e9,
    }
    moon.info(string.format("  [%-16s] %10d ops in %8.1f ms  (%12.0f ops/s, %8.1f ns/op)",
        label, count, elapsed * 1000, count / elapsed, (elapsed / count) * 1e9))
end

local function print_results()
    print("\n================================================================")
    print(string.format("  uuid benchmark  (OPS=%d)", OPS))
    print("================================================================")
    local hdr = string.format("%-18s %12s %12s %16s %12s", "op", "count", "total ms", "ops/sec", "avg ns")
    print(hdr)
    print(string.rep("-", #hdr))
    for _, r in ipairs(rows) do
        print(string.format("%-18s %12d %12.1f %16.0f %12.1f",
            r.label, r.count, r.ms, r.ops, r.avg_ns))
    end
    print(string.rep("-", #hdr))
end

-- Player UID space is only 2^24; cap the player-UID loop so it never saturates.
local UID_OPS = math.min(OPS, (1 << 24) - 2)

uuid.init(1, 100)

local sink = 0

-- 1) player UID generation (type 0).
bench("next(player)", UID_OPS, function(count)
    for _ = 1, count do
        sink = sink + uuid.next(0)
    end
end)

-- 2) UUID generation (type 5, 37-bit sequence — never saturates here).
bench("next(uuid)", OPS, function(count)
    for _ = 1, count do
        sink = sink + uuid.next(5)
    end
end)

-- 3) UUID generation with an explicit sequence (bypasses the counter).
bench("next(explicit)", OPS, function(count)
    for j = 1, count do
        sink = sink + uuid.next(5, j)
    end
end)

-- Prepare a batch of ids to decode (kept out of the timed loops).
local sample = uuid.next(5)
local sample_uid = uuid.next(0)

-- 4) uuid.type decode.
bench("type", OPS, function(count)
    for _ = 1, count do
        sink = sink + uuid.type(sample)
    end
end)

-- 5) uuid.is_uid decode.
bench("is_uid", OPS, function(count)
    for _ = 1, count do
        if uuid.is_uid(sample_uid) then sink = sink + 1 end
    end
end)

-- 6) uuid.serverid decode.
bench("serverid", OPS, function(count)
    for _ = 1, count do
        sink = sink + uuid.serverid(sample)
    end
end)

-- 7) uuid.split full decode (returns type, serverid, sequence, channel).
bench("split", OPS, function(count)
    for _ = 1, count do
        local _, _, seq = uuid.split(sample)
        sink = sink + seq
    end
end)

-- 8) full dump (builds a 1024-entry table per call).
local DUMP_OPS = math.max(1, math.floor(OPS / 1000))
bench("dump", DUMP_OPS, function(count)
    for _ = 1, count do
        local _, pct = uuid.dump(true)
        sink = sink + pct
    end
end)

print_results()
-- Keep `sink` observable so the loops can't be optimized away conceptually.
moon.info(string.format("(checksum=%.0f)", sink))

moon.exit(0)
