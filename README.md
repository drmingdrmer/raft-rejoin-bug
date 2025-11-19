# Raft Replication Session Isolation Bug Survey

Survey of 17 popular Raft implementations analyzing their vulnerability to a replication progress corruption bug during membership changes. See [SURVEY-REPORT.md](SURVEY-REPORT.md) for detailed analysis and solutions.

## The Bug

When a node is removed and re-added to a cluster within the same term, delayed AppendEntries responses from the old replication session can corrupt the new session's progress tracking.

**Root cause**: Membership changes don't require term changes, so term-only validation cannot distinguish responses from old vs new replication sessions.

**Impact**:
- ✗ Operational: Infinite retry loops, resource exhaustion, misleading error logs
- ✓ Data safety: Not compromised (Raft's commit protocol still ensures safety)

## Survey Results

| Implementation | Stars | Language | Status | Analysis |
|----------------|------:|----------|--------|----------|
| Apache Ratis | 1,418 | Java | ✓ PROTECTED | [Report](analysis/apache-ratis.md) |
| NuRaft | 1,140 | C++ | ✓ PROTECTED | [Report](analysis/nuraft.md) |
| OpenRaft | 1,700 | Rust | ✓ PROTECTED | [Report](analysis/openraft.md) |
| RabbitMQ Ra | 908 | Erlang | ✓ PROTECTED | [Report](analysis/rabbitmq-ra.md) |
| braft | 4,174 | C++ | ✓ PROTECTED | [Report](analysis/braft.md) |
| canonical/raft | 954 | C | ✓ PROTECTED | [Report](analysis/canonical-raft.md) |
| sofa-jraft | 3,762 | Java | ✓ PROTECTED | [Report](analysis/sofa-jraft-analysis.md) |
| **LogCabin** | **1,945** | **C++** | **✗ VULNERABLE** | [Report](analysis/logcabin.md) |
| **PySyncObj** | **738** | **Python** | **✗ VULNERABLE** | [Report](analysis/pysyncobj.md) |
| **dragonboat** | **5,262** | **Go** | **✗ VULNERABLE** | [Report](analysis/dragonboat.md) |
| **etcd-io/raft** | **943** | **Go** | **✗ VULNERABLE** | [Report](analysis/etcd-raft.md) |
| **hashicorp/raft** | **8,826** | **Go** | **✗ VULNERABLE** | [Report](analysis/hashicorp-raft-analysis.md) |
| **raft-java** | **1,234** | **Java** | **✗ VULNERABLE** | [Report](analysis/raft-java.md) |
| **raft-rs (TiKV)** | **3,224** | **Rust** | **✗ VULNERABLE** | [Report](analysis/raft-rs.md) |
| **redisraft** | **841** | **C** | **✗ VULNERABLE** | [Report](analysis/redisraft.md) |
| **willemt/raft** | **1,160** | **C** | **✗ VULNERABLE** | [Report](analysis/willemt-raft.md) |
| eliben/raft | 1,232 | Go | N/A | [Report](analysis/eliben-raft.md) |

## Clone Repositories

```bash
./clone-repos.sh
```

---

*November 2025*
