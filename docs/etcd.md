# etcd v3 Client (`moon.db.etcd`)

A pure-Lua etcd v3 client that speaks gRPC natively, reusing the existing
`grpc.core` transport (HTTP/2 + tonic `Channel`) and the `protobuf`
encode/decode infrastructure. **No additional Rust code is required** — the
entire etcd v3 API surface (KV, Watch, Lease, Cluster, Maintenance, Auth) is
implemented as a thin Lua wrapper over `moon.grpc`.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Lua Actor Thread                                              │
│                                                              │
│  client:put("/key", "val")                                   │
│    → Build PutRequest table                                   │
│    → conn:unary(path, req_type, req, resp_type)             │
│      → protobuf.encode(req_type, req)  → request bytes       │
│      → grpc.core unary(path, bytes)    → returns a session   │
│      → moon.wait(session) — coroutine yields                 │
│    → PTYPE_GRPC reply → { status, message, body }            │
│    → protobuf.decode(resp_type, body) → Lua table            │
└──────────────┬───────────────────────────────────────────────┘
               │ (owner, session) + raw protobuf bytes
               ▼
┌──────────────────────────────────────────────────────────────┐
│ IO Runtime (tokio) — tonic Channel (one HTTP/2 connection)    │
│                                                              │
│  BytesCodec: identity passthrough (no protobuf parsing)      │
│  HTTP/2 multiplexing: many concurrent requests over one conn │
│  Auto-reconnect on connection loss                            │
│  TLS via rustls (aws-lc-rs) + webpki roots                   │
│  send_value(PTYPE_GRPC, owner, session, response)            │
└──────────────────────────────────────────────────────────────┘
```

A single tonic `Channel` multiplexes concurrent requests over one HTTP/2
connection and reconnects automatically — no connection pool needed. Streaming
RPCs (Watch, LeaseKeepAlive, Snapshot) get a stream handle backed by `grpc.core`'s
native stream management.

## Design Principles

1. **Zero native code** — etcd v3 *is* gRPC. The existing `grpc.core` transport
   and `protobuf` encode/decode handle everything.
2. **Single connection** — a tonic `Channel` does HTTP/2 multiplexing and
   auto-reconnect; one connection per etcd cluster is sufficient.
3. **Full API coverage** — all six etcd v3 services (KV, Watch, Lease, Cluster,
   Maintenance, Auth) are wrapped with idiomatic Lua methods.
4. **Same error model as gRPC** — every unary call returns `response, nil` on
   success or `nil, status` on error, where `status` is `{ code, message }`.
5. **Prefix queries made simple** — `etcd.prefix_end(key)` computes the
   lexicographic range-end for prefix-based Range and Watch operations.

## Prerequisites

### 1. Compile the etcd FileDescriptorSet

```bash
git clone --depth 1 --branch v3.5.18 https://github.com/etcd-io/etcd.git
protoc --include_imports \
  --descriptor_set_out=assets/example/grpc/etcd.pb \
  -I etcd/api \
  etcd/api/etcdserverpb/rpc.proto \
  etcd/api/mvccpb/kv.proto \
  etcd/api/authpb/auth.proto
```

A pre-built descriptor (`assets/example/grpc/etcd.pb`, ~31 KB) is included.

> **Version matching**: the descriptor must match your etcd cluster version. The
> included `etcd.pb` was built from etcd **v3.5.18** protos. If your cluster runs a
> different version (especially a newer major like v3.6.x), rebuild the descriptor
> from the corresponding proto sources. Different etcd versions may introduce new
> RPCs or modify message fields, causing decode errors at runtime if mismatched.

### 2. Load descriptors at startup (process-global, one-time)

`protobuf.load()` accepts **multiple** `FileDescriptorSet` data arguments
in a single call — use this to load business protos and etcd protos together:

```lua
protobuf.load(business_proto_bytes, etcd_proto_bytes)
```

> **Note**: each call to `protobuf.load()` **replaces** the entire descriptor
> registry. To load multiple descriptors, pass them all in **one** call.
> Multiple separate calls will only keep the last one.

All descriptors must be loaded **before** any gRPC connection is opened,
because encoding/decoding reads from the registry at call time.

### 3. Feature flags

No additional feature flags needed. The etcd client depends on `grpc` and
`protobuf`, both enabled by default:

```toml
# crates/moon-runtime/Cargo.toml
[features]
default = ["grpc", "protobuf", ...]
```

## Lua API (`require("moon.db.etcd")`)

### Setup

`protobuf.load()` supports loading **multiple FileDescriptorSets in one call**.
In real projects, load your business protos and the etcd proto together — passing
all data arguments to a single `load()` call.

```lua
local protobuf = require("protobuf")
local etcd     = require("moon.db.etcd")

