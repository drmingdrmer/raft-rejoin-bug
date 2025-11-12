# sofa-jraft Replication Progress Analysis

## Conclusion

**sofa-jraft does NOT have the replication progress corruption bug found in raft-rs.**

sofa-jraft implements a version-based session isolation mechanism that prevents delayed responses from old replication sessions from corrupting current progress tracking.

## Key Defense Mechanism

### Version Field

Location: `Replicator.java:131`

```java
private int version = 0;  // Replicator state reset version
```

The `version` field is incremented every time the replicator state is reset:

```java
void resetInflights() {
    this.version++;  // Increment version on reset
    this.inflights.clear();
    this.pendingResponses.clear();
    final int rs = Math.max(this.reqSeq, this.requiredNextSeq);
    this.reqSeq = this.requiredNextSeq = rs;
    releaseReader();
}
```

### Response Validation

Location: `Replicator.java:1274`

When an RPC response arrives, sofa-jraft validates the version:

```java
static void onRpcReturned(final ThreadId id, final RequestType reqType,
                          final Status status, final RpcRequestHeader request,
                          final Message response, final int seq,
                          final int stateVersion, final long rpcSendTime) {
    // ... lock replicator ...

    if (stateVersion != r.version) {
        LOG.debug(
            "Replicator {} ignored old version response {}, current version is {}",
            r, stateVersion, r.version);
        id.unlock();
        return;  // Ignore stale response
    }

    // Continue processing valid response
}
```

### Version Capture at Send Time

When sending an AppendEntries request, the current version is captured:

```java
// Location: Replicator.java:689
private void sendEntries(final long nextSendingIndex) {
    // ...
    final int stateVersion = this.version;  // Capture current version

    final RpcResponseClosure<AppendEntriesResponse> done = new RpcResponseClosureAdapter<AppendEntriesResponse>() {
        @Override
        public void run(final Status status) {
            onRpcReturned(Replicator.this.id, RequestType.AppendEntries,
                         status, request, getResponse(), seq,
                         stateVersion,  // Pass captured version
                         rpcSendTime);
        }
    };

    this.rpcService.appendEntries(/* ... */);
}
```

## How Membership Changes Are Handled

### Node Removal

Location: `ReplicatorGroupImpl.java`

```java
public boolean stopReplicator(final PeerId peer) {
    this.replicatorMap.remove(peer);  // Remove from map
    return Replicator.stop(rid);      // Destroy replicator
}
```

The entire `Replicator` instance is destroyed, including its `version` state.

### Node Re-addition

```java
public boolean addReplicator(final PeerId peer, final ReplicatorType replicatorType) {
    final ThreadId rid = Replicator.start(opts, this.raftOptions);  // Create NEW instance
    return this.replicatorMap.put(peer, rid) == null;
}
```

A completely new `Replicator` instance is created with `version = 0`.

## Bug Prevention Scenario

The raft-rs bug scenario would unfold as follows in sofa-jraft:

```
Time | Event                                       | State
-----|---------------------------------------------|------------------
T1   | Node C in cluster, version=5                | Send AppendEntries
     | Capture stateVersion=5 in closure           | (network delay)
     |                                             |
T2   | Node C removed                              | Replicator destroyed
     | stopReplicator(C) called                    |
     |                                             |
T3   | Node C re-added                             | New Replicator
     | New Replicator created with version=0       | version=0
     |                                             |
T4   | Delayed response arrives                    | Response carries
     | with stateVersion=5                         | stateVersion=5
     |                                             |
T5   | Response validation:                        | Response IGNORED ✓
     | stateVersion(5) != r.version(0)             | Bug prevented
     | LOG.debug("ignored old version response")   |
```

## Comparison with raft-rs

| Aspect | raft-rs | sofa-jraft |
|--------|---------|------------|
| Session identification | No explicit mechanism | `version` field |
| Progress structure lifecycle | Deleted and recreated | Entire Replicator destroyed/created |
| Response validation | Only term check | Term + version check |
| Stale response handling | Incorrectly applied | Explicitly ignored |
| Bug vulnerability | ✗ Vulnerable | ✓ Protected |

## Technical Details

### Version Increment Triggers

The `version` field is incremented when:

1. **`resetInflights()` is called** (line 1387)
   - Clears in-flight requests
   - Resets sequence numbers
   - Increments version

2. **Snapshot installation** may trigger reset
3. **Connection issues** may trigger reset

### Version Scope

The `version` is **per-Replicator** (per follower), not global:
- Each follower has its own `Replicator` instance
- Each `Replicator` has its own independent `version` counter
- When a node rejoins, it gets a fresh `Replicator` with `version=0`

### Implementation Pattern

sofa-jraft uses a closure-based pattern:
1. Capture current state (including `version`) when sending request
2. Pass captured state to response callback
3. Validate captured state against current state when response arrives
4. Ignore response if state has changed

This pattern is robust and doesn't require protocol changes.

## Recommendation

The sofa-jraft approach demonstrates a clean solution to the session isolation problem:

1. **No protocol changes required** - Works with existing message format
2. **Simple implementation** - Single integer version field
3. **Clear semantics** - Version mismatch = stale response
4. **Debuggable** - Explicit logging when responses are ignored

This approach could be adopted by raft-rs to fix the bug without requiring protocol buffer changes.
