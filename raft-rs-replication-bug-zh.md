# raft-rs 成员变更期间的 replication progress 破坏问题

raft-rs（TiKV 的 Raft 实现）在 replication progress 跟踪中存在一个 bug，当节点在同一 term 内被移除并重新加入时会触发。来自先前成员配置的延迟 AppendEntries response 会破坏 Leader 对节点 replication progress 的认知，导致无限重试循环。虽然此 bug 不会危及数据安全，但会导致运维问题，包括资源耗尽和节点无法在不手动干预的情况下追赶集群。

## Raft 日志 replication 基础

在 Raft 中，Leader 通过 AppendEntries RPC 调用向 Follower 复制 log entry。Leader 为每个 Follower 维护一个 replication 状态机，跟踪哪些 log entry 已成功复制。

### AppendEntries request-response 流程

Leader 发送 AppendEntries request，包含：
- `term`：Leader 的当前 term
- `prev_log_index`：新 entry 之前的 log index
- `prev_log_term`：prev_log_index entry 的 term
- `entries[]`：要复制的 log entry
- `leader_commit`：Leader 的 commit index

Follower response 包含：
- `term`：Follower 的当前 term
- `index`：已复制的最高 log index
- `success`：AppendEntries 是否成功

### Progress 跟踪

Leader 使用 response 来跟踪每个 Follower 的 replication progress：
- `matched`：确认已在此 Follower 上复制的最高 log index
- `next_idx`：下一个要发送给此 Follower 的 log index

当成功 response 到达并携带 `index=N` 时，Leader 更新 `matched=N` 并计算 `next_idx=N+1` 用于下一次 request。

这种跟踪机制假设 response 对应于当前的 replication session。我们将要分析的 bug 就发生在这个假设被打破时。

## 问题描述

节点重新加入集群后，Leader 进入无限重试循环。Leader 发送 AppendEntries request，节点拒绝，然后循环重复。CPU 使用率上升，网络流量激增，节点永远无法追上集群状态。

日志显示持续的拒绝消息，看起来像数据损坏——节点似乎缺少 log entry。但实际原因是 Leader 的 progress 跟踪被来自先前成员配置的延迟 AppendEntries response 所破坏。

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

`matched` 字段跟踪已成功复制到该 follower 的最高 log index。当 Leader 收到成功的 AppendEntries response 时，它会更新这个字段：

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

### T4 的 response 处理

在时间 T4，来自旧成员 session 的延迟 response 到达。Leader 按如下方式处理：

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

Leader 找到了节点 C 的 Progress 记录（T3 创建的新记录）。由于 message 的 term 与当前 term 匹配，它使用陈旧的 index 值更新 progress。

## 根本原因分析

Bug 的发生是因为 **Raft 中的成员变更不需要 term 变更**。Leader 可以在同一 term 内移除并重新添加节点。成员变更是特殊的 log entry，像其他 entry 一样被复制。

raft-rs 中的 Message 结构只包含 term 信息：

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

如果没有办法区分 message 属于哪个 membership 配置，Leader 就无法判断 response 是来自当前 session 还是之前的 session。Term 检查 `if m.term == self.term` 通过了，因为旧 session 和新 session 都发生在 term 5 中。

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

尽管运维混乱，数据完整性得以保留。Raft 的安全特性确保即使 progress 跟踪被破坏，集群也不会丢失已 commit 的数据。

关键在于 commit index 的计算仍然正确工作。即使 Leader 认为节点 C 的 `matched=1`，它也是基于实际的 quorum 计算 commit index：

- 节点 A: matched=100
- 节点 B: matched=100
- 节点 C: matched=1（不正确，但无关紧要）

Quorum（A 和 B）的 matched=100，因此 commit index 被正确计算为 100。Raft 的 overlapping quorum 安全特性确保任何新 Leader 都将拥有所有已 commit 的 entry。

## 解决方案：三种方法

### 方案 1：添加 membership version（推荐）

向 message 中添加 membership 配置 version：

```protobuf
message Message {
    // ... 现有字段
    uint64 membership_log_id = 17;  // 新字段
}
```

然后在处理 response 时验证它：

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

这直接解决了根本原因，允许 Leader 区分来自不同 membership 配置的 message。

### 方案 2：generation counter

向 Progress 添加一个 generation counter，每次节点重新加入时递增：

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub generation: u64,  // 每次重新加入时递增
    // ...
}
```

在 message 中包含 generation，并在 response 时验证它。这比方案 1 更轻量，但需要仔细管理 generation。


## 总结

此 bug 表明，当成员变更发生在同一 term 内时，仅基于 term 的验证不足以确保 message 新鲜度。如果没有显式的 session 隔离，来自先前 membership 配置的延迟 response 会破坏 progress 跟踪。

虽然由于 Raft 的 commit index 计算和 overlapping quorum 保证，此 bug 不会危及数据安全，但它会造成运维问题。症状类似数据损坏，可能导致运维团队调查不存在的数据丢失问题。

生产环境的 Raft 实现应使用显式 session 管理，通过 membership version 或 generation counter 来防止此问题。推荐的解决方案是向 message 添加 membership_log_id 字段，允许 Leader 区分来自不同 membership 配置的 response。
