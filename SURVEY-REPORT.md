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
         | Node C rejects (doesn't have index 50)   |
         | Leader retries with prev=50 again        |
         | Infinite rejection loop                  |
```

### Root Cause

After node C rejoins, the new `Progress[C]` has `matched=0`. When the delayed response arrives with `index=50`, `maybe_update(50)` checks `0 < 50` and accepts it, corrupting progress to `matched=50` even though C's actual log is empty. The fundamental problem is that `Progress` lacks a session identifier—the monotonicity check (`matched < n`) works within a session but fails across session boundaries. Term-only validation cannot distinguish messages from different membership configurations within the same term, and there's no request-response correlation mechanism.

### Impact

The bug causes infinite retry loops, resource exhaustion, and requires manual restart to recover. TiKV nodes become unable to replicate data. However, data safety is not compromised—Raft's commit protocol still ensures safety, so this is an operational issue, not data loss.

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

**Why this works**: When node C is removed at T2, `Progress[C]` is deleted. When node C rejoins at T3, a new `Progress[C]` is created with `session_version=0`, and the first `reset()` call increments it to `session_version=1`. At T4, when the delayed response arrives with `response_version=0` (from the old session), the validation fails because `0 != 1`, and the response is rejected.


## General Solutions for Other Implementations

The version counter approach shown above can be adapted to any implementation. Other protection mechanisms found in surveyed implementations include: **membership log ID tracking** (include the log ID where membership was committed as session identifier), **CallId/request correlation** (assign unique ID to each request and validate responses against in-flight queue), and **configuration membership validation** (validate response sender is still in current configuration). See individual analysis reports for implementation details.

## Survey Methodology

For each implementation, we reviewed source code to analyze progress tracking structures, message protocols, membership change handling, and response validation logic. See individual analysis reports in [analysis/](analysis/) for details.

---

*Survey conducted November 2025*
