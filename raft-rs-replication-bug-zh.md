# raft-rs 成员变更期间的复制进度破坏问题

raft-rs（TiKV 的 Raft 实现）在复制进度跟踪中存在一个 bug，当节点在同一 term 内被移除并重新加入时会触发。来自先前成员配置的延迟 AppendEntries 响应会破坏 Leader 对节点复制进度的认知，导致无限重试循环。虽然此 bug 不会危及数据安全，但会导致运维问题，包括资源耗尽和节点无法在不手动干预的情况下追赶集群。

## Raft 日志复制基础

在 Raft 中，Leader 通过 AppendEntries RPC 调用向 Follower 复制日志条目。Leader 为每个 Follower 维护一个复制状态机，跟踪哪些日志条目已成功复制。

### AppendEntries 请求-响应流程

Leader 发送 AppendEntries 请求，包含：
- `term`：Leader 的当前 term
- `prev_log_index`：新条目之前的日志索引
- `prev_log_term`：prev_log_index 条目的 term
- `entries[]`：要复制的日志条目
- `leader_commit`：Leader 的提交索引

Follower 响应包含：
- `term`：Follower 的当前 term
- `index`：已复制的最高日志索引
- `success`：AppendEntries 是否成功

### 进度跟踪

Leader 使用响应来跟踪每个 Follower 的复制进度：
- `matched`：确认已在此 Follower 上复制的最高日志索引
- `next_idx`：下一个要发送给此 Follower 的日志索引

当成功响应到达并携带 `index=N` 时，Leader 更新 `matched=N` 并计算 `next_idx=N+1` 用于下一次请求。

这种跟踪机制假设响应对应于当前的复制会话。我们将要分析的 bug 就发生在这个假设被打破时。

## 问题描述

节点重新加入集群后，Leader 进入无限重试循环。Leader 发送 AppendEntries 请求，节点拒绝，然后循环重复。CPU 使用率上升，网络流量激增，节点永远无法追上集群状态。

日志显示持续的拒绝消息，看起来像数据损坏——节点似乎缺少日志条目。但实际原因是 Leader 的进度跟踪被来自先前成员配置的延迟 AppendEntries 响应所破坏。

## raft-rs 进度跟踪机制

raft-rs 使用 Progress 结构跟踪每个 follower 节点的复制进度：

```rust
// 来自 raft-rs/src/tracker/progress.rs
pub struct Progress {
    pub matched: u64,      // 已知已复制的最高日志索引
    pub next_idx: u64,     // 下一个要发送的日志索引
    pub state: ProgressState,
    // ... 其他字段
}
```

`matched` 字段跟踪已成功复制到该 follower 的最高日志索引。当 Leader 收到成功的 AppendEntries 响应时，它会更新这个字段：

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

当节点从集群中移除时，它的 Progress 记录会被删除。当它重新加入时，会创建一个新的 Progress 记录，`matched = 0`。

## Bug 复现序列

以下序列展示了 bug 如何发生。所有事件都发生在单个 term（term=5）内，这是理解为何基于 term 的验证失效的关键。

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

### T4 的响应处理

在时间 T4，来自旧成员会话的延迟响应到达。Leader 按如下方式处理：

```rust
// 来自 raft-rs/src/raft.rs
fn handle_append_response(&mut self, m: &Message) {
    // 查找进度记录
    let pr = match self.prs.get_mut(m.from) {
        Some(pr) => pr,
        None => {
            debug!(self.logger, "no progress available for {}", m.from);
            return;
        }
    };

    // 如果索引更高则更新进度
    if !pr.maybe_update(m.index) {
        return;
    }
    // ...
}
```

Leader 找到了节点 C 的 Progress 记录（T3 创建的新记录）。由于消息的 term 与当前 term 匹配，它使用陈旧的索引值更新进度。

## 根本原因分析

Bug 的发生是因为 **Raft 中的成员变更不需要 term 变更**。Leader 可以在同一 term 内移除并重新添加节点。成员变更是特殊的日志条目，像其他条目一样被复制。

raft-rs 中的 Message 结构只包含 term 信息：

