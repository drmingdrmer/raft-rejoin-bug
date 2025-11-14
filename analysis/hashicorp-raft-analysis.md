# hashicorp/raft Replication Progress Analysis

## Conclusion

**hashicorp/raft IS VULNERABLE to the replication progress corruption bug found in raft-rs.**

hashicorp/raft lacks a session isolation mechanism to prevent delayed responses from old replication sessions from corrupting current progress tracking.

## Vulnerability Analysis

### Progress Tracking Structure

Location: `replication.go:33-96`

```go
type followerReplication struct {
    peer            Server
    commitment      *commitment
    stopCh          chan uint64
    triggerCh       chan struct{}
    triggerDeferErrorCh chan *deferError
    currentTerm     uint64
    nextIndex       uint64    // Next log index to send
    lastContact     time.Time
    failures        uint64
    notifyCh        chan struct{}
    notify          []*verifyFuture
    notifyLock      sync.Mutex
    stepDown        chan struct{}
    allowPipeline   bool
}
```

The `nextIndex` field tracks the next log index to send to this follower. Unlike sofa-jraft, there is **no version or generation field** to identify the replication session.

### Membership Change Handling

Location: `raft.go:534-597`

#### Node Removal

```go
// lines 582-593
for serverID, repl := range r.leaderState.replState {
    if inConfig[serverID] {
        continue
    }
    r.logger.Info("removed peer, stopping replication", "peer", serverID)
    repl.stopCh <- lastIdx
    close(repl.stopCh)
    delete(r.leaderState.replState, serverID)  // DELETE the record
}
```

The `followerReplication` object is deleted from the map.

#### Node Re-addition

```go
// lines 546-565
for _, server := range r.configurations.latest.Servers {
    if server.ID == r.localID {
        continue
    }
    s, ok := r.leaderState.replState[server.ID]
    if !ok {
        r.logger.Info("added peer, starting replication", "peer", server.ID)
        s = &followerReplication{  // CREATE new record
            peer:        server,
            commitment:  r.leaderState.commitment,
            stopCh:      make(chan uint64, 1),
            triggerCh:   make(chan struct{}, 1),
            currentTerm: r.getCurrentTerm(),
            nextIndex:   lastIdx + 1,
            // ... other fields
        }
        r.leaderState.replState[server.ID] = s
        r.goFunc(func() { r.replicate(s) })
    }
}
```

A completely new `followerReplication` object is created, but with **no session identifier** that distinguishes it from the previous instance.

### Response Handling - The Vulnerability

Location: `replication.go`

#### Non-pipeline Mode

```go
// lines 238-263
func (r *Raft) sendLatestSnapshot(s *followerReplication) (bool, error) {
    // ... send snapshot ...

    // Check the response
    if resp.Success {
        // Update follower indexes
        updateLastAppended(s, &req)  // ← NO session validation
        s.failures = 0
        s.allowPipeline = true
    }
    return true, nil
}
```

#### Pipeline Mode

```go
// lines 530-553
case ready := <-respCh:
    req, resp := ready.Request(), ready.Response()

    // Check for newer term, stop running
    if resp.Term > req.Term {
        r.handleStaleTerm(s)
        return
    }

    // Update the lastContact
    s.lastContact = time.Now()

    // Fail if not successful
    if !resp.Success {
        return
    }

    // Update our replication state
    updateLastAppended(s, req)  // ← NO session validation
```

#### The updateLastAppended Function

```go
// lines 643-653
func updateLastAppended(s *followerReplication, req *AppendEntriesRequest) {
    // Mark any inflight logs as committed
    if logs := req.Entries; len(logs) > 0 {
        last := logs[len(logs)-1]
        atomic.StoreUint64(&s.nextIndex, last.Index+1)  // DIRECTLY updates nextIndex
        s.commitment.match(s.peer.ID, last.Index)       // Updates commit tracker
    }

    // Notify all the waiting verification futures
    s.notifyAll(true)
}
```

**Critical issue**: The `updateLastAppended` function:
1. Directly updates `nextIndex` with no validation
2. Updates the commit matcher with potentially stale data
3. Has no check that the response belongs to the current replication session

### Message Format

Location: `commands.go:27-69`

