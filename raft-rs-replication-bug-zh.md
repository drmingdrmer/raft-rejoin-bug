# raft-rs 成员变更期间的 replication progress 破坏问题

raft-rs 是 TiKV 使用的 Raft 实现，在 replication progress 跟踪中存在一个 bug。当节点在同一个 term 内被移除又重新加入集群时，问题就会出现。这个 bug 的核心在于：来自旧成员配置的延迟 AppendEntries response 会破坏 Leader 对节点 replication progress 的记录，导致 Leader 陷入无限重试循环。虽然这会带来运维上的困扰——资源持续消耗、节点无法追上集群进度，但好在数据安全性不会受到影响。

## Raft 日志 replication 基础

在 Raft 中，Leader 通过 AppendEntries RPC 向 Follower 复制 log entry，同时为每个 Follower 维护一个 replication 状态机来跟踪复制进度。

### AppendEntries request-response 流程

整个流程是这样的：Leader 发送 AppendEntries request 时会带上当前的 `term`、新 entry 前一个位置的 `prev_log_index` 和 `prev_log_term`、要复制的 `entries[]`，以及 Leader 的 `leader_commit` index。

Follower 收到后会返回一个 response，包含自己的 `term`、已复制的最高 log index，以及操作是否成功。

### Progress 跟踪

Leader 靠这些 response 来掌握每个 Follower 的复制情况。它用 `matched` 记录确认已复制到该 Follower 的最高 log index，用 `next_idx` 标记下次要发送的位置。当收到成功的 response 且携带 `index=N` 时，Leader 就会更新 `matched=N`，然后计算 `next_idx=N+1` 准备下一轮。

这套机制有个隐含的假设：response 对应的是当前的 replication session。

如果没有处理这个假设, 那么当节点重新加入集群后，Leader 可能会陷入无限重试的循环。它不停地发 AppendEntries request，节点不停地拒绝，然后循环往复，而那个节点就是怎么也追不上集群的状态。

## raft-rs Progress 跟踪机制

raft-rs 使用 Progress 结构跟踪每个 follower 节点的 replication progress：

```rust
// 来自 raft-rs/src/tracker/progress.rs
pub struct Progress {
    pub matched: u64,      // 已知已复制的最高 log index
    pub next_idx: u64,     // 下一个要发送的 log index
    pub state: ProgressState,
    // ... 其他字段
}
```

这里的 `matched` 字段记录的是已成功复制到该 follower 的最高 log index。每当 Leader 收到成功的 AppendEntries response，就会更新这个字段：

```rust
// 来自 raft-rs/src/tracker/progress.rs
pub fn maybe_update(&mut self, n: u64) -> bool {
    let need_update = self.matched < n;  // 只检查单调性
    if need_update {
        self.matched = n;  // 接受更新！
        self.resume();
    }
    need_update
}
```

注意这里的更新逻辑很简单：只要新来的 index 比当前记录的 `matched` 大，就接受更新。当节点从集群移除时，它的 Progress 记录会被删除；等它重新加入时，会创建一个全新的 Progress 记录，此时 `matched = 0`。

## Bug 复现序列

让我们通过一个具体的时间线来看看这个 bug 是怎么发生的。特别要注意的是，所有事件都发生在同一个 term（term=5）里——这正是理解为什么基于 term 的验证会失效的关键。

### 事件时间线

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

### T4 的 response 处理

到了时间 T4，那个在 T1 发出、在网络上延迟许久的 response 终于到达了。Leader 收到后会这样处理：

```rust
// 来自 raft-rs/src/raft.rs
fn handle_append_response(&mut self, m: &Message) {
    // 查找 progress 记录
    let pr = match self.prs.get_mut(m.from) {
        Some(pr) => pr,
        None => {
            debug!(self.logger, "no progress available for {}", m.from);
            return;
        }
    };

    // 如果 index 更高则更新 progress
    if !pr.maybe_update(m.index) {
        return;
    }
    // ...
}
```

这时候问题就来了：Leader 确实找到了节点 C 的 Progress 记录，但这是 T3 时新创建的那个。因为 message 的 term 和当前 term 都是 5，term 检查通过了，于是 Leader 就用这个陈旧的 index 值更新了 progress。

## 根本原因分析

这个 bug 的根源在于 **Raft 中的成员变更并不要求 term 发生变化**。也就是说，Leader 完全可以在同一个 term 内把一个节点移除，然后再把它加回来。成员变更只是一个特殊的 log entry，和其他 entry 一样通过正常的复制流程传播。

再看 raft-rs 的 Message 结构，你会发现它只包含 term 信息：

```protobuf
// 来自 raft-rs/proto/proto/eraftpb.proto
message Message {
    MessageType msg_type = 1;
    uint64 to = 2;
    uint64 from = 3;
    uint64 term = 4;        // 只有 term，没有 membership version！
    uint64 log_term = 5;
    uint64 index = 6;
    // ...
}
```

