---@meta
-- IDE annotation file only. Do not require this file at runtime.

--- 64-bit id generator (`require("uuid")`).
---
--- Produces two kinds of non-negative 64-bit ids that share one per-type atomic
--- counter:
--- - **Player UID** (`type == 0`): `channel(8) | serverid(16) | sequence(24)`.
--- - **UUID** (`type` in `1..=1023`): `type(10) | serverid(16) | sequence(37)`.
---
--- `type` lives in the high bits, so a player UID has `(id >> 53) == 0` and needs
--- no dedicated flag bit. Bit 63 is always clear, so every id is a positive
--- Lua integer.
---
--- Call `uuid.init` once during bootstrap before any `uuid.next`.
---@class uuid
local uuid = {}

--- Initialize the generator. Must be called once before `uuid.next`.
---
--- When `seqs` is non-empty, each stored counter is jittered by a random
--- `1000..=10000` before use, so the first ids after a restart do not follow a
--- predictable stride. When `seqs` is absent/nil/empty, every counter seeds at 1.
---
--- Raises a Lua error on `channel`/`serverid` out of range or a `seqs` table
--- whose length is neither 0 nor 1024.
---@param channel integer @ Player-UID channel, must be in 1..=255
---@param serverid integer @ Server id, must be in 1..=65535
---@param seqs? integer[] @ Persisted counters from a previous run: exactly 1024 entries (index 1 = type 0 … index 1024 = type 1023), or an empty table
function uuid.init(channel, serverid, seqs) end

--- Issue the next id.
---
--- - `type == 0` → player UID, advancing the type-0 counter (errors past 2^24-1).
--- - `type` in `1..=1023` → UUID, advancing that type's counter (errors past
---   2^37-1).
---
--- An explicit `sequence` (UUID only) issues an id with that value instead of
--- advancing the counter. It is range-checked to `0..=2^37-1` but bypasses the
--- counter, so it is not reflected in `uuid.dump`; mixing explicit and
--- auto-issued ids for the same type may collide and is the caller's
--- responsibility.
---@param type? integer @ Id type, 0..=1023 (default 0 = player UID)
---@param sequence? integer @ Explicit sequence value (UUID only, i.e. type >= 1)
---@return integer
---@nodiscard
function uuid.next(type, sequence) end

--- Return the `type` field of a UUID. Raises an error for a player UID (which has
--- `type == 0` and is not a UUID) — guard with `uuid.is_uid` first when unsure.
---@param uuid integer
---@return integer
---@nodiscard
function uuid.type(uuid) end

--- Return true iff `value` is a player UID: high bits clear (`type == 0`) and
--- `channel`, `serverid`, and `sequence` all non-zero.
---@param value integer
---@return boolean
---@nodiscard
function uuid.is_uid(value) end

--- Return the embedded `serverid`. Works for both UUIDs and player UIDs.
---@param uuid integer
---@return integer
---@nodiscard
function uuid.serverid(uuid) end

--- Decode an id into its component fields, dispatching on the kind. The first
--- three returns are always meaningful; `channel` is the player-UID channel for
--- a player UID (`type == 0`) and `0` for a UUID (which has no channel field).
---@param value integer
---@return integer type @ Id type (0 for a player UID)
---@return integer serverid @ Embedded server id
---@return integer sequence @ Sequence value
---@return integer channel @ Player-UID channel (0 for a UUID)
---@nodiscard
function uuid.split(value) end

--- Dump the per-type counters for persistence, plus monitoring info.
---
--- When `periodic` is true, each reported counter is advanced by a per-type
--- safety margin (clamped to the field cap) so a crash after the save can never
--- reissue ids — use for timer-driven saves. When false, the real counter is
--- reported — use on clean shutdown.
---
--- Returns:
--- 1. `seqs`: 1024 entries, index 1 = type 0 … index 1024 = type 1023.
--- 2. `max_percent`: highest fill ratio across all types (0.0–1.0).
--- 3. `serverid`: the currently-configured server id.
---@param periodic boolean @ true = periodic save (with margin), false = clean-shutdown save (real counter)
---@return integer[] seqs
---@return number max_percent
---@return integer serverid
---@nodiscard
function uuid.dump(periodic) end

return uuid