```go
type AppendEntriesRequest struct {
    RPCHeader
    Term              uint64
    Leader            []byte
    PrevLogEntry      uint64
    PrevLogTerm       uint64
    Entries           []*Log
    LeaderCommitIndex uint64
}

type AppendEntriesResponse struct {
    RPCHeader
    Term           uint64
    LastLog        uint64
    Success        bool
    NoRetryBackoff bool
}
```

The messages contain **only term information**, no session identifier.

### Validation Performed

The only validation performed is term checking:

```go
// replication.go:534
if resp.Term > req.Term {
    r.handleStaleTerm(s)
    return
}
```

This checks if the follower has moved to a newer term, but **does not protect against stale responses within the same term**.

## Bug Reproduction Scenario

```
Time | Event                                       | State
-----|---------------------------------------------|------------------
T1   | log=50, members={a,b,c}                     | C: nextIndex=50
     | Leader sends AppendEntries(45-50) to C      | Request in flight
     | (Network delay)                             |
     |                                             |
T2   | log=60, members={a,b}                       | C: [deleted]
     | Node C removed from cluster                 | replState[C] deleted
     |                                             |
T3   | log=100, members={a,b,c}                    | C: nextIndex=101
     | Node C rejoins cluster                      | New followerReplication
     |                                             | created
T4   | Delayed response from T1 arrives            |
     | {Success: true, LastLog: 50}                |
     | Term check passes (same term)               |
     | updateLastAppended() called                 |
     | → nextIndex = 51                            | C: nextIndex=51 ❌
     | → commitment.match(C, 50)                   | Corrupted!
     |                                             |
T5   | Leader sends AppendEntries(prev=50)         |
     | Node C rejects (doesn't have index 50)      |
     | Infinite retry loop begins                  |
```

## Comparison Table

| Aspect | raft-rs | sofa-jraft | hashicorp/raft |
|--------|---------|------------|----------------|
| Session identification | No | Yes (`version` field) | No |
| Progress lifecycle | Delete/recreate | Destroy/create new object | Delete/recreate |
| Response validation | Only term | Term + version | Only term |
| Stale response handling | Incorrectly applied | Explicitly ignored | Incorrectly applied |
| Bug vulnerability | ✗ Vulnerable | ✓ Protected | ✗ Vulnerable |

## Why hashicorp/raft is Vulnerable

1. **No session isolation mechanism**: Unlike sofa-jraft which has a `version` field that increments on reset, hashicorp/raft has no way to identify which replication session a response belongs to.

2. **Direct state update**: The `updateLastAppended()` function directly updates `nextIndex` and `commitment` without any validation that the response is from the current session.

3. **Term-only validation**: The code only checks if `resp.Term > req.Term`, which detects when the follower has moved to a newer term but **cannot detect stale responses within the same term**.

4. **Membership changes don't change term**: A node can be removed and re-added within the same term, making term-based validation insufficient.

## Impact

The impact is similar to raft-rs:
- **Data safety**: Not compromised (commit index calculation still correct)
- **Operational issues**:
  - Infinite retry loops
  - Resource exhaustion
  - Nodes unable to catch up
  - Misleading error messages

## Potential Solutions

### Solution 1: Add Version Field (Similar to sofa-jraft)

```go
type followerReplication struct {
    // ... existing fields ...
    version uint64  // Incremented on reset
}

func (r *Raft) startStopReplication() {
    // When creating new replication
    s = &followerReplication{
        version: 0,  // Start with version 0
        // ...
    }
}

// Capture version when sending
type appendFuture struct {
    // ... existing fields ...
    version uint64  // Captured version
}

// Validate on response
func handleAppendEntries(resp *AppendEntriesResponse, req *appendFuture, s *followerReplication) {
    if req.version != s.version {
        // Ignore stale response
        return
    }
    updateLastAppended(s, req)
}
```

### Solution 2: Add Membership Version to Messages

Add a `configIndex` field to AppendEntries messages that identifies which membership configuration the message belongs to. This requires protocol changes.

### Solution 3: Stricter Log Validation

Validate that the response's `LastLog` matches the local log term before updating progress. This is less robust but doesn't require new fields.

## Recommendation

hashicorp/raft should implement a version-based session isolation mechanism similar to sofa-jraft (Solution 1). This approach:
- Requires no protocol changes
- Is simple to implement (single uint64 field)
- Has clear semantics
- Is debuggable

Alternatively, the codebase could adopt the membership version approach (Solution 2) for more explicit session tracking, but this requires protocol changes and coordination across all implementations.
