-- etcd v3 client backed by `moon.grpc` + `protobuf`.
--
-- etcd v3 speaks gRPC natively, so this module is a pure-Lua wrapper that
-- reuses the existing `grpc.core` transport (HTTP/2 + tonic `Channel`) and
-- the `protobuf` encode/decode infrastructure.  No additional Rust code
-- is needed.
--
-- Proto descriptor
-- ----------------
-- Compile the etcd proto files into a `FileDescriptorSet` and load it with
-- `protobuf.load(...)` before opening a connection:
--
-- ```bash
-- protoc --include_imports \
--   --descriptor_set_out=assets/example/grpc/etcd.pb \
--   -I api \
--   api/etcdserverpb/rpc.proto \
--   api/mvccpb/kv.proto \
--   api/authpb/auth.proto
-- ```
--
-- Example
-- -------
-- ```lua
-- local fs       = require("fs")
-- local protobuf = require("protobuf")
-- local etcd     = require("moon.db.etcd")
--
-- protobuf.load(fs.read("assets/example/grpc/etcd.pb"))
--
-- local client, err = etcd.connect({ endpoint = "http://127.0.0.1:2379" })
-- assert(client, err)
--
-- -- Put a key
-- local put_resp = client:put("/hello", "world")
--
-- -- Range with prefix
-- local range_resp = client:range("/app/", etcd.prefix_end("/app/"))
-- for _, kv in ipairs(range_resp.kvs or {}) do
--     print(kv.key, kv.value)
-- end
--
-- -- Watch
-- local w <close> = client:watch({
--     key = "/app/",
--     range_end = etcd.prefix_end("/app/"),
--     start_revision = 1,
-- })
-- while true do
--     local resp = w:recv()
--     if not resp then break end
--     for _, ev in ipairs(resp.events or {}) do
--         print((ev.type == 0 and "PUT" or "DELETE"), ev.kv.key)
--     end
-- end
-- ```

local moon = require("moon")
local grpc = require("moon.grpc")

local M = {}

-- Method-path prefixes for each etcd v3 service.
local KV_PREFIX      = "/etcdserverpb.KV/"
local WATCH_PREFIX   = "/etcdserverpb.Watch/"
local LEASE_PREFIX   = "/etcdserverpb.Lease/"
local CLUSTER_PREFIX = "/etcdserverpb.Cluster/"
local MAINT_PREFIX   = "/etcdserverpb.Maintenance/"
local AUTH_PREFIX    = "/etcdserverpb.Auth/"

-- Protobuf message type prefixes (qualified package + message name).
local ETCD_PKG = "etcdserverpb."
local AUTH_PKG = "authpb."

-- ===========================================================================
-- Helpers
-- ===========================================================================

--- Compute the lexicographic end key for prefix-based range queries.
---
--- Given a key prefix `"/app/"`, returns the smallest key that is strictly
--- greater than every key starting with that prefix.  Use the result as
--- `range_end` in `client:range()` or `client:watch()`:
---
--- ```lua
--- local resp = client:range("/app/", etcd.prefix_end("/app/"))
--- ```
---
---@param key string
---@return string
function M.prefix_end(key)
    local len = #key
    if len == 0 then
        return "\0"
    end
    for i = len, 1, -1 do
        local b = key:byte(i)
        if b < 0xFF then
            return key:sub(1, i - 1) .. string.char(b + 1)
        end
    end
    error("etcd: prefix_end: key is all 0xFF bytes")
end

-- ===========================================================================
-- Response types (used by the public API)
-- ===========================================================================

---@alias etcd.Status grpc.Status

---@class etcd.KV
---@field key              string
---@field value            string
---@field create_revision  integer
---@field mod_revision     integer
---@field version          integer
---@field lease            integer

---@class etcd.Event
---@field type     integer  0 = PUT, 1 = DELETE
---@field kv       etcd.KV
---@field prev_kv   etcd.KV?

-- ===========================================================================
-- Internal stream types
-- ===========================================================================

---@class etcd._StreamBase
---@field _stream grpc.Stream
local StreamBase = {}
StreamBase.__index = StreamBase

---@async
function StreamBase:recv()
    return self._stream:recv()
end

function StreamBase:close()
    return self._stream:close()
end

StreamBase.__close = function(self)
    self:close()
end

