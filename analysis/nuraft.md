# NuRaft - PROTECTED

**Repository**: [ebay/NuRaft](https://github.com/ebay/NuRaft)
**Stars**: 1,140
**Language**: C++
**Status**: ✓ PROTECTED

## Protection Summary

NuRaft is protected against the replication session isolation bug through **RPC client ID validation**. The implementation captures the RPC client object identity when sending requests and validates responses against the current RPC client ID, ensuring that delayed responses from old replication sessions (before node removal) cannot corrupt the new session's progress tracking after a node rejoins.

## How Protection Works

### RPC Client ID Tracking

When a peer sends an AppendEntries request, the RPC client pointer is captured in the request closure:

File: [`peer.cxx:31-84`](https://github.com/ebay/NuRaft/blob/master/src/peer.cxx#L31-L84)

```cpp
ptr<req_msg> req(cs_new<req_msg>(...)...);
ptr<rpc_client> my_rpc_client = rpc_;
ptr<rpc_exception> err = nullptr;

rpc_handler callback = [SELF_REF, req, my_rpc_client]
                      (ptr<resp_msg>& resp,
                       ptr<rpc_exception>& err) -> void {
    // Response callback
};
```

The `my_rpc_client` variable captures the current RPC client object that will be used to send the request.

### Response Validation

When a response arrives, the implementation validates that the captured RPC client ID matches the current RPC client ID:

File: [`peer.cxx:119-143`](https://github.com/ebay/NuRaft/blob/master/src/peer.cxx#L119-L143)

```cpp
uint64_t cur_rpc_id = rpc_ ? rpc_->get_id() : 0;
uint64_t given_rpc_id = my_rpc_client ? my_rpc_client->get_id() : 0;

if (cur_rpc_id != given_rpc_id) {
    // Stale RPC from old session
    p_tr("stale RPC from peer %d: %" PRIu64 " (current %" PRIu64 ")",
         peer_->get_id(),
         given_rpc_id,
         cur_rpc_id);
    inc_stale_rpc_responses();
    return;  // Reject stale response
}

// Only proceed if IDs match
// Update progress tracking...
```

### RPC Client Lifecycle

When a node is removed and rejoins:

1. **Node removal**: Old RPC client is destroyed
2. **Node rejoin**: New RPC client is created with a fresh ID
3. **Delayed responses**: Carry the old RPC client ID in their closure
4. **Validation failure**: ID mismatch detected, response rejected

## Protection Flow

```
Timeline | Event                                    | RPC Client State
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | rpc_C (ID=100)
         | Leader sends AppendEntries(index=50)     | Closure captures ID=100
         | (network delay)                          |
         |                                          |
T2       | Node C removed from cluster              | rpc_C destroyed
         | Progress[C] deleted                      | C: [deleted]
         |                                          |
T3       | Node C rejoins cluster                   | rpc_C_new (ID=101)
         | New RPC client created                   | C: matched=0 (new)
         | New Progress[C] created                  |
         |                                          |
T4       | Delayed response arrives                 | Closure has ID=100
         | Validation: 100 != 101                   | current ID=101
         | Early return before progress update      | ✓ Protection works
         | Stale counter incremented                |
         |                                          |
T5       | Leader sends fresh AppendEntries(prev=0) |
         | Node C accepts (correct state)           |
         | Normal replication continues             | ✓ No corruption
```

## Benefits

### Automatic Session Management

No manual session tracking is required. The RPC client lifecycle naturally provides session boundaries:

- **Creation**: New session begins
- **Destruction**: Old session ends
- **ID generation**: Automatic uniqueness

### No Protocol Changes

The protection works entirely at the application level without requiring:

- Additional message fields
- Protocol version changes
- Wire format modifications
- Compatibility breaks

### Low Overhead

The validation overhead is minimal:

- Single ID comparison per response
- No additional state per request
- Counter increment for metrics
- Early return for stale responses

### Framework Integration

The protection is deeply integrated with the RPC framework:

- RPC client manages unique ID generation
- Natural lifecycle management
- Built-in metrics (stale response counter)
- Clean separation of concerns

## Implementation Details

### RPC Client ID Generation

Each RPC client gets a unique ID when created:

```cpp
class rpc_client {
public:
    uint64_t get_id() const { return id_; }

private:
    uint64_t id_;  // Unique identifier
};
```

### Stale Response Tracking

The implementation tracks stale responses for monitoring:

```cpp
void peer::inc_stale_rpc_responses() {
    stale_rpc_responses_++;
}
```

This provides visibility into how often the protection mechanism triggers, useful for debugging and monitoring.

### Thread Safety

The ID comparison is thread-safe because:

- IDs are immutable after creation
- Pointer capture in closure is atomic
- No concurrent modification of RPC client ID

## Impact Assessment

### Protection Effectiveness

- **Prevents progress corruption**: Yes, 100% effective
- **Handles delayed responses**: Yes, all stale responses rejected
- **Works across term boundaries**: Yes, term-independent
- **Handles rapid membership changes**: Yes, each change creates new ID

### Performance Impact

- **Validation overhead**: O(1) ID comparison
- **Memory overhead**: One uint64_t per peer
- **Network overhead**: None (no protocol changes)
- **CPU overhead**: Negligible (single comparison)

### Operational Benefits

- **Eliminates infinite retry loops**: Yes
- **Prevents resource exhaustion**: Yes
- **Reduces false alarms**: Yes
- **No manual intervention needed**: Yes

## References

### Source Files

- `peer.cxx` - RPC client validation logic
  - Lines 31-84: Request closure with captured RPC client
  - Lines 119-143: Response validation against current RPC client ID
  - Stale response counter for metrics

### Related Implementations

NuRaft's RPC client ID approach is similar to:

- **braft**: CallId-based session tracking with brpc framework
- **Apache Ratis**: CallId matching with RequestMap
- **sofa-jraft**: Version counter per replicator

The key difference is that NuRaft uses object identity (RPC client ID) rather than per-request IDs or version counters.