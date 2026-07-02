---
--- example_etcd.lua — Native etcd v3 client via gRPC (grpc.core) + protobuf.
---
--- Prereqs:
---   1. A running etcd server on :2379:
---        etcd --listen-client-urls http://127.0.0.1:2379
---
---   2. A compiled FileDescriptorSet for the etcd protos
---      (already built as assets/example/grpc/etcd.pb).
---
--- Run:  moon_rs assets/example/example_etcd.lua
---

local moon     = require("moon")
local protobuf = require("protobuf")
local etcd     = require("moon.db.etcd")

moon.loglevel("INFO")

local DESC_PATH = "grpc/etcd.pb"

moon.async(function()
    print("=== etcd v3 Client Example ===\n")

    -- 1. Load the etcd FileDescriptorSet (shared, process-global).
    local desc = io.readfile(DESC_PATH)
    protobuf.load(desc)
    print("protobuf descriptor loaded (" .. #desc .. " bytes)")

    -- 2. Connect to etcd.
    local client, err = etcd.connect({
        endpoint        = "http://127.0.0.1:2379",
        name            = "etcd-main",
        connect_timeout = 5000,
    })
    if not client then
        print("connect failed:", err)
        moon.exit(-1)
        return
    end
    print("connected to etcd\n")

    -----------------------------------------------------------
    -- 3. Put some keys
    -----------------------------------------------------------
    print("--- put ---")
    local put_resp = client:put("/example/hello", "world")
    assert(put_resp, "put failed")
    print(string.format("  put /example/hello = world  (revision=%d)", put_resp.header.revision))

    client:put("/example/config/name", "moon_rs")
    client:put("/example/config/version", "1.0")
    client:put("/example/users/alice", "active")
    client:put("/example/users/bob", "inactive")

    -----------------------------------------------------------
    -- 4. Range — exact key
    -----------------------------------------------------------
    print("\n--- range (exact key) ---")
    local range_resp = client:range("/example/hello")
    if range_resp and range_resp.count > 0 then
        for _, kv in ipairs(range_resp.kvs) do
            print(string.format("  %s = %s", kv.key, kv.value))
        end
    end

    -----------------------------------------------------------
    -- 5. Range — prefix query
    -----------------------------------------------------------
    print("\n--- range (prefix: /example/config/) ---")
    range_resp = client:range("/example/config/", etcd.prefix_end("/example/config/"))
    if range_resp and range_resp.kvs then
        for _, kv in ipairs(range_resp.kvs) do
            print(string.format("  %s = %s", kv.key, kv.value))
        end
    end
    print(string.format("  count=%d", range_resp.count))

    -----------------------------------------------------------
    -- 6. Range — keys_only
    -----------------------------------------------------------
    print("\n--- range (keys_only) ---")
    range_resp = client:range("/example/", etcd.prefix_end("/example/"), { keys_only = true })
    if range_resp and range_resp.kvs then
        for _, kv in ipairs(range_resp.kvs) do
            print(string.format("  %s  (version=%d)", kv.key, kv.version))
        end
    end

    -----------------------------------------------------------
    -- 7. Delete a key
    -----------------------------------------------------------
    print("\n--- delete ---")
    local deleted = client:delete("/example/users/bob")
    print(string.format("  deleted %d key(s)", deleted))

    -- Verify
    range_resp = client:range("/example/users/bob")
    print(string.format("  count after delete: %d", range_resp.count))

    -----------------------------------------------------------
    -- 8. Transaction (Txn): Compare-And-Swap
    -----------------------------------------------------------
    print("\n--- txn (CAS) ---")
    -- Try to put /example/lock only if it does not exist (create_revision == 0)
    local txn_resp = client:txn(
        {{ -- compares
            result           = 0,   -- EQUAL
            target           = 1,   -- CREATE
            key              = "/example/lock",
            create_revision  = 0,
        }},
        {{ -- success: key does not exist → create it
            request_put = {
                key   = "/example/lock",
                value = "acquired-by-example",
            },
        }},
        {{ -- failure: key exists → return current value
            request_range = { key = "/example/lock" },
        }}
    )
    if txn_resp.succeeded then
        print("  lock acquired")
    else
        local holder = txn_resp.responses[1].response_range.kvs[1]
        print(string.format("  lock held by: %s", holder and holder.value or "unknown"))
    end

    -- Second attempt should fail (key now exists)
    txn_resp = client:txn(
        {{ result = 0, target = 1, key = "/example/lock", create_revision = 0 }},
        {{ request_put = { key = "/example/lock", value = "second-attempt" } }},
        {{ request_range = { key = "/example/lock" } }}
    )
    print(string.format("  second attempt succeeded: %s", txn_resp.succeeded))

    -----------------------------------------------------------
    -- 9. Lease
    -----------------------------------------------------------
    print("\n--- lease ---")
    local grant_resp = client:lease_grant(30) -- 30 second TTL
    assert(grant_resp, "lease_grant failed")
    local lease_id = grant_resp.ID
    print(string.format("  lease granted: ID=%d TTL=%d", lease_id, grant_resp.TTL))

    -- Attach lease to a key
    client:put("/example/lease-demo", "expires-in-30s", { lease = lease_id })
    local ttl_resp = client:lease_time_to_live(lease_id, true)
    print(string.format("  lease TTL: grantedTTL=%d TTL=%d keys=%d",
        ttl_resp.grantedTTL, ttl_resp.TTL, #(ttl_resp.keys or {})))

    -- Revoke
    client:lease_revoke(lease_id)
    range_resp = client:range("/example/lease-demo")
    print(string.format("  key after revoke: count=%d", range_resp.count))

    -----------------------------------------------------------
    -- 10. Watch — spawn a separate coroutine to receive events
    -----------------------------------------------------------
    print("\n--- watch ---")

    -- Shared flag so the main coroutine knows when the watcher is done.
    local watch_ready = false
    local watch_done = false
    local watch_events = {}

    moon.async(function()
        -- Create a watch on a prefix.  The stream is auto-closed when this
        -- coroutine returns (thanks to <close>).
        local w <close> = client:watch({
            key        = "/example/watch/",
            range_end  = etcd.prefix_end("/example/watch/"),
            prev_kv    = true,   -- include previous KV in DELETE events
        })
        print("  watch stream created on /example/watch/")

        -- The first response carries `created = true` (no events).
        local resp = w:recv()
        if not resp then
            print("  watch create failed")
            watch_done = true
            return
        end
        if resp.created then
            print("  watch established, waiting for events...")
        end
        watch_ready = true

        -- Collect a few events, then stop.
        while #watch_events < 3 do
            resp = w:recv()
            if not resp then
                print("  watch stream closed")
                break
            end
            for _, ev in ipairs(resp.events or {}) do
                watch_events[#watch_events + 1] = ev
                local typ = (ev.type == 0) and "PUT" or "DELETE"
                local prev = ev.prev_kv and ("  (prev=" .. (ev.prev_kv.value or "") .. ")") or ""
                print(string.format("  [%s] %s = %s%s",
                    typ, ev.kv.key, ev.kv.value or "", prev))
            end
        end

        watch_done = true
        print("  watch coroutine finished")
    end)

    -- Wait for the watch stream to be ready.
    while not watch_ready do
        moon.sleep(10)
    end

    -- Make changes that trigger watch events.
    client:put("/example/watch/key1", "value1")
    client:put("/example/watch/key2", "value2")
    client:delete("/example/watch/key1")   -- triggers DELETE with prev_kv

    -- Wait for all expected events.
    while not watch_done do
        moon.sleep(10)
    end
    print(string.format("  received %d watch events", #watch_events))

    -----------------------------------------------------------
    -- 11. Cluster status
    -----------------------------------------------------------
    print("\n--- cluster status ---")
    local status_resp = client:status()
    if status_resp then
        print(string.format("  version: %s", status_resp.version))
        print(string.format("  dbSize:  %d kB", status_resp.dbSize // 1024))
        print(string.format("  leader:  %d", status_resp.leader or 0))
        print(string.format("  raftIndex: %d", status_resp.raftIndex or 0))
    end

    -- Member list
    local member_resp = client:member_list()
    if member_resp and member_resp.members then
        print(string.format("  members: %d", #member_resp.members))
        for _, m in ipairs(member_resp.members) do
            print(string.format("    id=%d name=%s clientURLs=%s",
                m.ID, m.name, table.concat(m.clientURLs or {}, ",")))
        end
    end

    -----------------------------------------------------------
    -- 12. Clean up
    -----------------------------------------------------------
    print("\n--- cleanup ---")
    client:delete_range("/example/", etcd.prefix_end("/example/"))
    print("  all /example/ keys deleted")

    -- Close the connection
    etcd.close("etcd-main")

    print("\n=== example_etcd done ===")
    moon.exit(0)
end)

moon.shutdown(function()
    moon.quit()
end)
