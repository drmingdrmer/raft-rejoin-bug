# Individual Implementation Analysis Reports

This directory contains detailed analysis reports for all 17 Raft implementations surveyed for the replication session isolation bug.

## Protected Implementations (7)

These implementations have mechanisms to prevent the replication session isolation bug:

| Implementation | Stars | Protection Mechanism | Analysis |
|----------------|------:|---------------------|----------|
| Apache Ratis | 1,418 | CallId matching with RequestMap | [apache-ratis.md](apache-ratis.md) |
| NuRaft | 1,140 | RPC client ID validation | [nuraft.md](nuraft.md) |
| OpenRaft | 1,700 | Vote + Membership log ID tracking | [openraft.md](openraft.md) |
| RabbitMQ Ra | 908 | Cluster membership validation | [rabbitmq-ra.md](rabbitmq-ra.md) |
| braft | 4,174 | CallId-based session tracking | [braft.md](braft.md) |
| canonical-raft | 954 | Configuration membership check | [canonical-raft.md](canonical-raft.md) |
| sofa-jraft | 3,762 | Version counter | [sofa-jraft.md](sofa-jraft.md) |

## Vulnerable Implementations (9)

These implementations are vulnerable to the bug and require fixes:

| Implementation | Stars | Issue | Analysis |
|----------------|------:|-------|----------|
| LogCabin | 1,945 | Insufficient epoch validation | [logcabin.md](logcabin.md) |
| PySyncObj | 738 | Zero validation | [pysyncobj.md](pysyncobj.md) |
| dragonboat | 5,262 | Term-only validation | [dragonboat.md](dragonboat.md) |
| etcd-io/raft | 943 | No session validation | [etcd-raft.md](etcd-raft.md) |
| hashicorp/raft | 8,826 | No session isolation | [hashicorp-raft.md](hashicorp-raft.md) |
| raft-java | 1,234 | No request-response correlation | [raft-java.md](raft-java.md) |
| raft-rs (TiKV) | 3,224 | Monotonicity check insufficient | [raft-rs.md](raft-rs.md) |
| redisraft | 841 | msg_id resets on rejoin | [redisraft.md](redisraft.md) |
| willemt/raft | 1,160 | Insufficient stale detection | [willemt-raft.md](willemt-raft.md) |

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
