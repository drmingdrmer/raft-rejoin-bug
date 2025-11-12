# Replication Progress Corruption in raft-rs During Membership Changes

raft-rs, TiKV's Raft implementation, contains a bug in its replication progress tracking that occurs when nodes are removed and re-added within the same term. Delayed AppendEntries responses from previous membership configurations can corrupt the leader's view of a node's replication progress, causing infinite retry loops. While this bug does not compromise data safety, it causes operational problems including resource exhaustion and nodes that cannot catch up without manual intervention.

## Raft Log Replication Basics

In Raft, the leader replicates log entries to followers through AppendEntries RPC calls. The leader maintains a replication state machine for each follower, tracking which log entries have been successfully replicated.

### AppendEntries Request-Response Flow

The leader sends AppendEntries requests containing:
- `term`: The leader's current term
- `prev_log_index`: Log index immediately before the new entries
- `prev_log_term`: Term of the prev_log_index entry
- `entries[]`: Log entries to replicate
- `leader_commit`: Leader's commit index

The follower responds with:
- `term`: Follower's current term
- `index`: The highest log index that was replicated
- `success`: Whether the AppendEntries succeeded

### Progress Tracking

The leader uses responses to track each follower's replication progress:
- `matched`: The highest log index confirmed to be replicated on this follower
- `next_idx`: The next log index to send to this follower

When a success response arrives with `index=N`, the leader updates `matched=N` and calculates `next_idx=N+1` for the next request.

This tracking mechanism assumes that responses correspond to the current replication session. The bug we'll examine occurs when this assumption breaks.

## Problem Description

After a node rejoins a cluster, the leader enters an infinite retry loop. The leader sends AppendEntries requests, the node rejects them, and the cycle repeats. CPU usage increases, network traffic spikes, and the node never catches up with the cluster state.

The logs show continuous rejection messages that resemble data corruption—the node appears to be missing log entries. However, the actual cause is that the leader's progress tracking has been corrupted by a delayed AppendEntries response from a previous membership configuration.

## raft-rs Progress Tracking

raft-rs tracks replication progress using a Progress structure for each follower node:

```rust
// From raft-rs/src/tracker/progress.rs
pub struct Progress {
    pub matched: u64,      // Highest log index known to be replicated
    pub next_idx: u64,     // Next log index to send
    pub state: ProgressState,
    // ... other fields
}
```

The `matched` field tracks the highest log index that has been successfully replicated to this follower. When the leader receives a successful AppendEntries response, it updates this field:

```rust
// From raft-rs/src/tracker/progress.rs
pub fn maybe_update(&mut self, n: u64) -> bool {
    let need_update = self.matched < n;  // Only check monotonicity
    if need_update {
        self.matched = n;  // Accept the update!
        self.resume();
    }
    need_update
}
```

When a node is removed from the cluster, its Progress record is deleted. When it rejoins, a new Progress record is created with `matched = 0`.

## Bug Reproduction Sequence

The following sequence demonstrates how the bug occurs. All events happen within a single term (term=5), which is key to understanding why term-based validation fails.

### Event Timeline

```
| Time | Event                                         | Progress State
|------|-----------------------------------------------|----------------
| T1   | log=1, members={a,b,c}                        | C: matched=0
|      | Leader sends AppendEntries(index=1) to C      |
|      | (Network delay causes slow delivery)          |
|      |                                               |
| T2   | log=5, members={a,b}                          | C: [deleted]
|      | Node C removed from cluster                   |
|      | Progress[C] deleted from leader's tracker     |
|      |                                               |
| T3   | log=100, members={a,b,c}                      | C: matched=0 (new)
|      | Node C rejoins the cluster                    |
|      | New Progress[C] created with matched=0        |
|      |                                               |
| T4   | Delayed response arrives from T1:             |
|      | {from: C, index: 1, success: true}            |
|      | Leader finds Progress[C] (the new one!)       |
|      | maybe_update(1) called: 0 < 1, so update!     | C: matched=1 ❌
|      |                                               |
| T5   | Leader calculates next_idx = matched + 1 = 2  |
|      | Sends AppendEntries(prev_index=1)             |
|      | Node C rejects (doesn't have index 1!)        |
|      | Leader can't decrement (matched == rejected)  |
|      | Infinite loop begins...                       |
```

### Response Handling at T4

At time T4, the delayed response from the old membership session arrives. The leader processes it as follows:

```rust
// From raft-rs/src/raft.rs
fn handle_append_response(&mut self, m: &Message) {
    // Find the progress record
    let pr = match self.prs.get_mut(m.from) {
        Some(pr) => pr,
        None => {
            debug!(self.logger, "no progress available for {}", m.from);
            return;
        }
    };

    // Update progress if the index is higher
    if !pr.maybe_update(m.index) {
        return;
    }
    // ...
}
```