-- Load ALL protobuf descriptors in ONE call.
-- Multiple calls REPLACE the registry; only the last call's data is kept.
local business_desc = io.readfile("proto/game.pb")       -- your business protos
local etcd_desc     = io.readfile("grpc/etcd.pb")         -- etcd v3 protos
protobuf.load(business_desc, etcd_desc)

-- Connect. http:// is plaintext h2c; https:// enables TLS.
local client, err = etcd.connect({
    endpoint        = "http://127.0.0.1:2379",
    name            = "etcd-main",    -- registry key (default "etcd")
    connect_timeout = 5000,           -- ms
    -- tls = { domain = "example.com", ca = <pem>, cert = <pem>, key = <pem> },
})
assert(client, err)
```

> **Important**: `protobuf.load()` must be called **before** any gRPC
> connections are established. The descriptors are read at encode/decode
> time, not at connect time. Load all descriptors — business + etcd —
> together at startup to avoid issues with cross-referencing message
> types.

### KV — Key-Value Operations

```lua
-- Put a key
local put_resp = client:put("/app/config", "value")
print(put_resp.header.revision)

-- Put with options
client:put("/app/session", "alive", { lease = lease_id, prev_kv = true })

-- Range — exact key match
local resp = client:range("/app/config")
if resp.count > 0 then
    print(resp.kvs[1].value)
end

-- Range — prefix query
resp = client:range("/app/", etcd.prefix_end("/app/"))
for _, kv in ipairs(resp.kvs or {}) do
    print(kv.key, kv.value, kv.version)
end

-- Range — keys only (no values, smaller response)
resp = client:range("/app/", etcd.prefix_end("/app/"), { keys_only = true })

-- Range — with revision and limit
resp = client:range("/app/", etcd.prefix_end("/app/"), {
    revision = 10, limit = 100, sort_order = 1, -- ASCEND
})

-- Delete — single key
local deleted = client:delete("/app/config")
print("deleted:", deleted)

-- Delete — range
local del_resp = client:delete_range("/app/", etcd.prefix_end("/app/"), { prev_kv = true })
print(del_resp.deleted)
for _, kv in ipairs(del_resp.prev_kvs or {}) do
    print("deleted:", kv.key, kv.value)
end
```

### Txn — Atomic Transactions

```lua
-- Compare-And-Swap: acquire a distributed lock
local resp = client:txn(
    {{ -- compares: key must not exist (create_revision == 0)
        result           = 0,   -- EQUAL
        target           = 1,   -- CREATE
        key              = "/lock/resource-1",
        create_revision  = 0,
    }},
    {{ -- success: create the lock key
        request_put = {
            key   = "/lock/resource-1",
            value = "owner-42",
            lease = lease_id,
        },
    }},
    {{ -- failure: return current holder
        request_range = { key = "/lock/resource-1" },
    }}
)

if resp.succeeded then
    print("lock acquired")
else
    local holder = resp.responses[1].response_range.kvs[1]
    print("held by:", holder.value)
end

-- Multi-key atomic update
resp = client:txn(
    {{ result = 0, target = 3, key = "/balance/alice", value = "100" }}, -- VALUE == 100
    {
        { request_put = { key = "/balance/alice", value = "50" } },
        { request_put = { key = "/balance/bob",   value = "150" } },
    },
    {}  -- failure: do nothing
)
```

**Compare fields**: `result` (EQUAL=0, GREATER=1, LESS=2, NOT_EQUAL=3),
`target` (VERSION=0, CREATE=1, MOD=2, VALUE=3, LEASE=4), `key`, plus
exactly one of `version`, `create_revision`, `mod_revision`, `value`, or
`lease` as the `target_union`.

**RequestOp fields**: exactly one of `request_range`, `request_put`,
`request_delete_range`, or `request_txn`, each set to the corresponding
request message table.

### Watch — Event Streaming

Watch is a bidirectional gRPC stream. The client sends a `WatchCreateRequest`
and then receives `WatchResponse` messages as events occur.

```lua
-- Start watching a prefix
local w <close> = client:watch({
    key              = "/app/",
    range_end        = etcd.prefix_end("/app/"),
    start_revision   = current_revision,
    progress_notify  = true,   -- periodic heartbeats
    prev_kv          = true,   -- include previous value on PUT
})

