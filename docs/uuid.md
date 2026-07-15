# UUID / Player UID

Implementation: `crates/moon-runtime/src/modules/lua_uuid.rs` (registered as `uuid`).

`uuid` generates two kinds of 64-bit identifiers sharing one per-type atomic counter:

- **Player UID** (`type == 0`) — short, channel-tagged ids for players.
- **UUID** (`type` in `1..=1023`) — wider, type-tagged ids for general entities.

The two are distinguishable **without a dedicated flag bit**: `type` occupies the high bits, so `(uid >> 53) == 0` means it is a player UID.

---

## 1. Bit layout

`type` occupies the high bits so the two kinds are told apart with no dedicated flag bit. Bit 63 is always `0`, so every id is a non-negative `i64`.

**UUID** (`type ∈ 1..=1023`):

| Bit range | Width | Field | Max |
|---|---|---|---|
| 63 | 1 | `0` (sign bit, always clear) | — |
| 53..62 | 10 | `type` | 1023 |
| 37..52 | 16 | `serverid` | 65535 |
| 0..36 | 37 | `sequence` | 2^37 − 1 = **137,438,953,471** |

**Player UID** (`type == 0`):

| Bit range | Width | Field | Max |
|---|---|---|---|
| 48..63 | 16 | `0` (so `(uid >> 53) == 0` holds) | — |
| 40..47 | 8 | `channel` | 255 |
| 24..39 | 16 | `serverid` | 65535 |
| 0..23 | 24 | `sequence` | 2^24 − 1 = **16,777,215** |

**Per-server capacity** (each `serverid` has its own sequence space, per type): a UUID type can issue up to **2^37 − 1 = 137,438,953,471** (~137.4 billion) ids, and the player-UID counter up to **2^24 − 1 = 16,777,215** (~16.7 million) ids. Reaching the cap makes `uuid.next` raise `sequence out of limit`.

Because a player UID tops out at bit 47 and a UUID always has `type ≥ 1` (bit 53 set), the high bits alone tell them apart. `uuid.type()` errors on a player UID; `uuid.is_uid()` returns `true` only for a player UID whose `channel`, `serverid`, and `sequence` are all non-zero.

---

## 2. Counter semantics

`sequence[type]` is the **next value to be assigned** (pre-increment). `uuid.next` atomically hands out the current value and advances the counter — so the first id issued for a freshly-seeded counter of value `N` is `N`. Both id kinds share the same per-type slot; `type 0` is the player-UID counter.

Once a counter reaches its field cap, `uuid.next` refuses further ids (raising `sequence out of limit`) **and stops advancing** — a saturated type never grows the counter unbounded.

`uuid.init` must complete before any actor calls `uuid.next`. `init` publishes `serverid` last with release ordering and `next` reads it with acquire ordering, so a `next` that observes an initialized generator is guaranteed to see the seeded counters; but the caller is still responsible for the init-before-use ordering (call it once in bootstrap).

---

## 3. API

### `uuid.init(channel, serverid, [seqs])`

Initializes the generator. Must be called once before `uuid.next`.

- `channel` (integer) — player-UID channel, must be in `1..=255`.
- `serverid` (integer) — server id, must be in `1..=65535`.
- `seqs` (table, optional) — persisted sequence table from a previous run. Must be empty or have exactly `1024` integer entries (index 1 = type 0, index 2 = type 1, …). Each entry is the previously-dumped counter for that type.

When `seqs` is provided and non-empty, each stored counter is **jittered by a random `1000..=10000`** before being installed as the new starting counter, so the first ids issued after a restart do not follow a predictable stride. When `seqs` is absent/nil/empty, every counter seeds at `1`.

Errors (Lua error raised):

- `channel out of limit`
- `serverid out of limit`
- `sequence table size error, expected 0 or 1024, got <n>`

```lua
-- First boot
uuid.init(1, 100)

-- Restart with persisted counters
local seqs = db:load_uuid_seq()  -- { [1]=.., [2]=.., ... [1024]=.. }
uuid.init(1, 100, seqs)
```

### `uuid.next([type], [sequence])` → integer

Issues the next id.

- `type` (integer, default `0`) — must be in `0..=1023`.
- `sequence` (integer, optional, UUID only) — issue a UUID with an explicit sequence value instead of advancing the counter. Range-checked to `0..=SEQUENCE_MAX` (a negative or oversized value raises `sequence out of limit`). Note: explicit sequences bypass the counter, so they are **not** reflected in `uuid.dump` — mixing explicit and auto-issued ids for the same type can collide, and is the caller's responsibility.

Behavior:

- `type == 0` → player UID. Advances the type-0 counter; errors if it exceeds `2^24 − 1`.
- `type` in `1..=1023` → UUID. Advances that type's counter (or uses the explicit `sequence`); errors if it exceeds `2^37 − 1`.

```lua
local uid  = uuid.next(0)        -- player UID
local id   = uuid.next(5)        -- UUID of type 5
local id2  = uuid.next(5, 42)    -- UUID of type 5, explicit sequence 42
```

### `uuid.type(uuid)` → integer

Returns the `type` field of a UUID. Raises an error if given a player UID (which has `type == 0` and is not a UUID).

### `uuid.is_uid(value)` → boolean

Returns `true` iff `value` is a player UID: high bits clear (`type == 0`) and `channel`, `serverid`, `sequence` all non-zero.

### `uuid.serverid(uuid)` → integer

Returns the embedded `serverid`. Works for both UUIDs (bits 37..52) and player UIDs (bits 24..39).

### `uuid.split(value)` → type, serverid, sequence, channel

