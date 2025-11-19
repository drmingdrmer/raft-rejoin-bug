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

## The Bug

When a node is removed and re-added to a cluster within the same term, delayed AppendEntries responses from the old replication session can corrupt the new session's progress tracking.

### Impact

- ✗ **Operational problems**: Infinite retry loops, resource exhaustion, misleading error logs
- ✓ **Data safety**: Not compromised (Raft's commit protocol still ensures safety)

## Survey Results Summary

| Implementation | Stars | Language | Status |
|----------------|------:|----------|--------|
| Apache Ratis | 1,418 | Java | ✓ PROTECTED |
| NuRaft | 1,140 | C++ | ✓ PROTECTED |
| RabbitMQ Ra | 908 | Erlang | ✓ PROTECTED |
| braft | 4,174 | C++ | ✓ PROTECTED |
| canonical/raft | 954 | C | ✓ PROTECTED |
| sofa-jraft | 3,762 | Java | ✓ PROTECTED |
| **LogCabin** | **1,945** | **C++** | **✗ VULNERABLE** |
| **PySyncObj** | **738** | **Python** | **✗ VULNERABLE** |
| **dragonboat** | **5,262** | **Go** | **✗ VULNERABLE** |
| **etcd-io/raft** | **943** | **Go** | **✗ VULNERABLE** |
| **hashicorp/raft** | **8,826** | **Go** | **✗ VULNERABLE** |
| **raft-java** | **1,234** | **Java** | **✗ VULNERABLE** |
| **raft-rs (TiKV)** | **3,224** | **Rust** | **✗ VULNERABLE** |
| **redisraft** | **841** | **C** | **✗ VULNERABLE** |
| **willemt/raft** | **1,160** | **C** | **✗ VULNERABLE** |
| eliben/raft | 1,232 | Go | N/A |


## 🎓 Key Takeaways

- **Term-only validation is insufficient** - Need explicit session tracking
- **Data safety preserved** - Bug causes operational issues, not data loss

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
| braft | 4,174 | ✓ PROTECTED | [Report](analysis/braft.md) |
| dragonboat | 5,262 | ✗ VULNERABLE | [Report](analysis/dragonboat.md) |
| hashicorp/raft | 8,826 | ✗ VULNERABLE | [Report](analysis/hashicorp-raft.md) |
| raft-rs (TiKV) | 3,224 | ✗ VULNERABLE | [Report](analysis/raft-rs.md) |
| sofa-jraft | 3,762 | ✓ PROTECTED | [Report](analysis/sofa-jraft.md) |

### Protection Mechanisms

| Mechanism | Implementations | Complexity | Protocol Changes |
|-----------|----------------|------------|------------------|
| CallId matching | braft, Apache Ratis | Medium | No |
| Version counter | sofa-jraft | Low | No |
| RPC client ID | NuRaft | Low | No |

## Protection Mechanism Examples
| Membership check | canonical-raft, Ra | Medium | No |

### sofa-jraft: Version Counter ✓

Increment a version counter when replication session resets. Responses with mismatched version are rejected as stale.

```java
private int version = 0;  // Incremented on reset

if (stateVersion != r.version) {
    return;  // Reject stale response
}
```

### canonical/raft: Configuration Membership ✓

Check if the response sender is still in the current cluster configuration. Responses from removed nodes are rejected.

```c
server = configurationGet(&r->configuration, id);
if (server == NULL) {
    return 0;  // Response from non-member rejected
}
```

## 📁 Individual Implementation Analyses

All implementations have detailed individual analysis reports in [analysis/](analysis/):

**Protected (6 implementations)**:
- [apache-ratis.md](analysis/apache-ratis.md) - CallId matching with RequestMap
- [braft.md](analysis/braft.md) - CallId-based session tracking
- [canonical-raft.md](analysis/canonical-raft.md) - Configuration membership check
- [nuraft.md](analysis/nuraft.md) - RPC client ID validation
- [rabbitmq-ra.md](analysis/rabbitmq-ra.md) - Cluster membership validation
- [sofa-jraft.md](analysis/sofa-jraft.md) - Version counter

**Vulnerable (9 implementations)**:
- [dragonboat.md](analysis/dragonboat.md) - Term-only validation
- [etcd-raft.md](analysis/etcd-raft.md) - No session validation
- [hashicorp-raft.md](analysis/hashicorp-raft.md) - No session isolation
- [logcabin.md](analysis/logcabin.md) - Insufficient epoch validation
- [pysyncobj.md](analysis/pysyncobj.md) - Zero validation
- [raft-java.md](analysis/raft-java.md) - No request-response correlation
- [raft-rs.md](analysis/raft-rs.md) - Monotonicity check insufficient
- [redisraft.md](analysis/redisraft.md) - msg_id resets on rejoin
- [willemt-raft.md](analysis/willemt-raft.md) - Insufficient stale detection

**Not Applicable (1 implementation)**:
- [eliben-raft.md](analysis/eliben-raft.md) - No membership changes (educational)

## Scripts

Clone all 16 implementations for local analysis:

```bash
./clone-repos.sh
```

Shallow clone (~500MB), skips existing repos. Cloned repos are gitignored.

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

See the [SURVEY REPORT](SURVEY-REPORT.md) for detailed solutions and code examples.


## 🤝 Contributing

To add more implementations: open an [issue](https://github.com/drmingdrmer/raft-rejoin-bug/issues/new).

---

**Survey**: 16 implementations, 60K+ stars, 67% vulnerable (November 2025)
