# raft-rs 复制会话隔离问题分析报告

## 概述

本报告分析了 raft-rs (TiKV 的 Raft 实现) 在成员变更场景下的复制进度跟踪问题。与 OpenRaft 使用显式的 `ReplicationSessionId` 不同，raft-rs 依赖隐式的进度生命周期管理，这导致在特定场景下可能出现陈旧的复制进度更新被错误应用的问题。

**结论**: raft-rs 存在此问题，会导致运维困扰，但不会造成数据丢失。

## 问题背景

### OpenRaft 的解决方案

OpenRaft 引入了 `ReplicationSessionId` 来区分不同的复制会话：

```rust
pub struct ReplicationSessionId {
    pub(crate) leader_vote: CommittedVote,        // 区分不同 Leader
    pub(crate) membership_log_id: Option<LogId>,  // 区分不同成员配置
}
```

当以下条件发生时，会创建新的会话 ID：
- Leader 变更
- 集群成员配置变更

### 问题场景

考虑如下时间序列：

1. **log_id=1, members={a,b,c}**: Leader 向节点 C 发送 AppendEntries(index=1)
2. **log_id=5, members={a,b}**: 节点 C 被移除，进度记录被删除
3. **log_id=100, members={a,b,c}**: 节点 C 重新加入，创建新的进度记录 `matched=0`
4. **延迟响应到达**: `{from: C, index: 1, reject: false}` (来自步骤 1)
5. **Leader 处理响应**: 错误地将新会话的 `matched` 更新为 1

没有会话隔离机制时，来自旧会话的进度更新可能被错误地应用到新会话。

## raft-rs 的实现分析

### 1. 进度跟踪结构

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/src/tracker/progress.rs:8-56`

```rust
pub struct Progress {
    pub matched: u64,      // 已复制的最高索引
    pub next_idx: u64,     // 下一个要发送的索引
    pub state: ProgressState,
    // ... 其他字段
}
```

### 2. 成员变更时的进度管理

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/src/tracker.rs:370-387`

```rust
pub fn apply_conf(&mut self, conf: Configuration, changes: MapChange, next_idx: u64) {
    for (id, change_type) in changes {
        match change_type {
            MapChangeType::Add => {
                let mut pr = Progress::new(next_idx, self.max_inflight);
                pr.recent_active = true;
                self.progress.insert(id, pr);  // 创建新的进度，matched=0
            }
            MapChangeType::Remove => {
                self.progress.remove(&id);      // 删除旧的进度
            }
        }
    }
}
```

### 3. 响应处理逻辑

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/src/raft.rs:1753-1817`

```rust
fn handle_append_response(&mut self, m: &Message) {
    // 1. 查找进度记录
    let pr = match self.prs.get_mut(m.from) {
        Some(pr) => pr,
        None => {
            debug!(self.logger, "no progress available for {}", m.from);
            return;  // 如果没有进度记录则返回
        }
    };

    // 2. 更新进度
    if !pr.maybe_update(m.index) {
        return;
    }
    // ...
}
```

### 4. 进度更新验证

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/src/tracker/progress.rs:136-148`

```rust
pub fn maybe_update(&mut self, n: u64) -> bool {
    let need_update = self.matched < n;  // 仅检查单调性
    if need_update {
        self.matched = n;  // 接受更新！
        self.resume();
    }
    // ...
}
```

### 5. 消息定义

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/proto/proto/eraftpb.proto:71-98`

```protobuf
message Message {
    MessageType msg_type = 1;
    uint64 to = 2;
    uint64 from = 3;
    uint64 term = 4;           // 只有 term，没有 membership_log_id
    uint64 log_term = 5;
    uint64 index = 6;
    // ...
}
```

## 漏洞证明

### raft-rs 缺乏会话隔离

**消息中没有成员配置版本字段**，只有 `term` 字段。关键问题：**成员配置变更不需要改变 term**。

### 攻击场景

在同一 term 内：

```
时间线 | 事件 | 进度状态
-------|------|----------
T1 | term=5, log=1, members={a,b,c}         | C: matched=0
   | Leader 发送 AppendEntries(index=1) → C |
   |                                         |