---@class etcd.WatchStream : etcd._StreamBase
local WatchStream = setmetatable({}, { __index = StreamBase })
WatchStream.__index = WatchStream
WatchStream.__close = StreamBase.__close

---@class etcd.KeepAliveStream : etcd._StreamBase
---@field _lease_id integer
local KeepAliveStream = setmetatable({}, { __index = StreamBase })
KeepAliveStream.__index = KeepAliveStream
KeepAliveStream.__close = StreamBase.__close

--- Send a keep-alive ping (reuses lease_id from creation).
---@return boolean ok
---@return string? err
function KeepAliveStream:send()
    return self._stream:send({ ID = self._lease_id })
end

---@class etcd.SnapshotStream : etcd._StreamBase
local SnapshotStream = setmetatable({}, { __index = StreamBase })
SnapshotStream.__index = SnapshotStream
SnapshotStream.__close = StreamBase.__close

--- Receive the next snapshot chunk.
--- Returns `{ blob = raw_bytes, remaining_bytes = N }`, or `nil` at end.
---@async
---@return table? chunk
---@return string? err
function SnapshotStream:recv()
    return self._stream:recv()
end

-- ===========================================================================
-- Client
-- ===========================================================================

---@class etcd.Client
---@field _conn grpc.Connection
local Client = {}
Client.__index = Client

--- Connect to an etcd cluster.
---
--- The etcd protobuf descriptor **must** already be loaded via
--- `protobuf.load(...)` before calling this function, otherwise the module
--- cannot encode/decode the gRPC payloads.
---
---@async
---@param opts? table
---   `{ endpoint?, name?, connect_timeout?, tls? }`.
---   `endpoint` defaults to `"http://127.0.0.1:2379"`.
---   `name` defaults to `"etcd"`.
---@return etcd.Client? client
---@return string? err
function M.connect(opts)
    opts = opts or {}
    opts.endpoint = opts.endpoint or "http://127.0.0.1:2379"
    opts.name = opts.name or "etcd"
    local conn, err = grpc.connect(opts)
    if not conn then
        return nil, err
    end
    return setmetatable({ _conn = conn }, Client)
end

--- Close (unregister) the named connection.
---@param name? string  defaults to `"etcd"`
function M.close(name)
    return grpc.close(name or "etcd")
end

--- Return the underlying gRPC connection for direct low-level calls.
---@return grpc.Connection
function Client:grpc_connection()
    return self._conn
end

-- ===========================================================================
-- KV service
-- ===========================================================================

