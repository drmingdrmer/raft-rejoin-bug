#!/bin/bash
repos=(
    "brpc/braft|braft"
    "apache/ratis|apache-ratis"
    "wenweihu86/raft-java|raft-java"
    "ebay/nuraft|nuraft"
    "logcabin/logcabin|logcabin"
    "eliben/raft|eliben-raft"
    "dotnet/dotNext|dotnext"
    "apache/kudu|apache-kudu"
    "rabbitmq/ra|rabbitmq-ra"
    "bakwc/PySyncObj|pysyncobj"
)

for repo_info in "${repos[@]}"; do
    repo=$(echo $repo_info | cut -d'|' -f1)
    dir=$(echo $repo_info | cut -d'|' -f2)
    
    if [ -d "$dir" ]; then
        echo "Skipping $dir (already exists)"
        continue
    fi
    
    echo "Cloning $repo into $dir..."
    git clone --depth 1 "https://github.com/$repo.git" "$dir" 2>&1 | head -3
    sleep 1
done