T2 | term=5, log=5, members={a,b}           | C: 被删除
   | 进度记录 Progress[C] 被删除              |
   |                                         |
T3 | term=5, log=100, members={a,b,c}       | C: matched=0 (新建)
   | 节点 C 重新加入，新建 Progress[C]         |
   |                                         |
T4 | 延迟响应到达: {from:C, term:5, index:1} |
   | Leader 查找 Progress[C]: ✓ 找到（新的）  |
   | 检查 term: ✓ term=5 匹配                |
   | maybe_update(1): ✓ matched(0) < 1 通过 |
   | 更新 matched=1                          | C: matched=1 ✗ 错误！
```

### 为什么 term 检查失效？

**关键观察**: 在 Raft 协议中，成员配置变更通过正常的日志复制完成，**不需要选举，不需要增加 term**。

Leader 可以在同一个 term 内：
- 提交 `log_id=5, members={a,b}` (移除 C)
- 提交 `log_id=100, members={a,b,c}` (重新加入 C)

因此，来自旧会话的消息 `{term: 5, index: 1}` 与当前 term 完全匹配，**无法通过 term 检查识别为陈旧消息**。

## 问题后果分析

### ✓ 不会造成数据丢失

根据 OpenRaft 文档的分析（replication-session.md:94-107）：

**Raft 的成员变更算法保证了重叠的多数派**：

- 在提交 `log_id=100` 的配置 `c10={a,b,c}` 之前，前一个配置必须已经提交
- 假设前一个配置是 `log_id=8` 的 `c8={a,b}`，那么 `c8` 已经在多数派中提交
- 这意味着 `log_id=1` 已经被 `c8` 的多数派接受
- Raft 的联合配置变更机制确保 `c8` 和 `c10` 之间存在重叠的多数派
- 因此，无论在 `c8` 还是 `c10` 下选出的新 Leader，都能看到已提交的 `log_id=1`

**即使 Leader 错误地认为节点 C 的 `matched=1`，提交索引的计算仍然基于真实的多数派**：
- 节点 A: matched=100
- 节点 B: matched=100
- 节点 C: matched=1 (错误，但不影响多数派)

多数派 {A, B} 的最小值是 100，commit index 正确计算为 100。

### ✗ 导致运维问题

**1. 无限重试循环**

当 Leader 错误地设置 `matched=1` 后：

```
1. Leader 计算 next_idx = matched + 1 = 2
2. Leader 发送 AppendEntries(prev_log_index=1, entries=[2,3,...])
3. 节点 C 拒绝：没有 prev_log_index=1
4. Leader 尝试回退 next_idx，但被拒绝
```

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/src/tracker/progress.rs:166-175`

```rust
pub fn maybe_decr_to(&mut self, rejected: u64, match_hint: u64, ...) -> bool {
    if self.state == ProgressState::Replicate {
        // 拒绝必定是陈旧的，如果 rejected < matched
        if rejected < self.matched
            || (rejected == self.matched && request_snapshot == INVALID_INDEX) {
            return false;  // 忽略拒绝！
        }
        // ...
    }
}
```

因为 `rejected(1) < matched(1)` 不成立，但 `rejected(1) == matched(1)` 成立，回退被拒绝。Leader 陷入死循环。

**2. 资源浪费**
- 持续的 AppendEntries → 拒绝 → 重试循环
- 消耗 CPU、网络带宽
- 可能持续到节点重启或超时

**3. 令人困惑的错误日志**

