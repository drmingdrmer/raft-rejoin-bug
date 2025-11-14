# Individual Implementation Analysis Reports

This directory contains detailed analysis reports for all 16 Raft implementations surveyed for the replication session isolation bug.

## Protected Implementations (6)

These implementations have mechanisms to prevent the replication session isolation bug:

| Implementation | Stars | Protection Mechanism | Analysis |
|----------------|-------|---------------------|----------|
| braft | 4,174 | CallId-based session tracking | [braft.md](braft.md) |
| sofa-jraft | 3,762 | Version counter | [sofa-jraft.md](sofa-jraft.md) |
| Apache Ratis | 1,418 | CallId matching with RequestMap | [apache-ratis.md](apache-ratis.md) |
| NuRaft | 1,140 | RPC client ID validation | [nuraft.md](nuraft.md) |
| canonical-raft | 954 | Configuration membership check | [canonical-raft.md](canonical-raft.md) |
| RabbitMQ Ra | 908 | Cluster membership validation | [rabbitmq-ra.md](rabbitmq-ra.md) |

## Vulnerable Implementations (9)

These implementations are vulnerable to the bug and require fixes:

| Implementation | Stars | Issue | Analysis |
|----------------|-------|-------|----------|
| hashicorp/raft | 8,826 | No session isolation | [hashicorp-raft.md](hashicorp-raft.md) |
| dragonboat | 5,262 | Term-only validation | [dragonboat.md](dragonboat.md) |
| raft-rs (TiKV) | 3,224 | Monotonicity check insufficient | [raft-rs.md](raft-rs.md) |
| LogCabin | 1,945 | Insufficient epoch validation | [logcabin.md](logcabin.md) |
| raft-java | 1,234 | No request-response correlation | [raft-java.md](raft-java.md) |
| willemt/raft | 1,160 | Insufficient stale detection | [willemt-raft.md](willemt-raft.md) |
| etcd-io/raft | 943 | No session validation | [etcd-raft.md](etcd-raft.md) |
| redisraft | 841 | msg_id resets on rejoin | [redisraft.md](redisraft.md) |
| PySyncObj | 738 | Zero validation | [pysyncobj.md](pysyncobj.md) |

## Not Applicable (1)

| Implementation | Stars | Reason | Analysis |
|----------------|-------|--------|----------|
| eliben/raft | 1,232 | No membership changes (educational) | [eliben-raft.md](eliben-raft.md) |

## Analysis Structure

Each analysis report contains:

**For Vulnerable Implementations**:
- Vulnerability summary
- How the bug occurs (with code references and line numbers)
- Attack scenario timeline
- Root cause analysis
- Recommended solutions (multiple approaches)
- Impact assessment
- References to source code

**For Protected Implementations**:
- Protection summary
- How the protection works (with code references and line numbers)
- Protection flow timeline
- Key design principles
- Benefits and comparison with other approaches
- References to source code

## Quick Navigation

**By Language**:
- **Go**: hashicorp-raft, dragonboat, etcd-raft (all vulnerable)
- **Rust**: raft-rs (vulnerable)
- **Java**: sofa-jraft (protected), apache-ratis (protected), raft-java (vulnerable)
- **C++**: braft (protected), nuraft (protected), logcabin (vulnerable)
- **C**: canonical-raft (protected), willemt-raft (vulnerable), redisraft (vulnerable)
- **Erlang**: rabbitmq-ra (protected)
- **Python**: pysyncobj (vulnerable)

**By Protection Mechanism**:
- **CallId matching**: braft, apache-ratis
- **Version counter**: sofa-jraft
- **RPC client ID**: nuraft
- **Membership validation**: canonical-raft, rabbitmq-ra
- **None**: 9 vulnerable implementations

## Summary Statistics

- **Total**: 16 implementations analyzed
- **Protected**: 6 (37.5%)
- **Vulnerable**: 9 (56.25%)
- **N/A**: 1 (6.25%)
- **Combined stars**: 60,000+

## Related Documents

- [../README.md](../README.md) - Survey overview and document navigation
- [../SURVEY-REPORT.md](../SURVEY-REPORT.md) - Comprehensive survey report
- [../raft-rs-replication-bug.md](../raft-rs-replication-bug.md) - Technical article (English)
- [../raft-rs-replication-bug-zh.md](../raft-rs-replication-bug-zh.md) - Technical article (Chinese)
