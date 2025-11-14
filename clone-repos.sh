#!/bin/bash

mkdir -p repos
cd repos

[ -d "hashicorp-raft" ] || git clone --depth 1 https://github.com/hashicorp/raft.git hashicorp-raft
[ -d "dragonboat" ] || git clone --depth 1 https://github.com/lni/dragonboat.git dragonboat
[ -d "sofa-jraft" ] || git clone --depth 1 https://github.com/sofastack/sofa-jraft.git sofa-jraft
[ -d "raft-rs" ] || git clone --depth 1 https://github.com/tikv/raft-rs.git raft-rs
[ -d "braft" ] || git clone --depth 1 https://github.com/brpc/braft.git braft
[ -d "apache-ratis" ] || git clone --depth 1 https://github.com/apache/ratis.git apache-ratis
[ -d "nuraft" ] || git clone --depth 1 https://github.com/ebay/nuraft.git nuraft
[ -d "raft-java" ] || git clone --depth 1 https://github.com/wenweihu86/raft-java.git raft-java
[ -d "logcabin" ] || git clone --depth 1 https://github.com/logcabin/logcabin.git logcabin
[ -d "eliben-raft" ] || git clone --depth 1 https://github.com/eliben/raft.git eliben-raft
[ -d "rabbitmq-ra" ] || git clone --depth 1 https://github.com/rabbitmq/ra.git rabbitmq-ra
[ -d "pysyncobj" ] || git clone --depth 1 https://github.com/bakwc/PySyncObj.git pysyncobj
[ -d "willemt-raft" ] || git clone --depth 1 https://github.com/willemt/raft.git willemt-raft
[ -d "canonical-raft" ] || git clone --depth 1 https://github.com/canonical/raft.git canonical-raft
[ -d "etcd-raft" ] || git clone --depth 1 https://github.com/etcd-io/raft.git etcd-raft
[ -d "redisraft" ] || git clone --depth 1 https://github.com/RedisLabs/redisraft.git redisraft
