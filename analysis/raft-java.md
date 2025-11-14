# raft-java - VULNERABLE

**Repository**: [wenweihu86/raft-java](https://github.com/wenweihu86/raft-java)
**Stars**: 1,234
**Language**: Java
**Status**: ✗ VULNERABLE

## Vulnerability Summary

raft-java is vulnerable to the replication session isolation bug due to **complete lack of request-response correlation**. The implementation has no mechanism to validate that AppendEntries responses correspond to current active requests. When a node is removed and rejoined, delayed responses from the old replication session can arrive and directly update the new session's progress tracking without any validation.

## How the Bug Occurs

### No Response Validation

The response handler performs zero validation on incoming responses:

**File**: `RaftNode.java:255-294`

```java
public void onReceiveAppendEntriesResponse(RaftProto.AppendEntriesResponse response,
                                          Peer peer) {
    // No validation of:
    // - Response freshness
    // - Request correlation
    // - Session identity
    // - Peer state

    // Directly update peer state
    if (response.getSuccess()) {
        peer.setMatchIndex(response.getLastLogIndex());
        peer.setNextIndex(response.getLastLogIndex() + 1);
    } else {
        peer.setNextIndex(response.getLastLogIndex() + 1);
    }

    // No check if this response is from current session
}
```

The implementation blindly trusts that any response with matching peer ID is valid and current.

### Peer Object Reuse

The implementation may reuse peer objects across sessions:

**File**: `RaftNode.java:406-412`

```java
public void addPeer(Peer peer) {
    peerMap.put(peer.getServerId(), peer);
    // May reuse existing peer object
    // No session isolation between old and new membership
}

public void removePeer(Peer peer) {
    peerMap.remove(peer.getServerId());
    // Peer object may still have pending RPCs
}
```

When a peer is removed and re-added:

1. Old peer object may still have in-flight RPCs
2. New peer object is added to map
3. Old responses may update wrong peer state
4. No mechanism to distinguish old vs new session

### No Correlation IDs

The protocol has no correlation identifiers:

**Message format** (inferred from code):

```protobuf
message AppendEntriesRequest {
    int64 term = 1;
    int64 prev_log_index = 2;
    int64 prev_log_term = 3;
    repeated LogEntry entries = 4;
    int64 leader_commit = 5;
    // Missing: request_id, session_id, version
}

message AppendEntriesResponse {
    int64 term = 1;
    bool success = 2;
    int64 last_log_index = 3;
    // Missing: request_id, session_id, version
}
```

No fields exist to correlate requests with responses or track sessions.

### Direct State Update

Progress tracking is updated directly without checks:

```java
// No validation before update
peer.setMatchIndex(response.getLastLogIndex());
peer.setNextIndex(response.getLastLogIndex() + 1);
```

There is no:

- Monotonicity check
- Range validation
- Session validation
- Staleness detection

## Attack Scenario

```
Timeline | Event                                    | Progress State
---------|------------------------------------------|------------------
T1       | Node C in cluster (term=5)               | peerMap[C].match = 50
         | Leader sends AppendEntries(index=50)     | RPC in flight
         | (network delay)                          |
         |                                          |
T2       | Node C removed from cluster              | peerMap.remove(C)
         | Peer object deleted from map             | C: [deleted]
         |                                          |
T3       | Node C rejoins cluster (term=5)          | peerMap[C] = new Peer()
         | New Peer object created                  | C.match = 0 (fresh)
         | match_index = 0, next_index = 1          |
         |                                          |
T4       | Delayed response arrives                 |
         | {from: C, term: 5, success: true,        |
         |  last_log_index: 50}                     |
         |                                          |
         | Handler logic:                           |
         | peer = peerMap.get(C)  // Gets NEW peer |
         | peer.setMatchIndex(50) // ❌ CORRUPTED  | C.match = 50 ✗
         | peer.setNextIndex(51)  // ❌ CORRUPTED  | C.next = 51 ✗
         |                                          |
T5       | Leader sends AppendEntries(prev=50)      | Wrong index!
         | Node C rejects (doesn't have index 50)   | success: false
         | Leader decrements next_index to 49       | C.next = 49
         |                                          |
T6       | Leader sends AppendEntries(prev=49)      | Still wrong!
         | Node C rejects again                     | Infinite loop begins
         | next_index decrements forever            | ♾️ Never converges
```

## Root Cause Analysis

### 1. Missing Request-Response Protocol

The implementation lacks fundamental request-response correlation:

```java
// What should exist but doesn't:
class AppendEntriesRequest {
    long requestId;  // ❌ Missing
    long sessionVersion;  // ❌ Missing
}

class AppendEntriesResponse {
    long requestId;  // ❌ Missing
    long sessionVersion;  // ❌ Missing
}

// Pending requests tracking:
Map<Long, PendingRequest> pendingRequests;  // ❌ Missing
```

### 2. No Session Lifecycle Management

There is no concept of replication sessions:

```java
// What should exist but doesn't:
class Peer {
    long sessionVersion;  // ❌ Missing

    void resetSession() {
        this.sessionVersion++;  // ❌ Missing
        // Clear in-flight requests
    }
}
```

### 3. Trust-Based Architecture

The implementation assumes all responses are valid:

```java
// Current (vulnerable) approach:
onReceiveResponse(response, peer) {
    // Trust response is current and valid
    updateProgress(response);
}

// Should be:
onReceiveResponse(response, peer) {
    if (!isValidResponse(response, peer)) {
        return;  // Reject stale
    }
    updateProgress(response);
}
```

### 4. No In-Flight Request Tracking

The implementation doesn't track which requests are pending:

```java
// Missing infrastructure:
- Queue of in-flight requests
- Request timeout tracking
- Response correlation
- Duplicate detection
```

## Recommended Solutions

### Solution 1: Add Version Counter (Simplest)

Add a session version to each peer and validate responses:

```java
class Peer {
    private long sessionVersion = 0;
    private long matchIndex = 0;
    private long nextIndex = 1;

    public void resetSession() {
        this.sessionVersion++;
        this.matchIndex = 0;
        this.nextIndex = 1;
        // Cancel all pending RPCs
    }
}

class AppendEntriesRequest {
    private long sessionVersion;
    // Include when sending
}

public void onReceiveAppendEntriesResponse(
        RaftProto.AppendEntriesResponse response,
        Peer peer,
        long requestSessionVersion) {

    // Validate session version
    if (requestSessionVersion != peer.getSessionVersion()) {
        LOG.debug("Stale response from old session, ignoring");
        return;  // Reject stale response
    }

    // Now safe to update progress
    if (response.getSuccess()) {
        peer.setMatchIndex(response.getLastLogIndex());
        peer.setNextIndex(response.getLastLogIndex() + 1);
    }
}
```

### Solution 2: Request ID Correlation

Implement proper request-response correlation:

```java
class RequestTracker {
    private AtomicLong nextRequestId = new AtomicLong(0);
    private Map<Long, PendingRequest> pending = new ConcurrentHashMap<>();

    public long sendRequest(Peer peer, AppendEntriesRequest req) {
        long requestId = nextRequestId.incrementAndGet();
        pending.put(requestId, new PendingRequest(peer, req, System.currentTimeMillis()));
        return requestId;
    }

    public PendingRequest validateResponse(long requestId) {
        PendingRequest req = pending.remove(requestId);
        if (req == null) {
            // Stale or duplicate response
            return null;
        }
        return req;
    }
}

public void onReceiveAppendEntriesResponse(
        RaftProto.AppendEntriesResponse response,
        long requestId) {

    PendingRequest pending = requestTracker.validateResponse(requestId);
    if (pending == null) {
        LOG.debug("Response for unknown request {}, ignoring", requestId);
        return;
    }

    Peer peer = pending.getPeer();
    // Safe to update - response is validated
    updatePeerProgress(peer, response);
}
```

### Solution 3: Configuration Membership Validation

Validate responses are from current configuration members:

```java
public void onReceiveAppendEntriesResponse(
        RaftProto.AppendEntriesResponse response,
        int peerId) {

    // Check peer is in current configuration
    Peer peer = peerMap.get(peerId);
    if (peer == null) {
        LOG.warn("Received response from unknown peer {}", peerId);
        return;  // Not in current configuration
    }

    // Additional validation could check configuration version
    if (peer.getConfigurationVersion() != currentConfiguration.getVersion()) {
        LOG.debug("Response from old configuration, ignoring");
        return;
    }

    updatePeerProgress(peer, response);
}
```

### Solution 4: Monotonicity Validation

Add basic staleness detection:

```java
public void onReceiveAppendEntriesResponse(
        RaftProto.AppendEntriesResponse response,
        Peer peer) {

    // Reject responses that would move matchIndex backward
    if (response.getLastLogIndex() < peer.getMatchIndex()) {
        LOG.debug("Stale response with index {} < current match {}",
                 response.getLastLogIndex(), peer.getMatchIndex());
        return;
    }

    // Update progress
    peer.setMatchIndex(response.getLastLogIndex());
    peer.setNextIndex(response.getLastLogIndex() + 1);
}
```

Note: This is insufficient for the surveyed bug (where match_index=0 on rejoin), but provides basic protection.

## Impact Assessment

### Vulnerability Severity

- **Trigger probability**: Medium to High
  - Membership changes are common
  - Network delays occur regularly
  - Same-term remove/rejoin is possible

- **Impact scope**: Operational
  - Infinite retry loops
  - Resource exhaustion (CPU, network)
  - Reduced cluster health
  - Manual intervention required

- **Data safety**: Not compromised
  - Commit protocol still works correctly
  - No data loss or corruption
  - Safety properties maintained

### Operational Consequences

When the bug triggers:

1. **Immediate effects**:
   - Leader sends wrong log indices to rejoined node
   - Node rejects all AppendEntries (index mismatch)
   - Infinite retry loop begins

2. **Resource impact**:
   - High CPU usage on leader (continuous retries)
   - Network bandwidth waste (failed RPCs)
   - Log spam (rejection messages)

3. **Cluster impact**:
   - Rejoined node never catches up
   - Reduced fault tolerance (fewer healthy replicas)
   - Potential performance degradation

4. **Resolution**:
   - Requires manual intervention (leader restart or node removal)
   - Temporary workaround: Remove and re-add with term change
   - Permanent fix: Implement session isolation

### Real-World Scenarios

Likely to occur in:

- **Dynamic clusters**: Frequent membership changes for scaling
- **Network chaos testing**: Simulated delays and partitions
- **Automated operations**: Scripts that remove/add nodes
- **Fast-changing topologies**: Cloud environments with node churn

## References

### Source Files

- `RaftNode.java:255-294` - Response handler with no validation
- `RaftNode.java:406-412` - Peer add/remove without session isolation

### Vulnerable Code Patterns

```java
// Pattern 1: No validation
onReceiveResponse(response, peer) {
    peer.updateProgress(response);  // ❌ Blind trust
}

// Pattern 2: No correlation
sendRequest(request) {
    rpc.send(request);  // ❌ No request ID
}

// Pattern 3: No session tracking
removePeer(peer) {
    peers.remove(peer);  // ❌ No session cleanup
}
addPeer(peer) {
    peers.add(peer);  // ❌ No version increment
}
```

### Similar Vulnerable Implementations

raft-java shares vulnerabilities with:

- **hashicorp/raft**: No session isolation
- **dragonboat**: Term-only validation
- **etcd-io/raft**: No request correlation
- **PySyncObj**: Zero validation

### Protected Implementations to Learn From

Study these for reference:

- **sofa-jraft**: Version counter per replicator (Java, similar language)
- **Apache Ratis**: CallId correlation (Java, similar language)
- **braft**: CallId-based session tracking (production-proven)