--- Range gets the keys in the given range from the key-value store.
---
--- For prefix queries use `etcd.prefix_end(key)` as `range_end`:
--- ```lua
--- local resp = client:range("/app/", etcd.prefix_end("/app/"))
--- for _, kv in ipairs(resp.kvs or {}) do
---     print(kv.key, kv.value)  --> "/app/foo", "/app/bar", ...
--- end
--- ```
---
---@async
---@param key       string    start key (raw bytes)
---@param range_end? string   end key for range query; omit / `""` for exact match
---@param opts?     table     `{ limit?, revision?, sort_order?, sort_target?,
---                            keys_only?, count_only?, serializable?,
---                            min_mod_revision?, max_mod_revision?,
---                            min_create_revision?, max_create_revision?,
---                            timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:range(key, range_end, opts)
    opts = opts or {}
    return self._conn:unary(
        KV_PREFIX .. "Range",
        ETCD_PKG .. "RangeRequest",
        {
            key                  = key,
            range_end            = range_end or "",
            limit                = opts.limit or 0,
            revision             = opts.revision or 0,
            sort_order           = opts.sort_order or 0,    -- NONE=0, ASCEND=1, DESCEND=2
            sort_target          = opts.sort_target or 0,   -- KEY=0, VERSION=1, CREATE=2, MOD=3, VALUE=4
            serializable         = opts.serializable or false,
            keys_only            = opts.keys_only or false,
            count_only           = opts.count_only or false,
            min_mod_revision     = opts.min_mod_revision or 0,
            max_mod_revision     = opts.max_mod_revision or 0,
            min_create_revision  = opts.min_create_revision or 0,
            max_create_revision  = opts.max_create_revision or 0,
        },
        ETCD_PKG .. "RangeResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Put the given key-value into the store.
---
---@async
---@param key    string
---@param value  string
---@param opts?  table  `{ lease?, prev_kv?, ignore_value?, ignore_lease?, timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:put(key, value, opts)
    opts = opts or {}
    return self._conn:unary(
        KV_PREFIX .. "Put",
        ETCD_PKG .. "PutRequest",
        {
            key           = key,
            value         = value,
            lease         = opts.lease or 0,
            prev_kv       = opts.prev_kv or false,
            ignore_value  = opts.ignore_value or false,
            ignore_lease  = opts.ignore_lease or false,
        },
        ETCD_PKG .. "PutResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- DeleteRange deletes keys in the given range.
---
---@async
---@param key       string
---@param range_end? string  range end for range delete; omit for single key
---@param opts?     table    `{ prev_kv?, timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:delete_range(key, range_end, opts)
    opts = opts or {}
    return self._conn:unary(
        KV_PREFIX .. "DeleteRange",
        ETCD_PKG .. "DeleteRangeRequest",
        {
            key       = key,
            range_end = range_end or "",
            prev_kv   = opts.prev_kv or false,
        },
        ETCD_PKG .. "DeleteRangeResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Delete a single key.  Convenience wrapper around `delete_range` that returns
--- the number of deleted keys directly.
---
---@async
---@param key   string
---@param opts? table  `{ prev_kv?, timeout?, metadata? }`
---@return integer? deleted   count of deleted keys, or `nil` on error
---@return etcd.Status? status
function Client:delete(key, opts)
    local resp, status = self:delete_range(key, "", opts)
    if not resp then
        return nil, status
    end
    return resp.deleted
end

--- Txn processes multiple requests in a single atomic transaction.
---
--- A txn is composed of:
--- - `compares`: list of `Compare` messages (see below).
--- - `success` : list of `RequestOp` to execute if all compares pass.
--- - `failure` : list of `RequestOp` to execute otherwise (optional).
---
--- Each `Compare` takes a `result` (EQUAL=0, GREATER=1, LESS=2, NOT_EQUAL=3),
--- a `target` (VERSION=0, CREATE=1, MOD=2, VALUE=3, LEASE=4), a `key`, and
--- one of the `target_union` fields:
---
--- ```lua
--- -- CAS: put /lock only if it does not already exist
--- local resp = client:txn(
---     {{ -- compare
---         result = 0,    -- EQUAL
---         target = 1,    -- CREATE (create_revision)
---         key    = "/lock",
---         create_revision = 0,
---     }},
---     {{ -- success
---         request_put = { key = "/lock", value = "owner-1", lease = lease_id },
---     }},
---     {{ -- failure
---         request_range = { key = "/lock" },
---     }}
--- )
--- if resp.succeeded then
---     print("lock acquired")
--- else
---     local holder = resp.responses[1].response_range.kvs[1]
---     print("held by", holder.value)
--- end
--- ```
---
--- `RequestOp` uses the `request_*` oneof field:
--- - `{ request_range = { key, ... } }`
--- - `{ request_put = { key, value, ... } }`
--- - `{ request_delete_range = { key, ... } }`
--- - `{ request_txn = { compare, success, failure } }`
---
---@async
---@param compares  table[]  list of Compare messages
---@param success   table[]  list of RequestOp to execute on success
---@param failure?  table[]  list of RequestOp to execute on failure (default {})
---@param opts?     table    `{ timeout?, metadata? }`
---@return table? response  `{ succeeded, responses }`
---@return etcd.Status? status
function Client:txn(compares, success, failure, opts)
    opts = opts or {}
    return self._conn:unary(
        KV_PREFIX .. "Txn",
        ETCD_PKG .. "TxnRequest",
        {
            compare = compares,
            success = success,
            failure = failure or {},
        },
        ETCD_PKG .. "TxnResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Compact compacts the event history in the key-value store.
---
---@async
---@param revision  integer  compact up to this revision
---@param physical? boolean  wait until physically applied (default false)
---@param opts?     table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:compact(revision, physical, opts)
    opts = opts or {}
    return self._conn:unary(
        KV_PREFIX .. "Compact",
        ETCD_PKG .. "CompactionRequest",
        {
            revision = revision,
            physical = physical or false,
        },
        ETCD_PKG .. "CompactionResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

-- ===========================================================================
-- Watch service
-- ===========================================================================

--- Watch watches for events happening or that have happened.
--- Returns a `WatchStream` handle — call `:recv()` to receive
--- `WatchResponse` messages, each containing `events` and `created`.
---
--- ```lua
--- local w <close> = client:watch({
---     key = "/app/",
---     range_end = etcd.prefix_end("/app/"),
---     start_revision = rev,
--- })
--- while true do
---     local resp = w:recv()
---     if not resp then break end
---     if resp.created then print("watch created") end
---     for _, ev in ipairs(resp.events or {}) do
---         if ev.type == 0 then print("PUT", ev.kv.key)
---         else print("DELETE", ev.kv.key) end
---     end
--- end
--- ```
---
---@async
---@param create_req table    a `WatchCreateRequest` message:
---   `{ key, range_end?, start_revision?, progress_notify?, filters?,
---      prev_kv?, watch_id?, fragment? }`
---@param opts?      table   `{ timeout?, metadata? }`
---@return etcd.WatchStream? stream
---@return string? err
function Client:watch(create_req, opts)
    local stream, err = self._conn:bidi_stream(
        WATCH_PREFIX .. "Watch",
        ETCD_PKG .. "WatchRequest",
        ETCD_PKG .. "WatchResponse",
        opts
    )
    if not stream then
        return nil, err
    end

    local ok, serr = stream:send({ create_request = create_req })
    if not ok then
        stream:close()
        return nil, serr
    end

    return setmetatable({ _stream = stream }, WatchStream)
end

--- Cancel a watch on an active watch stream.
---
---@param stream   etcd.WatchStream  active watch stream
---@param watch_id integer            watch_id to cancel
---@return boolean ok
---@return string? err
function M.watch_cancel(stream, watch_id)
    return stream._stream:send({ cancel_request = { watch_id = watch_id } })
end

--- Request a progress notification on an active watch stream.
--- The next `WatchResponse` will have `created == false` and an empty
--- `events` list, acting as a heartbeat.
---
---@param stream  etcd.WatchStream  active watch stream
---@return boolean ok
---@return string? err
function M.watch_progress(stream)
    return stream._stream:send({ progress_request = {} })
end

-- ===========================================================================
-- Lease service
-- ===========================================================================

--- LeaseGrant creates a lease with the given TTL.
---
---@async
---@param ttl  integer  TTL in seconds
---@param id?  integer  requested lease ID (0 = server-chosen)
---@param opts? table   `{ timeout?, metadata? }`
---@return table? response  `{ ID, TTL, error, header }`
---@return etcd.Status? status
function Client:lease_grant(ttl, id, opts)
    opts = opts or {}
    return self._conn:unary(
        LEASE_PREFIX .. "LeaseGrant",
        ETCD_PKG .. "LeaseGrantRequest",
        { TTL = ttl, ID = id or 0 },
        ETCD_PKG .. "LeaseGrantResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- LeaseRevoke revokes a lease.  All keys attached to the lease will expire.
---
---@async
---@param id    integer  lease ID
---@param opts? table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:lease_revoke(id, opts)
    opts = opts or {}
    return self._conn:unary(
        LEASE_PREFIX .. "LeaseRevoke",
        ETCD_PKG .. "LeaseRevokeRequest",
        { ID = id },
        ETCD_PKG .. "LeaseRevokeResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- LeaseKeepAlive starts a keep-alive stream for the given lease.
--- Returns a `KeepAliveStream` — call `:send()` to renew and `:recv()` to
--- read the server's response with the new TTL.
---
--- ```lua
--- -- Start keep-alive
--- local ka <close> = client:lease_keep_alive(lease_id)
--- -- The first response arrives after the initial :send
--- local resp = ka:recv()  -- blocks until server sends new TTL
--- print("TTL =", resp.TTL)
--- -- Keep renewing in a loop
--- while true do
---     moon.sleep(ttl // 3 * 1000)
---     ka:send()
---     local resp = ka:recv()
---     if not resp then break end  -- lease revoked
---     print("TTL =", resp.TTL)
--- end
--- ```
---
---@async
---@param lease_id integer
---@param opts?    table  `{ timeout?, metadata? }`
---@return etcd.KeepAliveStream? stream
---@return string? err
function Client:lease_keep_alive(lease_id, opts)
    local stream, err = self._conn:bidi_stream(
        LEASE_PREFIX .. "LeaseKeepAlive",
        ETCD_PKG .. "LeaseKeepAliveRequest",
        ETCD_PKG .. "LeaseKeepAliveResponse",
        opts
    )
    if not stream then
        return nil, err
    end

    local ok, serr = stream:send({ ID = lease_id })
    if not ok then
        stream:close()
        return nil, serr
    end

    return setmetatable({ _stream = stream, _lease_id = lease_id }, KeepAliveStream)
end

--- LeaseTimeToLive retrieves lease information.
---
---@async
---@param id    integer   lease ID
---@param keys? boolean   return keys attached to this lease
---@param opts? table     `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:lease_time_to_live(id, keys, opts)
    opts = opts or {}
    return self._conn:unary(
        LEASE_PREFIX .. "LeaseTimeToLive",
        ETCD_PKG .. "LeaseTimeToLiveRequest",
        { ID = id, keys = keys or false },
        ETCD_PKG .. "LeaseTimeToLiveResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- LeaseLeases lists all existing leases.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response  `{ leases }`
---@return etcd.Status? status
function Client:lease_leases(opts)
    opts = opts or {}
    return self._conn:unary(
        LEASE_PREFIX .. "LeaseLeases",
        ETCD_PKG .. "LeaseLeasesRequest",
        {},
        ETCD_PKG .. "LeaseLeasesResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

-- ===========================================================================
-- Cluster service
-- ===========================================================================

--- MemberAdd adds a member to the cluster.
---
---@async
---@param peer_urls   string[]  peer URLs for the new member
---@param is_learner? boolean
---@param opts?       table     `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:member_add(peer_urls, is_learner, opts)
    opts = opts or {}
    return self._conn:unary(
        CLUSTER_PREFIX .. "MemberAdd",
        ETCD_PKG .. "MemberAddRequest",
        {
            peer_URLs  = peer_urls,
            is_learner = is_learner or false,
        },
        ETCD_PKG .. "MemberAddResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- MemberRemove removes a member from the cluster.
---
---@async
---@param id    integer  member ID
---@param opts? table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:member_remove(id, opts)
    opts = opts or {}
    return self._conn:unary(
        CLUSTER_PREFIX .. "MemberRemove",
        ETCD_PKG .. "MemberRemoveRequest",
        { ID = id },
        ETCD_PKG .. "MemberRemoveResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- MemberUpdate updates the member configuration.
---
---@async
---@param id        integer   member ID
---@param peer_urls string[]  new peer URLs
---@param opts?     table     `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:member_update(id, peer_urls, opts)
    opts = opts or {}
    return self._conn:unary(
        CLUSTER_PREFIX .. "MemberUpdate",
        ETCD_PKG .. "MemberUpdateRequest",
        { ID = id, peer_URLs = peer_urls },
        ETCD_PKG .. "MemberUpdateResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- MemberList lists all members in the cluster.
---
---@async
---@param linearizable? boolean  default true
---@param opts?         table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:member_list(linearizable, opts)
    opts = opts or {}
    return self._conn:unary(
        CLUSTER_PREFIX .. "MemberList",
        ETCD_PKG .. "MemberListRequest",
        { linearizable = linearizable ~= false },
        ETCD_PKG .. "MemberListResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

-- ===========================================================================
-- Maintenance service
-- ===========================================================================

local ALARM_TYPE = { NONE = 0, NOSPACE = 1, CORRUPT = 2 }
M.ALARM = ALARM_TYPE

local ALARM_ACTION = { GET = 0, ACTIVATE = 1, DEACTIVATE = 2 }
M.ALARM_ACTION = ALARM_ACTION

--- Alarm activates, deactivates, or queries alarms.
---
--- ```lua
--- -- Query all alarms
--- local resp = client:alarm(etcd.ALARM_ACTION.GET, etcd.ALARM.NOSPACE)
--- -- Activate alarm
--- client:alarm(etcd.ALARM_ACTION.ACTIVATE, etcd.ALARM.NOSPACE)
--- ```
---
---@async
---@param action     integer  0=GET, 1=ACTIVATE, 2=DEACTIVATE
---@param alarm?     integer  NONE=0, NOSPACE=1, CORRUPT=2
---@param member_id? integer  specific member, or 0 for all
---@param opts?      table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:alarm(action, alarm, member_id, opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "Alarm",
        ETCD_PKG .. "AlarmRequest",
        {
            action    = action or 0,
            alarm     = alarm or 1,
            member_ID = member_id or 0,
        },
        ETCD_PKG .. "AlarmResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Status gets the status of the endpoint (version, db size, leader, etc.).
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:status(opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "Status",
        ETCD_PKG .. "StatusRequest",
        {},
        ETCD_PKG .. "StatusResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Defragment defragments the backend database on the endpoint.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:defragment(opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "Defragment",
        ETCD_PKG .. "DefragmentRequest",
        {},
        ETCD_PKG .. "DefragmentResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Hash returns the hash of the local KV state for consistency checking.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:hash(opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "Hash",
        ETCD_PKG .. "HashRequest",
        {},
        ETCD_PKG .. "HashResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- HashKV computes the hash of all MVCC keys up to a given revision.
---
---@async
---@param revision integer
---@param opts?    table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:hash_kv(revision, opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "HashKV",
        ETCD_PKG .. "HashKVRequest",
        { revision = revision },
        ETCD_PKG .. "HashKVResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Snapshot sends a snapshot of the entire backend over a server stream.
--- Returns a stream; each `:recv()` returns a chunk `{ blob, remaining_bytes }`.
---
--- ```lua
--- local s <close> = client:snapshot()
--- local chunks = {}
--- while true do
---     local chunk = s:recv()
---     if not chunk then break end
---     chunks[#chunks + 1] = chunk.blob
--- end
--- local data = table.concat(chunks)
--- ```
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return etcd.SnapshotStream? stream
---@return string? err
function Client:snapshot(opts)
    local stream, err = self._conn:server_stream(
        MAINT_PREFIX .. "Snapshot",
        ETCD_PKG .. "SnapshotRequest",
        {},
        ETCD_PKG .. "SnapshotResponse",
        opts
    )
    if not stream then
        return nil, err
    end
    return setmetatable({ _stream = stream }, SnapshotStream)
end

--- MoveLeader requests the current leader to transfer leadership to `target_id`.
---
---@async
---@param target_id integer  target node ID
---@param opts?     table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:move_leader(target_id, opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "MoveLeader",
        ETCD_PKG .. "MoveLeaderRequest",
        { target_ID = target_id },
        ETCD_PKG .. "MoveLeaderResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

local DOWNGRADE_ACTION = { VALIDATE = 0, ENABLE = 1, CANCEL = 2 }
M.DOWNGRADE_ACTION = DOWNGRADE_ACTION

--- Downgrade requests downgrades the cluster version.
---
---@async
---@param action  integer  VALIDATE=0, ENABLE=1, CANCEL=2
---@param version string   target version, e.g. "3.5"
---@param opts?   table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:downgrade(action, version, opts)
    opts = opts or {}
    return self._conn:unary(
        MAINT_PREFIX .. "Downgrade",
        ETCD_PKG .. "DowngradeRequest",
        { action = action, version = version },
        ETCD_PKG .. "DowngradeResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

-- ===========================================================================
-- Auth service
-- ===========================================================================

--- AuthEnable enables authentication.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:auth_enable(opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "AuthEnable",
        ETCD_PKG .. "AuthEnableRequest",
        {},
        ETCD_PKG .. "AuthEnableResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- AuthDisable disables authentication.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:auth_disable(opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "AuthDisable",
        ETCD_PKG .. "AuthDisableRequest",
        {},
        ETCD_PKG .. "AuthDisableResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- AuthStatus gets the authentication status.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:auth_status(opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "AuthStatus",
        ETCD_PKG .. "AuthStatusRequest",
        {},
        ETCD_PKG .. "AuthStatusResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- Authenticate authenticates with username and password.
--- Returns an auth token to include in subsequent request metadata.
---
--- ```lua
--- local resp = client:authenticate("root", "secret")
--- -- Use token for subsequent calls:
--- local opts = { metadata = { authorization = resp.token } }
--- client:range("/", etcd.prefix_end("/"), { metadata = opts.metadata })
--- ```
---
---@async
---@param name     string
---@param password string
---@param opts?    table  `{ timeout?, metadata? }`
---@return table? response  `{ token }`
---@return etcd.Status? status
function Client:authenticate(name, password, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "Authenticate",
        ETCD_PKG .. "AuthenticateRequest",
        { name = name, password = password },
        ETCD_PKG .. "AuthenticateResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserAdd adds a user.
---
---@async
---@param name     string
---@param password string
---@param opts?    table  `{ options?, timeout?, metadata? }`
---  `opts.options` is an `authpb.UserAddOptions` message `{ no_password? }`.
---@return table? response
---@return etcd.Status? status
function Client:user_add(name, password, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserAdd",
        ETCD_PKG .. "AuthUserAddRequest",
        { name = name, password = password, options = opts.user_options },
        ETCD_PKG .. "AuthUserAddResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserGet gets detailed user information.
---
---@async
---@param name  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:user_get(name, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserGet",
        ETCD_PKG .. "AuthUserGetRequest",
        { name = name },
        ETCD_PKG .. "AuthUserGetResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserList lists all users.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:user_list(opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserList",
        ETCD_PKG .. "AuthUserListRequest",
        {},
        ETCD_PKG .. "AuthUserListResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserDelete deletes a user.
---
---@async
---@param name  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:user_delete(name, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserDelete",
        ETCD_PKG .. "AuthUserDeleteRequest",
        { name = name },
        ETCD_PKG .. "AuthUserDeleteResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserChangePassword changes a user's password.
---
---@async
---@param name         string
---@param new_password string
---@param opts?        table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:user_change_password(name, new_password, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserChangePassword",
        ETCD_PKG .. "AuthUserChangePasswordRequest",
        { name = name, password = new_password },
        ETCD_PKG .. "AuthUserChangePasswordResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserGrantRole grants a role to a user.
---
---@async
---@param user  string
---@param role  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:user_grant_role(user, role, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserGrantRole",
        ETCD_PKG .. "AuthUserGrantRoleRequest",
        { user = user, role = role },
        ETCD_PKG .. "AuthUserGrantRoleResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- UserRevokeRole revokes a role from a user.
---
---@async
---@param user  string
---@param role  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:user_revoke_role(user, role, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "UserRevokeRole",
        ETCD_PKG .. "AuthUserRevokeRoleRequest",
        { user = user, role = role },
        ETCD_PKG .. "AuthUserRevokeRoleResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- RoleAdd adds a role.
---
---@async
---@param name  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:role_add(name, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "RoleAdd",
        ETCD_PKG .. "AuthRoleAddRequest",
        { name = name },
        ETCD_PKG .. "AuthRoleAddResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- RoleGet gets detailed role information.
---
---@async
---@param role  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:role_get(role, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "RoleGet",
        ETCD_PKG .. "AuthRoleGetRequest",
        { role = role },
        ETCD_PKG .. "AuthRoleGetResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- RoleList lists all roles.
---
---@async
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:role_list(opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "RoleList",
        ETCD_PKG .. "AuthRoleListRequest",
        {},
        ETCD_PKG .. "AuthRoleListResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- RoleDelete deletes a role.
---
---@async
---@param role  string
---@param opts? table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:role_delete(role, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "RoleDelete",
        ETCD_PKG .. "AuthRoleDeleteRequest",
        { role = role },
        ETCD_PKG .. "AuthRoleDeleteResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

local PERM_TYPE = { READ = 0, WRITE = 1, READWRITE = 2 }
M.PERM_TYPE = PERM_TYPE

--- RoleGrantPermission grants a permission to a role.
---
--- ```lua
--- client:role_grant_permission("myrole", {
---     key = "/app/",
---     range_end = etcd.prefix_end("/app/"),
---     perm_type = etcd.PERM_TYPE.READWRITE,
--- })
--- ```
---
---@async
---@param role  string   role name
---@param perm  table    Permission: `{ key, range_end?, perm_type }`
---@param opts? table    `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:role_grant_permission(role, perm, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "RoleGrantPermission",
        ETCD_PKG .. "AuthRoleGrantPermissionRequest",
        { name = role, permission = perm },
        ETCD_PKG .. "AuthRoleGrantPermissionResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

--- RoleRevokePermission revokes a permission from a role.
---
---@async
---@param role       string
---@param key        string
---@param range_end? string
---@param opts?      table  `{ timeout?, metadata? }`
---@return table? response
---@return etcd.Status? status
function Client:role_revoke_permission(role, key, range_end, opts)
    opts = opts or {}
    return self._conn:unary(
        AUTH_PREFIX .. "RoleRevokePermission",
        ETCD_PKG .. "AuthRoleRevokePermissionRequest",
        { name = role, key = key, range_end = range_end or "" },
        ETCD_PKG .. "AuthRoleRevokePermissionResponse",
        { timeout = opts.timeout, metadata = opts.metadata }
    )
end

return M
