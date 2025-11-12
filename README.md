# Raft Replication Session Isolation Bug Survey

This directory contains a comprehensive survey of 16 popular Raft implementations (>700 stars) analyzing their vulnerability to a replication progress corruption bug that occurs during membership changes.

## Quick Links

- **[📊 SURVEY REPORT](SURVEY-REPORT.md)** - Comprehensive analysis of all 16 implementations
- [hashicorp/raft Analysis](hashicorp-raft-analysis.md) - Detailed analysis of HashiCorp's implementation
- [sofa-jraft Analysis](sofa-jraft-analysis.md) - Detailed analysis of SOFAJRaft's implementation

## The Bug

When a node is removed and re-added to a cluster within the same term, delayed AppendEntries responses from the old replication session can corrupt the new session's progress tracking.

### Impact

- ✗ **Operational problems**: Infinite retry loops, resource exhaustion, misleading error logs
- ✓ **Data safety**: Not compromised (Raft's commit protocol still ensures safety)

## Survey Results Summary

| Implementation | Stars | Language | Status |
|----------------|-------|----------|--------|
| braft | 4,174 | C++ | ✓ PROTECTED |
| Apache Ratis | 1,418 | Java | ✓ PROTECTED |
| NuRaft | 1,140 | C++ | ✓ PROTECTED |
| RabbitMQ Ra | 908 | Erlang | ✓ PROTECTED |
| sofa-jraft | 3,762 | Java | ✓ PROTECTED |
| canonical/raft | 954 | C | ✓ PROTECTED |
| **hashicorp/raft** | **8,826** | **Go** | **✗ VULNERABLE** |
| **dragonboat** | **5,262** | **Go** | **✗ VULNERABLE** |
| **raft-rs (TiKV)** | **3,224** | **Rust** | **✗ VULNERABLE** |
| **LogCabin** | **1,945** | **C++** | **✗ VULNERABLE** |
| **raft-java** | **1,234** | **Java** | **✗ VULNERABLE** |
| **willemt/raft** | **1,160** | **C** | **✗ VULNERABLE** |
| **etcd-io/raft** | **943** | **Go** | **✗ VULNERABLE** |
| **redisraft** | **841** | **C** | **✗ VULNERABLE** |
| **PySyncObj** | **738** | **Python** | **✗ VULNERABLE** |
| eliben/raft | 1,232 | Go | N/A |

**10 out of 15 implementations with membership changes are VULNERABLE (67%)**

## Protection Mechanisms

### sofa-jraft: Version Counter ✓

```java
private int version = 0;  // Incremented on reset

if (stateVersion != r.version) {
    return;  // Reject stale response
}
```

### canonical/raft: Configuration Membership ✓

```c
server = configurationGet(&r->configuration, id);
if (server == NULL) {
    return 0;  // Response from non-member rejected
}
```

## Repository Structure

```
rejoin-bug-survey/
├── README.md                       # This file
├── SURVEY-REPORT.md               # Comprehensive survey report
├── hashicorp-raft-analysis.md     # Individual analysis
├── sofa-jraft-analysis.md         # Individual analysis
├── hashicorp-raft/                # Cloned source code
├── dragonboat/                    # Cloned source code
├── sofa-jraft/                    # Cloned source code
├── raft-rs/                       # Cloned source code
├── willemt-raft/                  # Cloned source code
├── canonical-raft/                # Cloned source code
├── etcd-raft/                     # Cloned source code
└── redisraft/                     # Cloned source code
```

## Methodology

For each implementation, we analyzed:

1. **Progress tracking** - How replication state is maintained
2. **Message protocol** - Fields in AppendEntries requests/responses
3. **Membership changes** - How progress is reset on rejoin
4. **Response validation** - What checks are performed
5. **Session isolation** - Mechanisms to distinguish sessions

## Recommendations

Implementations should adopt one of these solutions:

1. **Version counter** (recommended) - No protocol changes needed
2. **Membership log ID** - Explicit tracking, requires protocol upgrade
3. **Configuration membership check** - Natural boundary, needs care

See the [SURVEY REPORT](SURVEY-REPORT.md) for detailed solutions and code examples.

## Related Articles

- `raft-rs-replication-bug.md` - Technical article analyzing the bug (English)
- `raft-rs-replication-bug-zh.md` - Technical article analyzing the bug (Chinese)

---

**Date**: November 2025
**Scope**: 8 Raft implementations with >700 GitHub stars
**Finding**: 75% of popular implementations are vulnerable