问题就在这里：既然没有办法区分 message 属于哪个 membership 配置，Leader 也就无从判断收到的 response 是来自当前 session 还是之前的 session。而 term 检查 `if m.term == self.term` 又顺利通过了，因为旧 session 和新 session 都在 term 5 里发生。

## 影响分析

### 无限重试循环

一旦 Leader 错误地把 `matched` 设成了 1，麻烦就大了。来看看会发生什么：

```rust
// 来自 raft-rs/src/tracker/progress.rs
pub fn maybe_decr_to(&mut self, rejected: u64, match_hint: u64, ...) -> bool {
    if self.state == ProgressState::Replicate {
        // 如果 rejected <= matched 则无法递减
        if rejected < self.matched
            || (rejected == self.matched && request_snapshot == INVALID_INDEX) {
            return false;  // 忽略拒绝！
        }
        // ...
    }
}
```

现在 Leader 发送 AppendEntries，`prev_log_index=1`，但节点 C 的日志是空的，根本没有 index 1 的条目。所以节点 C 拒绝了这个请求。Leader 想要递减 `next_idx` 来重试更早的位置，但问题来了：因为 `rejected (1) == matched (1)`，递减逻辑直接返回 false，拒绝递减。于是 Leader 只好再发一遍同样的请求，节点 C 再拒绝一次，如此往复，形成了一个死循环。

### 运维影响

这个 bug 会带来一系列运维上的麻烦。首先是资源耗尽的问题：AppendEntries-拒绝的循环会一直消耗 CPU 和网络带宽。其次，运维人员看到日志里全是拒绝消息，比如 `rejected msgApp [logterm: 5, index: 1] from leader`，第一反应会以为是数据损坏了。监控系统也会因为检测到高拒绝率而发出警报，可能半夜把值班工程师叫起来排查一个并不存在的数据丢失问题。最要命的是，这个节点没法自己恢复，必须手动重启或干预才能解决，这就降低了集群的整体容错能力。

## 为什么数据保持安全

虽然运维上一片混乱，但有个好消息：数据的完整性不会受影响。Raft 的安全机制保证了即使 progress 跟踪出了问题，集群也不会丢失已经 commit 的数据。

原因在于 commit index 的计算仍然是正确的。即便 Leader 误以为节点 C 的 `matched=1`，它计算 commit index 时依然是基于实际的 quorum。比如说节点 A 的 matched=100，节点 B 的 matched=100，节点 C 的 matched=1（虽然不对，但也没关系）。Quorum 看的是 A 和 B 的 matched=100，所以 commit index 会被正确计算为 100。加上 Raft 的 overlapping quorum 特性，任何新选出的 Leader 都必然包含所有已 commit 的 entry，数据安全就这样得到了保障。

## 解决方案：三种方法

### 方案 1：添加 membership version（推荐）

最直接的办法就是在 message 里加上 membership 配置的 version：

```protobuf
message Message {
    // ... 现有字段
    uint64 membership_log_id = 17;  // 新字段
}
```

然后在处理 response 时校验一下：

```rust
fn handle_append_response(&mut self, m: &Message) {
    let pr = self.prs.get_mut(m.from)?;

    // 检查 membership version
    if m.membership_log_id != self.current_membership_log_id {
        debug!("stale message from different membership");
        return;
    }

    pr.maybe_update(m.index);
}
```

这样就直接解决了问题的根源——Leader 现在可以分辨出 message 来自哪个 membership 配置了。

### 方案 2：generation counter

另一个思路是在 Progress 里加个 generation counter，每次节点重新加入时就递增：

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub generation: u64,  // 每次重新加入时递增
    // ...
}
```

发 message 时把 generation 带上，收到 response 时验证一下。这个方案比方案 1 轻量一些，不过得小心管理 generation 的生命周期。


## 总结

通过这个 bug 我们可以看到，当成员变更发生在同一个 term 内时，单纯依靠 term 来验证 message 的新鲜度是不够的。如果缺少显式的 session 隔离机制，来自旧 membership 配置的延迟 response 就可能破坏 progress 跟踪。

不过值得庆幸的是，因为 Raft 在 commit index 计算和 overlapping quorum 机制上的保障，这个 bug 并不会危及数据安全。它带来的主要是运维层面的问题——表面上看起来像数据损坏，可能让运维团队花大力气去排查一个并不存在的数据丢失问题。

对于生产环境的 Raft 实现，建议引入显式的 session 管理机制。可以通过 membership version 或者 generation counter 来实现。其中最推荐的做法是在 message 里添加 membership_log_id 字段，这样 Leader 就能清楚地分辨出 response 来自哪个 membership 配置了。