```protobuf
// 来自 raft-rs/proto/proto/eraftpb.proto
message Message {
    MessageType msg_type = 1;
    uint64 to = 2;
    uint64 from = 3;
    uint64 term = 4;        // 只有 term，没有成员版本！
    uint64 log_term = 5;
    uint64 index = 6;
    // ...
}
```

如果没有办法区分消息属于哪个成员配置，Leader 就无法判断响应是来自当前会话还是之前的会话。Term 检查 `if m.term == self.term` 通过了，因为旧会话和新会话都发生在 term 5 中。

## 影响分析

### 无限重试循环

一旦 Leader 错误地设置了 `matched=1`，它就会进入无限循环：

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

Leader 发送带有 `prev_log_index=1` 的 AppendEntries，但节点 C 没有这个条目（它是一个日志为空的新节点）。节点 C 拒绝请求。Leader 尝试递减 `next_idx`，但由于 `rejected (1) == matched (1)`，它拒绝递减。Leader 再次发送相同的请求，循环永远持续。

### 运维影响

1. **资源耗尽**：持续的 AppendEntries-拒绝循环无限期地消耗 CPU 和网络带宽。

2. **误导性日志**：运维人员看到持续的拒绝消息，看起来像数据损坏：
   ```
   rejected msgApp [logterm: 5, index: 1] from leader
   ```

3. **虚假警报**：监控系统检测到高拒绝率，可能会为不存在的数据损坏问题呼叫值班工程师。

4. **需要手动干预**：节点在没有重启或手动干预的情况下无法恢复，降低了集群的容错能力。

## 为什么数据保持安全

尽管运维混乱，数据完整性得以保留。Raft 的安全特性确保即使进度跟踪被破坏，集群也不会丢失已提交的数据。

关键在于提交索引的计算仍然正确工作。即使 Leader 认为节点 C 的 `matched=1`，它也是基于实际的多数派计算提交索引：

- 节点 A: matched=100
- 节点 B: matched=100
- 节点 C: matched=1（不正确，但无关紧要）

多数派（A 和 B）的 matched=100，因此提交索引被正确计算为 100。Raft 的重叠多数派安全特性确保任何新 Leader 都将拥有所有已提交的条目。

## 解决方案：三种方法

### 方案 1：添加成员版本（推荐）

向消息中添加成员配置版本：

```protobuf
message Message {
    // ... 现有字段
    uint64 membership_log_id = 17;  // 新字段
}
```

然后在处理响应时验证它：

```rust
fn handle_append_response(&mut self, m: &Message) {
    let pr = self.prs.get_mut(m.from)?;

    // 检查成员版本
    if m.membership_log_id != self.current_membership_log_id {
        debug!("stale message from different membership");
        return;
    }

    pr.maybe_update(m.index);
}
```

这直接解决了根本原因，允许 Leader 区分来自不同成员配置的消息。

### 方案 2：代数计数器

向 Progress 添加一个代数计数器，每次节点重新加入时递增：

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub generation: u64,  // 每次重新加入时递增
    // ...
}
```

在消息中包含代数，并在响应时验证它。这比方案 1 更轻量，但需要仔细管理代数。

### 方案 3：更严格的日志验证

更新进度时，验证响应的日志 term 与本地日志匹配：

```rust
pub fn maybe_update(&mut self, n: u64, log_term: u64) -> bool {
    // 验证日志 term 与我们的本地日志匹配
    if self.raft_log.term(n) != log_term {
        return false;  // 拒绝陈旧更新
    }

    let need_update = self.matched < n;
    if need_update {
        self.matched = n;
        self.resume();
    }
    need_update
}
```

这可以捕获不一致，但需要额外的日志查找，并可能存在边缘情况。

## 总结

此 bug 表明，当成员变更发生在同一 term 内时，仅基于 term 的验证不足以确保消息新鲜度。如果没有显式的会话隔离，来自先前成员配置的延迟响应会破坏进度跟踪。

虽然由于 Raft 的提交索引计算和重叠多数派保证，此 bug 不会危及数据安全，但它会造成运维问题。症状类似数据损坏，可能导致运维团队调查不存在的数据丢失问题。

生产环境的 Raft 实现应使用显式会话管理，通过成员版本或代数计数器来防止此问题。推荐的解决方案是向消息添加 membership_log_id 字段，允许 Leader 区分来自不同成员配置的响应。
