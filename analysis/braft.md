# braft Replication Session Bug Analysis

**Repository**: https://github.com/brpc/braft
**Stars**: 4,174
**Language**: C++
**Status**: ✓ PROTECTED

## Protection Summary

braft is **protected** against the replication session isolation bug through CallId-based session tracking provided by the brpc RPC framework. Each RPC request receives a unique call_id, and responses are validated against in-flight requests before updating replication progress.

## How Protection Works

### 1. CallId Assignment from RPC Framework

File: [`src/braft/replicator.cpp:691`](https://github.com/brpc/braft/blob/master/src/braft/replicator.cpp#L691)

```cpp
int Replicator::_send_entries(long start_index) {
    // ... prepare request
    FlyingAppendEntriesRpc rpc;
    rpc.call_id = cntl->call_id();  // Get unique ID from brpc
    rpc.log_index = request->prev_log_index() + 1;
    rpc.entries_count = request->entries_size();

    _append_entries_in_fly.push_back(rpc);
    // ... send RPC
}
```

Each AppendEntries request is assigned a unique `call_id` by the brpc Controller, which is stored in the `FlyingAppendEntriesRpc` struct.

### 2. Response Validation Against In-Flight Queue

File: [`src/braft/replicator.cpp:384-398`](https://github.com/brpc/braft/blob/master/src/braft/replicator.cpp#L384-L398)

```cpp
void Replicator::_on_rpc_returned(ReplicatorId id, brpc::Controller* cntl,
                                   AppendEntriesRequest* request,
                                   AppendEntriesResponse* response,
                                   int64_t rpc_send_time) {
    // ...
    bool valid_rpc = false;

    // Find matching in-flight RPC by call_id
    for (std::deque<FlyingAppendEntriesRpc>::iterator rpc_it =
         r->_append_entries_in_fly.begin();
         rpc_it != r->_append_entries_in_fly.end(); ++rpc_it) {
        if (rpc_it->call_id == cntl->call_id()) {
            valid_rpc = true;
            // Remove this and all older RPCs from queue
            r->_append_entries_in_fly.erase(
                r->_append_entries_in_fly.begin(), ++rpc_it);
            break;
        }
    }

    if (!valid_rpc) {
        // Stale response - call_id not found in queue
        LOG(WARNING) << "Received stale AppendEntries response";
        return;  // Ignore response
    }

    // Process valid response
    // ...
}
```

When a response arrives, braft searches the in-flight queue for a matching `call_id`. If not found, the response is rejected as stale.

### 3. Queue Cleanup on Node Removal

File: [`src/braft/replicator.cpp:1077-1084`](https://github.com/brpc/braft/blob/master/src/braft/replicator.cpp#L1077-L1084)

```cpp
void Replicator::_destroy() {
    // Cancel all in-flight RPCs
    for (std::deque<FlyingAppendEntriesRpc>::iterator it =
         _append_entries_in_fly.begin();
         it != _append_entries_in_fly.end(); ++it) {
        brpc::StartCancel(it->call_id);
    }
    _append_entries_in_fly.clear();
    // ...
}
```

When a replicator is destroyed (e.g., node removed), all in-flight RPCs are canceled and the queue is cleared.

## Why This Prevents the Bug

1. **Unique session identifier**: Each RPC gets a unique `call_id` from the framework
2. **Request-response correlation**: Responses must match a pending request
3. **Queue isolation**: When a node is removed and rejoins, the old replicator is destroyed with its in-flight queue, and a new replicator is created with an empty queue
4. **Automatic rejection**: Delayed responses from the old session have `call_id` values that don't exist in the new replicator's queue, so they're automatically rejected

## Protection Flow

```
Timeline | Event                                    | In-Flight Queue
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | Queue: [callId=100]
         | Send AppendEntries with callId=100      | (network delay)
         |                                          |
T2       | Node C removed from cluster              | Queue: [] (cleared)
         | Replicator destroyed                     | callId=100 canceled
         | In-flight queue cleared                  |
         |                                          |
T3       | Node C rejoins cluster                   | Queue: [] (new)
         | New Replicator created                   | (empty queue)
         |                                          |
T4       | Delayed response arrives                 | Queue: []
         | {callId: 100, index: 50, success: true}  | callId=100 not found
         | Search queue for callId=100: NOT FOUND   | Response REJECTED ✓
         |                                          |
T5       | Send new AppendEntries with callId=200   | Queue: [callId=200]
         | Normal replication continues             | Clean state
```

## Benefits

- **Robust**: Cannot be fooled by delayed responses
- **Proven**: brpc is widely used in production systems
- **No protocol changes**: Works at application level
- **Per-request granularity**: Handles all edge cases

## References

- RPC sending: `src/braft/replicator.cpp:691`
- Response validation: `src/braft/replicator.cpp:384-398`
- Cleanup on removal: `src/braft/replicator.cpp:1077-1084`
- brpc documentation: https://github.com/apache/brpc
