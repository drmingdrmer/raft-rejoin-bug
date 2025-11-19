# Replication Session Isolation Bug Survey

This survey analyzes popular Raft implementations for a replication progress corruption bug that occurs during membership changes. The bug allows delayed AppendEntries responses from old replication sessions to corrupt progress tracking after a node is removed and rejoined.

## The Bug: A Concrete Example with raft-rs

We use **raft-rs** (TiKV's Raft library, 3,224 stars) as a concrete example to demonstrate how this bug occurs.

### How raft-rs Tracks Replication Progress

File: [`src/tracker/progress.rs:8-56`](https://github.com/tikv/raft-rs/blob/master/src/tracker/progress.rs#L8-L56)

```rust
pub struct Progress {
    pub matched: u64,      // Highest log index known to be replicated
    pub next_idx: u64,     // Next log index to send
    pub state: ProgressState,
    pub pending_snapshot: u64,
    // No session version or ID field!
}
```

The leader maintains a `Progress` struct for each follower. When a follower successfully replicates log entries, the leader updates `matched` and `next_idx`.

### The Vulnerable Update Logic

File: [`src/tracker/progress.rs:136-148`](https://github.com/tikv/raft-rs/blob/master/src/tracker/progress.rs#L136-L148)

```rust
pub fn maybe_update(&mut self, n: u64) -> bool {
    let need_update = self.matched < n;  // Only checks monotonicity
    if need_update {
        self.matched = n;
        self.next_idx = n + 1;
        self.resume();
    }
    need_update
}
```

**The problem**: `maybe_update` only checks if the new index is higher than current `matched`. After a node rejoins, `matched` is reset to 0, so **any delayed response with index > 0 will be accepted**.

### Attack Scenario with raft-rs

```
Timeline | Event                                    | Progress State
---------|------------------------------------------|------------------
T1       | Node C in cluster, term=5                | C: matched=50
         | Leader sends AppendEntries(index=50)     | (network delay)
         |                                          |
T2       | Node C removed from cluster              | C: [deleted]
         | Progress[C] removed from tracker         |
         |                                          |
T3       | Node C rejoins cluster (still term=5)    | C: matched=0 (new)
         | New Progress[C] created                  |
         |                                          |
T4       | Delayed response arrives                 | C: matched=50 ❌
         | {from: C, index: 50, success: true}      | Corrupted!
         | maybe_update(50) returns true            | (50 > 0) ✓
         | matched set to 50, next_idx to 51        |
         |                                          |
T5       | Leader sends AppendEntries(prev=50)      |
         | Node C rejects (actual log < 50)         |
         | Leader decrements next_idx               |
         | But delayed responses keep resetting it! |
         | Infinite loop continues                  |
```

### Why Monotonicity Check Is Insufficient

After node C rejoins:
- New `Progress[C]` has `matched=0`
- Delayed response arrives with `index=50`
- `maybe_update(50)` checks: `0 < 50` → **true** ✓
- Progress corrupted to `matched=50` even though C's actual log is empty!

### Root Cause

1. **No session isolation**: `Progress` struct lacks session identifier
2. **Monotonicity check insufficient**: Works within a session, fails across session boundaries
3. **Term-only validation**: Cannot distinguish messages from different membership configurations within same term
4. **No request-response correlation**: No mechanism to match responses with sent requests

### Impact

**Operational problems**:
- Infinite retry loops - Leader sends wrong log indices
- Resource exhaustion - Continuous failed replication attempts
- TiKV nodes unable to replicate data
- Manual restart required to recover

**Data safety**:
- ✓ Not compromised - Raft's commit protocol still ensures safety
- The bug causes operational issues, not data loss

## How to Fix It in raft-rs

### Add Version Counter (Recommended)

Modify the `Progress` struct to include a session version:

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub state: ProgressState,
    pub pending_snapshot: u64,
    pub session_version: u64,  // ← Add this field
}

impl Progress {
    pub fn reset(&mut self) {
        self.session_version += 1;  // ← Increment on reset
        self.matched = 0;
        self.next_idx = 1;
        self.state = ProgressState::Probe;
    }

    pub fn maybe_update(&mut self, n: u64, response_version: u64) -> bool {
        // ← Validate session first
        if response_version != self.session_version {
            return false;  // Reject stale response
        }

        let need_update = self.matched < n;
        if need_update {
            self.matched = n;
            self.next_idx = n + 1;
            self.resume();
        }
        need_update
    }
}
```

**Why this works**:
- When node C is removed at T2, `Progress[C]` is deleted
- When node C rejoins at T3, new `Progress[C]` created with `session_version=0`
- First `reset()` call increments to `session_version=1`
- At T4, delayed response has `response_version=0` (from old session)
- Validation fails: `0 != 1` → response rejected ✓

**Benefits**:
- No protocol changes needed
- Minimal code changes
- Zero performance overhead

## General Solutions for Other Implementations

The version counter approach shown above can be adapted to any implementation. Other protection mechanisms found in surveyed implementations:

### Membership Log ID Tracking

Include the log ID where membership was committed in session identifier. Explicit session boundary at membership changes.

### CallId/Request Correlation

Assign unique ID to each request, validate responses against in-flight queue. Leverages RPC framework capabilities.

### Configuration Membership Validation

Validate response sender is still in current configuration. Natural session boundary, but requires careful handling of rapid changes.

## Implementation Analysis

For detailed analysis of how each implementation handles (or fails to handle) this bug, see:

### Protected Implementations

- [Apache Ratis](analysis/apache-ratis.md) - CallId matching with RequestMap
- [NuRaft](analysis/nuraft.md) - RPC client ID validation
- [RabbitMQ Ra](analysis/rabbitmq-ra.md) - Cluster membership validation
- [braft](analysis/braft.md) - CallId-based session tracking
- [canonical/raft](analysis/canonical-raft.md) - Configuration membership check
- [OpenRaft](analysis/openraft.md) - Vote + Membership log ID
- [sofa-jraft](analysis/sofa-jraft-analysis.md) - Version counter

### Vulnerable Implementations

- [LogCabin](analysis/logcabin.md) - Insufficient epoch validation
- [PySyncObj](analysis/pysyncobj.md) - Zero validation
- [dragonboat](analysis/dragonboat.md) - Term-only validation insufficient
- [etcd-io/raft](analysis/etcd-raft.md) - No session validation
- [hashicorp/raft](analysis/hashicorp-raft-analysis.md) - No session isolation
- [raft-java](analysis/raft-java.md) - No request-response correlation
- [raft-rs (TiKV)](analysis/raft-rs.md) - Monotonicity check insufficient
- [redisraft](analysis/redisraft.md) - msg_id resets on rejoin
- [willemt/raft](analysis/willemt-raft.md) - Insufficient stale detection

### Not Applicable

- [eliben/raft](analysis/eliben-raft.md) - No membership changes (educational)

## Recommendations

For vulnerable implementations:

1. **Immediate**: Add version counter (as shown in raft-rs fix) - minimal changes, no protocol modifications
2. **Better**: Implement membership log ID tracking - explicit session isolation
3. **Best**: Combine with RPC framework call IDs - comprehensive protection

For new implementations:

- Design with explicit session identifiers from the start
- Include membership_log_id or version counter in replication session tracking
- Validate all responses against current session before updating progress

## Survey Methodology

For each implementation, we analyzed:

1. **Progress tracking** - How replication state is maintained
2. **Message protocol** - Fields in AppendEntries requests/responses
3. **Membership changes** - How progress is reset on rejoin
4. **Response validation** - What checks are performed
5. **Session isolation** - Mechanisms to distinguish sessions

Analysis was performed through:
- Source code review
- Protocol message structure examination
- Replication state management inspection
- Response handler validation logic review

---

*Survey conducted November 2025*
