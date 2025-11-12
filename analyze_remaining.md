# Implementations to Analyze

## Already Analyzed (8)
- ✓ hashicorp/raft (8,826 stars) - Go - VULNERABLE
- ✓ dragonboat (5,262 stars) - Go - VULNERABLE
- ✓ sofa-jraft (3,762 stars) - Java - PROTECTED
- ✓ tikv/raft-rs (3,224 stars) - Rust - VULNERABLE
- ✓ willemt/raft (1,160 stars) - C - VULNERABLE
- ✓ canonical/raft (954 stars) - C - PROTECTED
- ✓ etcd-io/raft (943 stars) - Go - VULNERABLE
- ✓ redisraft (841 stars) - C - VULNERABLE

## From repo-list.md with >700 stars - Not Yet Analyzed

### High Priority (>2000 stars)
1. braft (4,174 stars) - C++ - Baidu's Raft
2. LogCabin (1,945 stars) - C++
3. .NEXT Raft (1,861 stars) - C#
4. Kudu (1,892 stars) - C++ - Apache project

### Medium Priority (1000-2000 stars)
5. Apache Ratis (1,418 stars) - Java
6. raft-java (1,234 stars) - Java
7. eliben/raft (1,232 stars) - Go
8. NuRaft (1,140 stars) - C++ - eBay

### Lower Priority (700-1000 stars)
9. Ra (908 stars) - Erlang - RabbitMQ
10. PySyncObj (738 stars) - Python

### Note: Very Large Projects (Embedded Raft)
- TiKV (16,275) - Already analyzed raft-rs component
- RethinkDB (26,958) - Database with embedded Raft
- Seastar Raft (15,041) - ScyllaDB
- nebula-graph-storage (11,817) - Graph DB
- Aeron Cluster (8,222) - Messaging
- Tarantool (3,581) - Database

These are full database/messaging systems where Raft is embedded.
May be difficult to analyze just the Raft component.
