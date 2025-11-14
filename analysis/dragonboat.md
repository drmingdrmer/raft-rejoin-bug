# dragonboat Replication Session Bug Analysis

**Repository**: https://github.com/lni/dragonboat
**Stars**: 5,262
**Language**: Go
**Status**: ✗ VULNERABLE

## Vulnerability Summary

dragonboat is vulnerable to the replication session isolation bug. It uses term-only validation without any session tracking mechanism, allowing delayed AppendEntries responses from old replication sessions to corrupt progress tracking after a node rejoins.

## How the Bug Occurs

### 1. Progress Tracking Without Session ID

File: [`internal/raft/remote.go:72-80`](https://github.com/lni/dragonboat/blob/master/internal/raft/remote.go#L72-L80)

```go
type remote struct {
    next   uint64
    match  uint64
    state  remoteState
    // No session version or ID field
}
```

The `remote` struct tracks replication progress but has no field to identify which replication session the progress belongs to.

### 2. Response Handling Without Validation

File: [`internal/raft/raft.go:1878-1907`](https://github.com/lni/dragonboat/blob/master/internal/raft/raft.go#L1878-L1907)

```go
func (r *raft) handleAppendEntriesResponse(from uint64, resp pb.MessageResp) {
    remote := r.remotes[from]
    if resp.Reject {
        // Handle rejection
    } else {
        // Direct update without session validation
        remote.respondedTo()
        remote.tryUpdate(resp.LogIndex)
    }
}
```

The handler updates progress directly based on the response without checking if the response belongs to the current replication session.

### 3. Critical Flaw: Wrapper Always Passes Current Pointer

The `lw()` wrapper captures the current remote pointer in closures, but when a node is removed and re-added, the pointer changes. However, delayed responses with the old pointer can still arrive and the system doesn't validate that the response corresponds to the current session.

## Attack Scenario

```
Timeline | Event                                    | Progress State
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | C: match=50
         | Leader sends AppendEntries(index=50)     | (network delay)
         |                                          |
T2       | Node C removed from cluster              | C: [deleted]
         | remote[C] deleted from remotes map       |
         |                                          |
T3       | Node C rejoins cluster                   | C: match=0 (new)
         | New remote[C] created                    |
         |                                          |
T4       | Delayed response arrives                 | C: match=50 ❌
         | {from: C, index: 50, success: true}      | Corrupted!
         | handleAppendEntriesResponse() updates    |
         |                                          |
T5       | Leader sends AppendEntries(prev=50)      |
         | Node C rejects (doesn't have index 50)   |
         | Infinite loop begins                     |
```

## Root Cause

1. **No session identifier**: The `remote` struct lacks any field to identify which replication session it belongs to
2. **Term-only validation**: Only checks message term, not sufficient when membership changes occur within same term
3. **No request-response correlation**: No mechanism to match responses with pending requests

## Recommended Solutions

### Solution 1: Add Version Counter (Simplest)

```go
type remote struct {
    next    uint64
    match   uint64
    state   remoteState
    version uint64  // Add this field
}

func (r *remote) reset() {
    r.version++  // Increment on reset
    r.next = 0
    r.match = 0
}

func (r *raft) handleAppendEntriesResponse(from uint64, resp pb.MessageResp, reqVersion uint64) {
    remote := r.remotes[from]
    if remote.version != reqVersion {
        // Stale response from old session
        return
    }
    // Process response
}
```

### Solution 2: Request ID Correlation

```go
type pendingRequest struct {
    requestID uint64
    logIndex  uint64
    sentTime  time.Time
}

type remote struct {
    next           uint64
    match          uint64
    state          remoteState
    pendingReqs    map[uint64]*pendingRequest
    nextRequestID  uint64
}

func (r *remote) sendRequest(index uint64) uint64 {
    reqID := r.nextRequestID
    r.nextRequestID++
    r.pendingReqs[reqID] = &pendingRequest{
        requestID: reqID,
        logIndex:  index,
        sentTime:  time.Now(),
    }
    return reqID
}

func (r *raft) handleAppendEntriesResponse(from uint64, resp pb.MessageResp) {
    remote := r.remotes[from]
    req, exists := remote.pendingReqs[resp.RequestID]
    if !exists {
        // Stale response, request already canceled or timed out
        return
    }
    delete(remote.pendingReqs, resp.RequestID)
    // Process response
}
```

### Solution 3: Membership Validation

```go
func (r *raft) handleAppendEntriesResponse(from uint64, resp pb.MessageResp) {
    // Check if sender is still in current configuration
    if !r.isMemberInCurrentConfig(from) {
        // Response from node that's no longer a member
        return
    }
    remote := r.remotes[from]
    // Process response
}
```

## Impact Assessment

**Data Safety**: ✓ Not compromised (Raft's commit protocol ensures correctness)

**Operational Impact**: ✗ Significant
- Infinite retry loops when progress is corrupted
- Resource exhaustion from continuous failed replication
- Misleading error logs that may appear as data corruption
- Manual intervention required to recover

## References

- Progress tracking: `internal/raft/remote.go:72-80`
- Response handling: `internal/raft/raft.go:1878-1907`
- Message protocol: No session ID in message format
