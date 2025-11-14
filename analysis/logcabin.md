# LogCabin - VULNERABLE

**Repository**: [logcabin/logcabin](https://github.com/logcabin/logcabin)
**Stars**: 1,945
**Language**: C++
**Status**: ✗ VULNERABLE

## Vulnerability Summary

LogCabin is vulnerable to the replication session isolation bug due to **insufficient epoch validation**. While the implementation tracks an epoch counter for leadership changes, it does not use this epoch to validate AppendEntries responses. The epoch check in the response handler only validates leadership status, not whether the response belongs to the current replication session. When a node is removed and rejoined within the same epoch, delayed responses from the old session can corrupt the new session's progress tracking.

## How the Bug Occurs

### Insufficient Epoch Validation

The response handler has epoch tracking but doesn't validate response freshness:

**File**: `RaftConsensus.cc:2309-2371`

```cpp
void RaftConsensus::handleAppendEntriesResponse(
    const Server& server,
    const Protocol::Raft::AppendEntries::Response& response) {

    // Line 2323: Epoch check only validates leadership
    if (response.epoch() != currentEpoch) {
        // Only used to detect leadership changes
        // NOT used to validate response session
        NOTICE("Ignoring response from old epoch");
        return;
    }

    // Line 2340: Check peer.exiting flag
    if (peer.exiting) {
        // Only catches peers marked as exiting
        // Doesn't catch responses from already-removed peers
        return;
    }

    // Lines 2350-2365: Direct progress update without session validation
    if (response.success()) {
        peer.matchIndex = response.matchIndex();
        peer.nextIndex = response.matchIndex() + 1;
    } else {
        peer.nextIndex = response.nextIndex();
    }

    // No validation that response is from current session
}
```

### Epoch Lifecycle Problem

The epoch counter is only incremented on leadership changes, not membership changes:

```cpp
void RaftConsensus::becomeLeader() {
    currentEpoch++;  // New epoch on leadership change
    // ...
}

void RaftConsensus::addServer(ServerId serverId) {
    // Epoch NOT incremented on membership change
    // Same epoch used before and after node rejoin
}

void RaftConsensus::removeServer(ServerId serverId) {
    // Epoch NOT incremented on membership change
}
```

This means:

1. Node removed at epoch N
2. Node rejoined at epoch N (same epoch)
3. Delayed responses from before removal still have epoch N
4. Epoch validation passes, response accepted

### New Peer Creation

When a peer rejoins, it gets zero state but keeps the same epoch:

**File**: `RaftConsensus.cc:727-738`

```cpp
void RaftConsensus::addPeer(uint64_t serverId) {
    Peer peer;
    peer.serverId = serverId;
    peer.nextIndex = log->getLastLogIndex() + 1;
    peer.matchIndex = 0;  // Fresh state
    peer.exiting = false;
    peer.lastAckEpoch = 0;

    // No session identifier
    // Same epoch as before removal

    configuration->addServer(serverId, peer);
}
```

### No Request-Response Correlation

The implementation has no mechanism to correlate responses with requests:

```cpp
// Request sending (simplified):
void sendAppendEntries(Peer& peer) {
    AppendEntriesRequest request;
    request.set_epoch(currentEpoch);
    request.set_prev_log_index(peer.nextIndex - 1);
    // No request ID
    // No session version

    rpc->call(peer.serverId, request);
}

// Response handling:
void handleAppendEntriesResponse(const Response& response) {
    // No way to match response to specific request
    // No way to detect stale responses within same epoch
}
```

## Attack Scenario

```
Timeline | Event                                    | State
---------|------------------------------------------|------------------
T1       | Leader L elected (term=5, epoch=10)      | epoch = 10
         | Node C in cluster                        | C: match=50, epoch=10
         | Leader sends AppendEntries(index=50)     | Request epoch=10
         | (network delay)                          |
         |                                          |
T2       | Node C removed from cluster              | C: [deleted]
         | peer.exiting = true                      | epoch still 10
         | Configuration change applied             | (no epoch change)
         |                                          |
T3       | Node C rejoins cluster (term=5)          | epoch still 10
         | New Peer object created                  | C: match=0
         | peer.exiting = false                     | peer.lastAckEpoch=0
         |                                          |
T4       | Delayed response arrives                 |
         | {epoch: 10, success: true,               |
         |  matchIndex: 50}                         |
         |                                          |
         | Validation checks:                       |
         | if (epoch != currentEpoch)               | 10 == 10 ✓ Pass
         | if (peer.exiting)                        | false ✓ Pass
         | -> Validation passes! ❌                 |
         |                                          |
         | Progress update:                         |
         | peer.matchIndex = 50  // ❌ CORRUPTED   | C.match = 50 ✗
         | peer.nextIndex = 51   // ❌ CORRUPTED   | C.next = 51 ✗
         |                                          |
T5       | Leader sends AppendEntries(prev=50)      | Wrong index!
         | Node C rejects (doesn't have index 50)   | Conflict
         | Leader decrements nextIndex              | Retry
         |                                          |
T6       | Infinite retry loop begins               | ♾️ Never converges
```

## Root Cause Analysis

### 1. Epoch Scope Too Broad

The epoch counter tracks leadership changes, not replication sessions:

```cpp
// Epoch increments:
becomeLeader()      -> epoch++  ✓
stepDown()          -> No change
addServer()         -> No change  ❌
removeServer()      -> No change  ❌
```

A single epoch can span:

- Multiple membership changes
- Multiple remove/rejoin cycles for same node
- Many distinct replication sessions

### 2. Missing Session Abstraction

The code has no concept of replication sessions:

```cpp
// What exists:
struct Peer {
    uint64_t matchIndex;
    uint64_t nextIndex;
    bool exiting;
    uint64_t lastAckEpoch;  // Tracks last ack, not session
};

// What's missing:
struct Peer {
    uint64_t sessionVersion;  // ❌ Missing
    std::queue<PendingRequest> inflightRequests;  // ❌ Missing
};
```

### 3. Insufficient Validation Gates

The validation logic has gaps:

```cpp
// Current validation:
if (epoch != currentEpoch) return;  // Too coarse
if (peer.exiting) return;           // Only catches exiting flag

// Missing validations:
if (response.sessionVersion != peer.sessionVersion) return;
if (!hasPendingRequest(response.requestId)) return;
if (response.matchIndex < peer.matchIndex) return;
```

### 4. peer.exiting Flag Limitation

The `peer.exiting` flag only protects during removal, not after:

```
T1: removeServer(C) -> peer.exiting = true   ✓ Responses rejected
T2: Configuration change complete -> peer deleted
T3: addServer(C) -> new peer, exiting = false
T4: Old response arrives -> exiting = false  ❌ Accepted
```

## Recommended Solutions

### Solution 1: Increment Epoch on Membership Changes

Make epoch track replication sessions, not just leadership:

```cpp
void RaftConsensus::addServer(ServerId serverId) {
    currentEpoch++;  // New epoch on membership change

    Peer peer;
    peer.serverId = serverId;
    peer.nextIndex = log->getLastLogIndex() + 1;
    peer.matchIndex = 0;
    peer.lastAckEpoch = currentEpoch;  // Current epoch

    configuration->addServer(serverId, peer);
}

void RaftConsensus::removeServer(ServerId serverId) {
    currentEpoch++;  // New epoch on membership change
    configuration->removeServer(serverId);
}
```

This ensures:

- Each membership change gets a new epoch
- Delayed responses from before change have old epoch
- Epoch validation rejects stale responses

### Solution 2: Add Per-Peer Session Version

Add a session version counter to each peer:

```cpp
struct Peer {
    uint64_t serverId;
    uint64_t matchIndex;
    uint64_t nextIndex;
    uint64_t sessionVersion;  // New field
    bool exiting;
};

void RaftConsensus::addPeer(uint64_t serverId) {
    Peer peer;
    peer.serverId = serverId;
    peer.sessionVersion = nextSessionVersion++;  // Unique version
    peer.matchIndex = 0;
    peer.nextIndex = log->getLastLogIndex() + 1;

    configuration->addServer(serverId, peer);
}

void RaftConsensus::handleAppendEntriesResponse(
    const Server& server,
    const Protocol::Raft::AppendEntries::Response& response) {

    Peer& peer = getPeer(server.serverId);

    // Validate session version
    if (response.sessionVersion() != peer.sessionVersion) {
        LOG(INFO) << "Stale response from old session, ignoring";
        return;
    }

    // Safe to update progress
    updatePeerProgress(peer, response);
}
```

### Solution 3: Request ID Correlation

Track in-flight requests and validate responses:

```cpp
struct PendingRequest {
    uint64_t requestId;
    uint64_t serverId;
    uint64_t prevLogIndex;
    uint64_t timestamp;
};

class RaftConsensus {
private:
    uint64_t nextRequestId = 0;
    std::map<uint64_t, PendingRequest> pendingRequests;

public:
    void sendAppendEntries(Peer& peer) {
        uint64_t requestId = nextRequestId++;

        AppendEntriesRequest request;
        request.set_request_id(requestId);
        request.set_epoch(currentEpoch);
        request.set_prev_log_index(peer.nextIndex - 1);

        pendingRequests[requestId] = PendingRequest{
            requestId, peer.serverId, peer.nextIndex - 1, now()
        };

        rpc->call(peer.serverId, request);
    }

    void handleAppendEntriesResponse(const Response& response) {
        auto it = pendingRequests.find(response.request_id());
        if (it == pendingRequests.end()) {
            LOG(INFO) << "Response for unknown request, ignoring";
            return;  // Stale or duplicate
        }

        PendingRequest& pending = it->second;
        Peer& peer = getPeer(pending.serverId);

        // Process response
        updatePeerProgress(peer, response);

        // Remove from pending
        pendingRequests.erase(it);
    }
};
```

### Solution 4: Enhanced Monotonicity Checks

Add validation to detect backward progress:

```cpp
void RaftConsensus::handleAppendEntriesResponse(
    const Server& server,
    const Protocol::Raft::AppendEntries::Response& response) {

    Peer& peer = getPeer(server.serverId);

    // Reject responses that would move matchIndex backward
    if (response.success() && response.matchIndex() < peer.matchIndex) {
        LOG(WARNING) << "Stale response with matchIndex "
                    << response.matchIndex()
                    << " < current " << peer.matchIndex;
        return;
    }

    // Update progress
    updatePeerProgress(peer, response);
}
```

Note: This is insufficient for the surveyed bug (where matchIndex=0 on rejoin), but provides defense in depth.

## Impact Assessment

### Vulnerability Severity

- **Trigger probability**: Medium
  - Requires membership change without leadership change
  - Network delays must align with rejoin timing
  - More likely in stable leadership with dynamic membership

- **Impact scope**: Operational
  - Infinite retry loops for rejoined node
  - Resource exhaustion (CPU, network, logs)
  - Reduced cluster fault tolerance
  - Requires manual intervention

- **Data safety**: Not compromised
  - Raft commit protocol still correct
  - No data loss or corruption
  - Safety properties maintained

### Operational Consequences

When the bug triggers:

1. **Immediate symptoms**:
   - Rejoined node never catches up
   - Continuous AppendEntries retries
   - Log entries showing index conflicts

2. **Resource impact**:
   - High CPU on leader (retry loop)
   - Network bandwidth waste
   - Disk I/O for logging

3. **Cluster health**:
   - One node perpetually behind
   - Reduced redundancy
   - Potential quorum issues if multiple nodes affected

4. **Mitigation**:
   - Restart leader (forces new epoch)
   - Remove and re-add node after leadership change
   - Wait for term change before rejoin

### Why Epoch Tracking Wasn't Enough

LogCabin's epoch mechanism was designed for leadership tracking, not session isolation:

**Original purpose**: Detect leadership changes and reject responses from old leaders.

**Actual need**: Distinguish responses from different replication sessions within the same leadership.

**Gap**: Epoch increments only on `becomeLeader()`, not on `addServer()`/`removeServer()`.

## References

### Source Files

- `RaftConsensus.cc:2309-2371` - Response handler with insufficient epoch validation
- `RaftConsensus.cc:2323` - Epoch check that only validates leadership, not session
- `RaftConsensus.cc:727-738` - New peer creation with zero state but same epoch

### Vulnerable Code Patterns

```cpp
// Pattern 1: Epoch scope too broad
becomeLeader() { epoch++; }
addServer() { /* no epoch change */ }  // ❌

// Pattern 2: Insufficient validation
if (epoch != currentEpoch) return;  // Not enough
if (peer.exiting) return;           // Not enough

// Pattern 3: No request correlation
sendRequest(request);  // ❌ No request ID
handleResponse(response);  // ❌ No correlation
```

### Similar Vulnerable Implementations

LogCabin shares vulnerabilities with:

- **hashicorp/raft**: Term-only validation (similar scope issue)
- **dragonboat**: Term-based validation insufficient
- **raft-rs**: No session tracking

### Protected Implementations to Learn From

Study these for reference:

- **braft**: CallId-based session tracking (C++, similar language)
- **NuRaft**: RPC client ID validation (C++, similar language)
- **sofa-jraft**: Version counter shows how to extend epoch concept
- **Apache Ratis**: CallId correlation demonstrates proper request tracking