while true do
    local resp = w:recv()
    if not resp then break end          -- stream ended / error

    if resp.created then
        print("watch created, watch_id:", resp.watch_id)
    end

    for _, ev in ipairs(resp.events or {}) do
        if ev.type == 0 then            -- PUT
            print("PUT", ev.kv.key, ev.kv.value)
        else                            -- DELETE
            print("DELETE", ev.kv.key)
        end
    end
end

-- Cancel a specific watch on the same stream
etcd.watch_cancel(w, watch_id)

-- Request a progress notification (heartbeat)
etcd.watch_progress(w)
```

The `__close` metamethod auto-closes the stream on scope exit or error.

### Lease — TTL-based Key Expiry

```lua
-- Grant a lease (TTL in seconds)
local grant = client:lease_grant(30)
local lease_id = grant.ID

-- Attach the lease to a key
client:put("/app/session/token-1", "user-data", { lease = lease_id })

-- Check lease status
local ttl = client:lease_time_to_live(lease_id, true) -- true = list keys
print(string.format("TTL=%d granted=%d keys=%d", ttl.TTL, ttl.grantedTTL, #(ttl.keys or {})))

-- List all leases
local leases = client:lease_leases()
for _, l in ipairs(leases.leases or {}) do
    print("lease:", l.ID)
end

-- Revoke (keys expire immediately)
client:lease_revoke(lease_id)
```

#### Lease Keep-Alive (bidirectional stream)

```lua
local ka <close> = client:lease_keep_alive(lease_id)

-- Read the first server response
local resp = ka:recv()
print("initial TTL:", resp.TTL)

-- Periodically renew
while true do
    moon.sleep(resp.TTL // 3 * 1000)   -- renew at TTL/3
    ka:send()                           -- send keep-alive ping
    resp = ka:recv()
    if not resp then break end          -- lease revoked / error
    print("renewed, TTL:", resp.TTL)
end
```

### Cluster

```lua
-- List members
local members = client:member_list()
for _, m in ipairs(members.members or {}) do
    print(string.format("id=%d name=%s clientURLs=%s peerURLs=%s",
        m.ID, m.name,
        table.concat(m.clientURLs or {}, ","),
        table.concat(m.peerURLs or {}, ",")))
end

-- Add a member
client:member_add({"http://new-node:2380"}, false) -- is_learner = false

-- Remove a member
client:member_remove(member_id)

-- Update a member's peer URLs
client:member_update(member_id, {"http://updated:2380"})
```

### Maintenance

```lua
-- Endpoint status
local st = client:status()
print(st.version, st.dbSize, st.leader)

-- Defragment
client:defragment()

-- Hash check (for consistency verification)
local h = client:hash()
print("hash:", h.hash)

-- Hash at a specific revision
local hk = client:hash_kv(42)

-- Alarms
local alarms = client:alarm(0, 1)  -- GET, NOSPACE
print(#alarms.alarms, "alarms")

-- Snapshot (server-side streaming)
local snap <close> = client:snapshot()
local chunks = {}
while true do
    local chunk = snap:recv()
    if not chunk then break end
    chunks[#chunks + 1] = chunk.blob
end
local snapshot_data = table.concat(chunks)
io.writefile("snapshot.db", snapshot_data)

-- Downgrade
client:downgrade(0, "3.5")   -- VALIDATE
client:downgrade(1, "3.5")   -- ENABLE
```

### Auth

```lua
-- Authentication
local auth_resp = client:authenticate("root", "secret")
local auth_meta = { authorization = auth_resp.token }

-- Now use auth_meta on subsequent calls
client:range("/", etcd.prefix_end("/"), { metadata = auth_meta })

-- User management
client:user_add("alice", "password123", { metadata = auth_meta })
client:user_get("alice", { metadata = auth_meta })
client:user_change_password("alice", "new-password", { metadata = auth_meta })
client:user_grant_role("alice", "reader", { metadata = auth_meta })
client:user_revoke_role("alice", "reader", { metadata = auth_meta })
client:user_delete("alice", { metadata = auth_meta })

-- Role management
client:role_add("reader", { metadata = auth_meta })
client:role_grant_permission("reader", {
    key = "/app/",
    range_end = etcd.prefix_end("/app/"),
    perm_type = 0,  -- READ
}, { metadata = auth_meta })
client:role_delete("reader", { metadata = auth_meta })
```

## API Reference

### Module `moon.db.etcd`

| Function | Description |
| --- | --- |
| `etcd.connect(opts?)` | Async connect to an etcd cluster. Returns `client` or `nil, err`. |
| `etcd.close(name?)` | Unregister and drop a named connection (default `"etcd"`). |
| `etcd.prefix_end(key)` | Compute the range-end for a prefix query. |
| `etcd.watch_cancel(stream, watch_id)` | Cancel a watch on an active stream. |
| `etcd.watch_progress(stream)` | Send a progress-request on an active watch stream. |

`opts` for `connect`: `{ endpoint?, name?, connect_timeout?, tls? }`.
`endpoint` defaults to `"http://127.0.0.1:2379"`.

### `Client` — KV Service

| Method | Description |
| --- | --- |
| `client:range(key, range_end?, opts?)` | Range query → `RangeResponse` or `nil, status`. |
| `client:put(key, value, opts?)` | Put a key → `PutResponse` or `nil, status`. |
| `client:delete_range(key, range_end?, opts?)` | Delete a range → `DeleteRangeResponse` or `nil, status`. |
| `client:delete(key, opts?)` | Delete a single key → `deleted_count` or `nil, status`. |
| `client:txn(compares, success, failure?, opts?)` | Atomic transaction → `TxnResponse` or `nil, status`. |
| `client:compact(revision, physical?, opts?)` | Compact event history → `CompactionResponse` or `nil, status`. |

`opts` for all KV methods: `{ timeout?, metadata? }`. Range/Put/DeleteRange also
accept their respective proto fields as optional keys (e.g., `limit`, `revision`,
`prev_kv`, `lease`, `keys_only`, `count_only`, `serializable`, etc.).

### `Client` — Watch Service

| Method | Description |
| --- | --- |
| `client:watch(create_req, opts?)` | Open a watch stream → `WatchStream` or `nil, err`. |

### `Client` — Lease Service

| Method | Description |
| --- | --- |
| `client:lease_grant(ttl, id?, opts?)` | Create a lease → `LeaseGrantResponse` or `nil, status`. |
| `client:lease_revoke(id, opts?)` | Revoke a lease → `LeaseRevokeResponse` or `nil, status`. |
| `client:lease_keep_alive(lease_id, opts?)` | Start keep-alive stream → `KeepAliveStream` or `nil, err`. |
| `client:lease_time_to_live(id, keys?, opts?)` | Query lease info → `LeaseTimeToLiveResponse` or `nil, status`. |
| `client:lease_leases(opts?)` | List all leases → `LeaseLeasesResponse` or `nil, status`. |

### `Client` — Cluster Service

| Method | Description |
| --- | --- |
| `client:member_add(peer_urls, is_learner?, opts?)` | Add a member → `MemberAddResponse` or `nil, status`. |
| `client:member_remove(id, opts?)` | Remove a member → `MemberRemoveResponse` or `nil, status`. |
| `client:member_update(id, peer_urls, opts?)` | Update a member → `MemberUpdateResponse` or `nil, status`. |
| `client:member_list(linearizable?, opts?)` | List members → `MemberListResponse` or `nil, status`. |

### `Client` — Maintenance Service

| Method | Description |
| --- | --- |
| `client:status(opts?)` | Endpoint status → `StatusResponse` or `nil, status`. |
| `client:alarm(action, alarm?, member_id?, opts?)` | Query/activate/deactivate alarms → `AlarmResponse`. |
| `client:defragment(opts?)` | Defragment the backend → `DefragmentResponse` or `nil, status`. |
| `client:hash(opts?)` | Hash of local KV → `HashResponse` or `nil, status`. |
| `client:hash_kv(revision, opts?)` | Hash at a revision → `HashKVResponse` or `nil, status`. |
| `client:snapshot(opts?)` | Stream a snapshot → `SnapshotStream` or `nil, err`. |
| `client:move_leader(target_id, opts?)` | Transfer leadership → `MoveLeaderResponse` or `nil, status`. |
| `client:downgrade(action, version, opts?)` | Downgrade cluster version → `DowngradeResponse` or `nil, status`. |

### `Client` — Auth Service

| Method | Description |
| --- | --- |
| `client:auth_enable(opts?)` | Enable authentication. |
| `client:auth_disable(opts?)` | Disable authentication. |
| `client:auth_status(opts?)` | Get auth status. |
| `client:authenticate(name, password, opts?)` | Authenticate → `{ token }`. |
| `client:user_add(name, password, opts?)` | Add a user. |
| `client:user_get(name, opts?)` | Get user details. |
| `client:user_list(opts?)` | List all users. |
| `client:user_delete(name, opts?)` | Delete a user. |
| `client:user_change_password(name, new_password, opts?)` | Change a user's password. |
| `client:user_grant_role(user, role, opts?)` | Grant a role to a user. |
| `client:user_revoke_role(user, role, opts?)` | Revoke a role from a user. |
| `client:role_add(name, opts?)` | Add a role. |
| `client:role_get(role, opts?)` | Get role details. |
| `client:role_list(opts?)` | List all roles. |
| `client:role_delete(role, opts?)` | Delete a role. |
| `client:role_grant_permission(role, perm, opts?)` | Grant a permission to a role. |
| `client:role_revoke_permission(role, key, range_end?, opts?)` | Revoke a permission. |

### Stream Types

| Stream | Source | Methods |
| --- | --- | --- |
| `WatchStream` | `client:watch()` | `recv()` → `WatchResponse`, `close()`, `<close>` |
| `KeepAliveStream` | `client:lease_keep_alive()` | `send()`, `recv()` → `LeaseKeepAliveResponse`, `close()`, `<close>` |
| `SnapshotStream` | `client:snapshot()` | `recv()` → `{ blob, remaining_bytes }`, `close()`, `<close>` |

All stream types support Lua's **to-be-closed** (`<close>`) variable pattern,
auto-releasing native resources on scope exit.

### Constants

| Constant | Values |
| --- | --- |
| `etcd.ALARM` | `{ NONE = 0, NOSPACE = 1, CORRUPT = 2 }` |
| `etcd.ALARM_ACTION` | `{ GET = 0, ACTIVATE = 1, DEACTIVATE = 2 }` |
| `etcd.DOWNGRADE_ACTION` | `{ VALIDATE = 0, ENABLE = 1, CANCEL = 2 }` |
| `etcd.PERM_TYPE` | `{ READ = 0, WRITE = 1, READWRITE = 2 }` |

## Notes & Limits

- **Message size** is capped by `LIMITS.max_network_read_bytes`, inherited from
  the gRPC module. Individual values larger than the limit are rejected.
- **Keys and values are raw bytes** — Lua strings carry arbitrary bytes natively,
  including `\0`. No encoding or base64 wrapping is applied.
- **Prefix queries**: use `etcd.prefix_end(key)` to compute the correct
  `range_end` for the `[key, prefix_end)` interval. Do not append `\0` manually.
- **Watch reconnection**: the underlying gRPC stream does not auto-resume on
  disconnection. Use the `start_revision` field (latest revision before the
  watch started) to re-establish the watch without missing events.
- **Concurrency**: many unary calls can be in flight over a single connection.
  A streaming RPC permits at most one outstanding `recv` at a time (a second
  returns a gRPC error).
- **Authentication token**: after `authenticate()`, pass the token via the
  `metadata` option on every call (`{ metadata = { authorization = token } }`).
  etcd does not use an implicit session.

## Low-Level Access

For operations that need the raw gRPC connection:

```lua
local conn = client:grpc_connection()
-- Direct gRPC call with protobuf type names
local reply, status = conn:unary(
    "/etcdserverpb.KV/Range",
    "etcdserverpb.RangeRequest",
    { key = "/foo" },
    "etcdserverpb.RangeResponse"
)
```

## Source

- Client module: `lualib/moon/db/etcd.lua` (~1200 lines, pure Lua)
- gRPC transport (reused): `crates/moon-runtime/src/modules/lua_grpc.rs`
- gRPC Lua wrapper (reused): `lualib/moon/grpc.lua`
- Protobuf descriptor: `assets/example/grpc/etcd.pb` (~31 KB)
- Example: `assets/example/example_etcd.lua`
