# raft-rs (TiKV) Replication Session Bug Analysis

**Repository**: https://github.com/tikv/raft-rs
**Stars**: 3,224
**Language**: Rust
**Status**: ✗ VULNERABLE

## Vulnerability Summary

raft-rs (used by TiKV) is vulnerable to the replication session isolation bug. The implementation relies solely on term validation and monotonicity checks, without any mechanism to distinguish between replication sessions within the same term.

## How the Bug Occurs

### 1. Progress Tracking Without Session ID

File: [`src/tracker/progress.rs:8-56`](https://github.com/tikv/raft-rs/blob/master/src/tracker/progress.rs#L8-L56)

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub state: ProgressState,
    pub pending_snapshot: u64,
    // No session version or ID field
    // ...
}
```

The `Progress` struct tracks replication state but has no field to identify the replication session.

### 2. Progress Update With Only Monotonicity Check

File: [`src/tracker/progress.rs:136-148`](https://github.com/tikv/raft-rs/blob/master/src/tracker/progress.rs#L136-L148)

```rust
pub fn maybe_update(&mut self, n: u64) -> bool {
    let need_update = self.matched < n;
    if need_update {
        self.matched = n;
        self.next_idx = n + 1;
        self.resume();
    }
    need_update
}
```

The `maybe_update` method only checks if the new index is higher than the current matched index. This is insufficient to prevent corruption from delayed responses after a rejoin, because after rejoin `matched` is reset to 0, so any delayed response with index > 0 will be accepted.

### 3. Message Protocol Without Session ID

File: [`proto/proto/eraftpb.proto:71-98`](https://github.com/tikv/raft-rs/blob/master/proto/proto/eraftpb.proto#L71-L98)

```protobuf
message Message {
    MessageType msg_type = 1;
    uint64 to = 2;
    uint64 from = 3;
    uint64 term = 4;
    // ... other fields
    // No session_id or version field
}
```

The message protocol only includes term, which cannot distinguish sessions within the same term.

## Attack Scenario

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
         | maybe_update(50) returns true            | (50 > 0)
         | matched set to 50, next_idx to 51        |
         |                                          |
T5       | Leader sends AppendEntries(prev=50)      |
         | Node C rejects (actual log_index < 50)   |
         | Infinite loop: next_idx never advances   |
```

## Root Cause

1. **No session isolation**: Progress struct lacks session identifier
2. **Monotonicity check insufficient**: `maybe_update` accepts any index higher than current, but after rejoin matched=0, so any delayed response passes
3. **Term-only validation**: Cannot distinguish messages from different membership configurations within same term
4. **No request-response correlation**: No mechanism to match responses with sent requests

## Recommended Solutions

### Solution: Add Version Counter (Recommended)

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub state: ProgressState,
    pub session_version: u64,  // Add this field
    // ...
}

impl Progress {
    pub fn reset(&mut self) {
        self.session_version += 1;  // Increment on reset
        self.matched = 0;
        self.next_idx = 1;
        self.state = ProgressState::Probe;
    }

    pub fn maybe_update(&mut self, n: u64, response_version: u64) -> bool {
        // Validate session first
        if response_version != self.session_version {
            return false;  // Stale response from old session
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

This requires protocol changes and coordination with all raft-rs users.

## Impact Assessment

**Data Safety**: ✓ Not compromised
- Commit protocol ensures majority agreement
- No committed data is lost or corrupted
- Safety properties maintained

**Operational Impact**: ✗ Significant
- Infinite retry loops when progress corrupted
- TiKV nodes unable to replicate data
- Resource exhaustion from continuous retries
- Manual node restart required to recover
- Reduced cluster redundancy during issue

## References

- Progress struct: [`src/tracker/progress.rs:8-56`](https://github.com/tikv/raft-rs/blob/master/src/tracker/progress.rs#L8-L56)
- Progress update: [`src/tracker/progress.rs:136-148`](https://github.com/tikv/raft-rs/blob/master/src/tracker/progress.rs#L136-L148)
- Message protocol: [`proto/proto/eraftpb.proto:71-98`](https://github.com/tikv/raft-rs/blob/master/proto/proto/eraftpb.proto#L71-L98)