Decodes an id into its fields, dispatching on the kind. The first three returns are always meaningful; `channel` is the player-UID channel for a player UID (`type == 0`) and `0` for a UUID (which has no channel field).

```lua
local typ, sid, seq, ch = uuid.split(uuid.next(0))
print(typ, sid, seq, ch)  -- 0  100  1  1

typ, sid, seq, ch = uuid.split(uuid.next(5))
print(typ, sid, seq, ch)  -- 5  100  1  0
```

### `uuid.dump(periodic)` → seqs, max_percent, serverid

Returns the per-type counters for persistence, plus monitoring info.

- `periodic` (boolean) — save mode (see §4).
- `seqs` (table) — `1024` entries, index 1 = type 0 … index 1024 = type 1023.
- `max_percent` (number) — highest fill ratio across all types (`0.0`–`1.0`). For type 0 the ratio is against `2^24`; for others against `2^37`.
- `serverid` (integer) — the currently-configured server id.

```lua
local seqs, pct, sid = uuid.dump(false)
print(sid, pct, seqs[1], seqs[6])
```

---

## 4. Persistence strategy

The generator never blocks on I/O; persistence is driven from Lua via `uuid.dump`.

Two save modes, selected by the `periodic` flag:

| Mode | `periodic` | Reported value | When to use |
|---|---|---|---|
| **Periodic** | `true` | `counter + margin` (clamped to the per-type cap) | Timer-driven DB saves |
| **Clean shutdown** | `false` | actual `counter` | `shutdown` handler |

**Why the margin:** a periodic save persists a value *ahead* of what was actually issued. If the process crashes between periodic saves, the next `init` resumes from `last_saved + jitter` — which is still beyond every id handed out before the crash, so no id is ever reissued. On a clean shutdown the real counter is saved, avoiding needless gaps.

**Per-type margin & cap:** the margin is sized to the field width. UUID types (37-bit sequence) use `10,000,000`; the player-UID counter (type 0, 24-bit sequence, `2^24 − 1 ≈ 16.7M`) uses a smaller `100,000` — the 37-bit margin would overshoot the 24-bit cap and, after a restart, brick player-UID generation. Both the periodic report and the `init` restore are clamped to the counter's own cap (`UID_SEQUENCE_MAX` for type 0, `SEQUENCE_MAX` otherwise).

**Startup:** `init` receives the persisted table and adds a random `1000..=10000` jitter per type. This hides the saved stride from outside observers (e.g. a player cannot infer the server's issuance cadence from a sequence of ids).

```lua
-- Periodic save with margin. moon.timeout is one-shot, so re-arm it each tick.
local function schedule_save()
    moon.timeout(60 * 1000, function()
        db:save_uuid_seq((uuid.dump(true)))
        schedule_save()
    end)
end
schedule_save()

-- Clean shutdown: save actual counters (no margin, no gaps)
moon.shutdown(function()
    db:save_uuid_seq((uuid.dump(false)))
    moon.quit()
end)
```

---

## 5. Decoding helpers summary

| Question | Call |
|---|---|
| Is this a player UID? | `uuid.is_uid(v)` |
| What type is this UUID? | `uuid.type(v)` |
| Which server issued this? | `uuid.serverid(v)` (works on both kinds) |
| All fields at once? | `uuid.split(v)` (works on both kinds) |

Manual decode (equivalent to `uuid.split`, for reference):

```lua
-- Player UID (channel | serverid | sequence)
local channel  = (uid >> 40) & 0xFF
local serverid = (uid >> 24) & 0xFFFF
local sequence =  uid       & 0xFFFFFF

-- UUID (type | serverid | sequence)
local typ      = (u >> 53) & 0x3FF
local serverid = (u >> 37) & 0xFFFF
local sequence =  u        & 0x1FFFFFFFFF  -- 37 bits (2^37 - 1 = 137,438,953,471)
```

---

## 6. Example, tests & benchmark

| Kind | File | Run |
|---|---|---|
| Usage example | `assets/example/example_uuid.lua` | `cargo run --release assets/example/example_uuid.lua` |
| Integration test | `assets/test/test_uuid.lua` | `cargo run --release assets/test/test_uuid.lua` |
| Benchmark | `assets/benchmark/benchmark_uuid.lua` | `cargo run --release assets/benchmark/benchmark_uuid.lua [OPS]` |
| IDE annotations | `lualib/meta/uuid.lua` | (EmmyLua meta, not required at runtime) |

The example demonstrates init, both id kinds, the decode helpers, a persistence round-trip (dump → re-init resumes past every issued id), periodic saving, and a clean-shutdown handler.

The test covers the bit layout, monotonic sequencing, argument/range validation, explicit-sequence bypass, `dump` shape and per-type margins, and the restart round-trip.

**Benchmark (release, indicative — 5M ops on one machine):**

| Op | ops/sec | ns/op |
|---|---|---|
| `next` (player UID) | ~70M | ~14 |
| `next` (UUID) | ~80M | ~12 |
| `next` (explicit sequence) | ~74M | ~14 |
| `type` | ~90M | ~11 |
| `is_uid` | ~89M | ~11 |
| `serverid` | ~84M | ~12 |
| `split` (4 return values) | ~70M | ~14 |
| `dump` (builds a 1024-entry table) | ~0.2M | ~4700 |

Generation and decode are effectively FFI-bound (a single atomic op plus bit twiddling), so throughput is in the tens of millions per second. `dump` is far heavier because it allocates and fills a 1024-entry Lua table each call — keep it on a coarse timer, not the hot path.