The leader finds a Progress record for node C (the new one from T3). Since the message's term matches the current term, it updates the progress with the stale index value.

## Root Cause Analysis

The bug occurs because **membership changes in Raft don't require term changes**. A leader can remove and re-add a node within the same term. Membership changes are special log entries that get replicated like any other entry.

The Message structure in raft-rs only includes term information:

```protobuf
// From raft-rs/proto/proto/eraftpb.proto
message Message {
    MessageType msg_type = 1;
    uint64 to = 2;
    uint64 from = 3;
    uint64 term = 4;        // Only term, no membership version!
    uint64 log_term = 5;
    uint64 index = 6;
    // ...
}
```

Without a way to distinguish which membership configuration a message belongs to, the leader can't tell if a response is from the current session or a previous one. The term check `if m.term == self.term` passes because both the old and new sessions happen in term 5.

## Impact Analysis

### Infinite Retry Loop

Once the leader incorrectly sets `matched=1`, it enters an infinite loop:

```rust
// From raft-rs/src/tracker/progress.rs
pub fn maybe_decr_to(&mut self, rejected: u64, match_hint: u64, ...) -> bool {
    if self.state == ProgressState::Replicate {
        // Can't decrement if rejected <= matched
        if rejected < self.matched
            || (rejected == self.matched && request_snapshot == INVALID_INDEX) {
            return false;  // Ignore the rejection!
        }
        // ...
    }
}
```

The leader sends AppendEntries with `prev_log_index=1`, but node C doesn't have this entry (it's a fresh node with an empty log). Node C rejects the request. The leader tries to decrement `next_idx`, but since `rejected (1) == matched (1)`, it refuses to decrement. The leader sends the same request again, and the cycle continues forever.

### Operational Impact

1. **Resource Exhaustion**: The continuous AppendEntries-rejection cycle consumes CPU and network bandwidth indefinitely.

2. **Misleading Logs**: Operators see continuous rejection messages that look like data corruption:
   ```
   rejected msgApp [logterm: 5, index: 1] from leader
   ```

3. **False Alerts**: Monitoring systems detect high rejection rates and may page on-call engineers for a non-existent data corruption issue.

4. **Manual Intervention Required**: The node won't recover without a restart or manual intervention, reducing cluster fault tolerance.

## Why Data Remains Safe

Despite the operational chaos, data integrity is preserved. Raft's safety properties ensure that even with corrupted progress tracking, the cluster won't lose committed data.

The key is that commit index calculation still works correctly. Even if the leader thinks node C has `matched=1`, it calculates the commit index based on the actual majority:

- Node A: matched=100
- Node B: matched=100
- Node C: matched=1 (incorrect, but doesn't matter)

The majority (A and B) have matched=100, so the commit index is correctly calculated as 100. The safety properties of Raft's overlapping majorities ensure that any new leader will have all committed entries.

## Solutions: Three Approaches

### Solution 1: Add Membership Version (Recommended)

Add a membership configuration version to messages:

```protobuf
message Message {
    // ... existing fields
    uint64 membership_log_id = 17;  // New field
}
```

Then validate it when processing responses:

```rust
fn handle_append_response(&mut self, m: &Message) {
    let pr = self.prs.get_mut(m.from)?;

    // Check membership version
    if m.membership_log_id != self.current_membership_log_id {
        debug!("stale message from different membership");
        return;
    }

    pr.maybe_update(m.index);
}
```

This directly addresses the root cause by allowing the leader to distinguish messages from different membership configurations.

### Solution 2: Generation Counters

Add a generation counter to Progress that increments each time a node rejoins:

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub generation: u64,  // Incremented on each rejoin
    // ...
}
```

Include the generation in messages and validate it on responses. This is lighter weight than solution 1 but requires careful generation management.

### Solution 3: Stricter Log Validation

When updating progress, verify that the response's log term matches the local log:

```rust
pub fn maybe_update(&mut self, n: u64, log_term: u64) -> bool {
    // Verify log term matches our local log
    if self.raft_log.term(n) != log_term {
        return false;  // Reject stale update
    }

    let need_update = self.matched < n;
    if need_update {
        self.matched = n;
        self.resume();
    }
    need_update
}
```

This catches inconsistencies but requires additional log lookups and may have edge cases.

## Summary

This bug demonstrates that term-based validation alone is insufficient for ensuring message freshness when membership changes occur within the same term. Without explicit session isolation, delayed responses from previous membership configurations can corrupt progress tracking.

While the bug does not compromise data safety due to Raft's commit index calculation and overlapping majority guarantees, it creates operational problems. The symptoms resemble data corruption, potentially causing operations teams to investigate non-existent data loss issues.

Production Raft implementations should use explicit session management through membership versioning or generation counters to prevent this issue. The recommended solution is to add a membership_log_id field to messages, allowing the leader to distinguish responses from different membership configurations.