**文件**: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs/src/raft.rs:2528-2537`

```rust
debug!(
    self.logger,
    "rejected msgApp [logterm: {msg_log_term}, index: {msg_index}] \
    from {from}",
    msg_log_term = m.log_term,
    msg_index = m.index,
    from = m.from;
    "index" => m.index,
    "logterm" => ?self.raft_log.term(m.index),
);
```

节点 C 持续输出：
```
rejected msgApp [logterm: 5, index: 1] from leader
```

运维人员会看到：
- 持续的复制失败
- 看起来像数据损坏
- 但实际上不是

**4. 监控误报**
- 拒绝率飙升
- 可能触发告警、寻呼
- 运维人员调查不存在的数据损坏

**5. 延迟追赶**
- 节点 C 无法取得进展
- 可能需要手动干预或节点重启
- 集群容错能力下降（少了一个健康副本）

## OpenRaft vs raft-rs 对比

| 方面 | OpenRaft | raft-rs |
|------|----------|---------|
| 会话标识 | 显式 `ReplicationSessionId` | 隐式（节点 ID + term）|
| 成员配置版本 | `membership_log_id` | 无 |
| 消息字段 | 包含会话 ID | 只有 term |
| 隔离机制 | 直接比较会话 ID | 依赖进度删除 + term |
| 同 term 内保护 | ✓ 是 | ✗ 否 |
| 问题影响 | 无此问题 | 运维困扰 |

## 解决方案建议

### 方案 1: 添加成员配置版本（推荐）

在 `Message` 中添加 `membership_log_id` 字段：

```protobuf
message Message {
    // ... 现有字段
    uint64 membership_log_id = 17;  // 新字段
}
```

验证逻辑：
```rust
fn handle_append_response(&mut self, m: &Message) {
    let pr = self.prs.get_mut(m.from)?;

    // 检查成员配置版本
    if m.membership_log_id != self.current_membership_log_id {
        debug!("stale message from different membership");
        return;
    }

    pr.maybe_update(m.index);
}
```

### 方案 2: 添加会话代数（轻量级）

在 `Progress` 中添加代数计数器：

```rust
pub struct Progress {
    pub matched: u64,
    pub next_idx: u64,
    pub generation: u64,  // 每次重建时递增
    // ...
}
```

### 方案 3: 更严格的响应验证

在 `maybe_update` 中添加额外检查：
- 验证响应的 `log_term` 与本地日志一致
- 如果不一致，拒绝更新

## 影响评估

### 严重程度: 中等

- **数据安全**: ✓ 不影响（Raft 协议保证）
- **可用性**: ✗ 受影响（节点无法追赶）
- **运维复杂度**: ✗ 增加（误报和调试困难）

### 触发条件

需要同时满足：
1. 节点被移除后重新加入
2. 移除和重新加入发生在同一 term 内
3. 来自旧会话的响应消息延迟到达
4. 消息到达时新进度的 `matched < 旧响应的 index`

### 概率评估

- **生产环境**: 低到中等
  - 网络延迟可能导致消息乱序
  - 快速的成员变更操作（自动化运维）增加概率
  - 使用 learner → voter 升级模式降低概率

- **测试环境**: 较高
  - 网络模拟器可能引入长延迟
  - 快速的成员变更测试

## 参考

1. OpenRaft 文档: `/Users/drdrxp/xp/vcs/github.com/drmingdrmer/openraft/openraft/src/docs/data/replication-session.md`
2. raft-rs 源码: `/Users/drdrxp/xp/vcs/github.com/tikv/raft-rs`
3. Raft 论文: https://raft.github.io/raft.pdf
4. TiKV 文档: https://tikv.org/

## 结论

raft-rs 存在复制会话隔离问题，在特定条件下会导致运维困扰，但不会造成数据丢失。建议：

1. **短期**: 添加监控和告警，识别此类场景
2. **中期**: 实现方案 2（代数计数器）作为临时缓解
3. **长期**: 实现方案 1（成员配置版本），与 OpenRaft 对齐

该问题的根本原因是 **Raft 协议中成员配置变更不改变 term**，因此仅依赖 term 检查无法区分同一 term 内的不同配置会话。OpenRaft 通过显式的 `membership_log_id` 解决了这个问题，raft-rs 应该借鉴这一设计。
