# Raft Replication Session Isolation Bug Survey

This directory contains a comprehensive survey of 16 popular Raft implementations (>700 stars) analyzing their vulnerability to a replication progress corruption bug that occurs during membership changes.

## 🎯 Quick Start

1. Read this overview below for the bug explanation and results
2. Read the technical article: [English](raft-rs-replication-bug.md) | [中文](raft-rs-replication-bug-zh.md)
3. Check [SURVEY-REPORT.md](SURVEY-REPORT.md) for comprehensive findings
4. Clone source code: `./clone-repos.sh` (optional)

## 📚 Main Documents

- [SURVEY-REPORT.md](SURVEY-REPORT.md) - Comprehensive analysis of 16 implementations
- [analysis/](analysis/) - Individual analysis reports for all 16 implementations
- [raft-rs-replication-bug.md](raft-rs-replication-bug.md) - Technical article (English)
- [raft-rs-replication-bug-zh.md](raft-rs-replication-bug-zh.md) - Technical article (Chinese)
- [raft-rs-replication-session-issue.md](raft-rs-replication-session-issue.md) - Original research (Chinese)

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

## 🎓 Key Takeaways

1. **67% of implementations are vulnerable** - This is a widespread issue
2. **Term-only validation is insufficient** - Need explicit session tracking
3. **Multiple solutions exist** - No protocol changes required
4. **Data safety preserved** - Bug causes operational issues, not data loss
5. **Popular implementations affected** - Including hashicorp/raft, etcd-io/raft, raft-rs

## 🔍 Quick Reference

### Vulnerability Status

| Category | Count | Percentage |
|----------|-------|------------|
| VULNERABLE | 10/15 | 67% |
| PROTECTED | 5/15 | 33% |
| N/A (no membership changes) | 1/16 | - |

### Most Popular Implementations

| Implementation | Stars | Status | Analysis |
|----------------|-------|--------|----------|
| hashicorp/raft | 8,826 | ✗ VULNERABLE | [Report](analysis/hashicorp-raft.md) |
| dragonboat | 5,262 | ✗ VULNERABLE | [Report](analysis/dragonboat.md) |
| braft | 4,174 | ✓ PROTECTED | [Report](analysis/braft.md) |
| sofa-jraft | 3,762 | ✓ PROTECTED | [Report](analysis/sofa-jraft.md) |
| raft-rs (TiKV) | 3,224 | ✗ VULNERABLE | [Report](analysis/raft-rs.md) |

### Protection Mechanisms

| Mechanism | Implementations | Complexity | Protocol Changes |
|-----------|----------------|------------|------------------|
| CallId matching | braft, Apache Ratis | Medium | No |
| Version counter | sofa-jraft | Low | No |
| RPC client ID | NuRaft | Low | No |
| Membership check | canonical-raft, Ra | Medium | No |

## Protection Mechanism Examples

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

## 📁 Individual Implementation Analyses

All implementations have detailed individual analysis reports in [analysis/](analysis/):

**Protected (6 implementations)**:
- [braft.md](analysis/braft.md) - CallId-based session tracking
- [apache-ratis.md](analysis/apache-ratis.md) - CallId matching with RequestMap
- [nuraft.md](analysis/nuraft.md) - RPC client ID validation
- [rabbitmq-ra.md](analysis/rabbitmq-ra.md) - Cluster membership validation
- [sofa-jraft.md](analysis/sofa-jraft.md) - Version counter
- [canonical-raft.md](analysis/canonical-raft.md) - Configuration membership check

**Vulnerable (9 implementations)**:
- [hashicorp-raft.md](analysis/hashicorp-raft.md) - No session isolation
- [dragonboat.md](analysis/dragonboat.md) - Term-only validation
- [raft-rs.md](analysis/raft-rs.md) - Monotonicity check insufficient
- [logcabin.md](analysis/logcabin.md) - Insufficient epoch validation
- [raft-java.md](analysis/raft-java.md) - No request-response correlation
- [willemt-raft.md](analysis/willemt-raft.md) - Insufficient stale detection
- [etcd-raft.md](analysis/etcd-raft.md) - No session validation
- [redisraft.md](analysis/redisraft.md) - msg_id resets on rejoin
- [pysyncobj.md](analysis/pysyncobj.md) - Zero validation

**Not Applicable (1 implementation)**:
- [eliben-raft.md](analysis/eliben-raft.md) - No membership changes (educational)

## Getting Started

Clone all 16 implementations for local analysis:

```bash
./clone-repos.sh
```

Shallow clone (~500MB), skips existing repos. Cloned repos are gitignored.

## 📖 Reading Paths

**Quick Overview** (15 min): This README → raft-rs-replication-bug.md

**Comprehensive** (1-2 hours): raft-rs-replication-bug.md → SURVEY-REPORT.md → individual analyses

**Maintainers**: Find your implementation in SURVEY-REPORT.md → check protection mechanisms

**Chinese Readers**: raft-rs-replication-bug-zh.md → SURVEY-REPORT.md

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

## 💡 For Maintainers

Check your implementation status in [SURVEY-REPORT.md](SURVEY-REPORT.md). If vulnerable, consider adding a version counter or other protection mechanism (see Solutions section).

## 🤝 Contributing

To add more implementations: follow the [methodology](SURVEY-REPORT.md#survey-methodology), update SURVEY-REPORT.md and clone-repos.sh.

---

**Survey**: 16 implementations, 60K+ stars, 67% vulnerable (November 2025)
