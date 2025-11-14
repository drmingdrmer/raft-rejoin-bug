# eliben/raft - N/A (No Membership Changes)

**Repository**: [eliben/raft](https://github.com/eliben/raft)
**Stars**: 1,232
**Language**: Go
**Status**: N/A - Educational Implementation

## Summary

eliben/raft is an educational Raft implementation that **does not support membership changes**. The cluster configuration is static and fixed at initialization time. Since the replication session isolation bug specifically occurs during node removal and rejoin operations, this implementation is not affected by the surveyed vulnerability.

## Implementation Characteristics

### Static Cluster Configuration

The implementation uses a fixed, immutable cluster configuration:

```go
// Cluster configuration is set at initialization
type Server struct {
    id        int
    peers     []int  // Fixed list of peer IDs
    peerAddrs map[int]string  // Static peer addresses
    // No dynamic membership change support
}

func NewServer(id int, peers []int, peerAddrs map[int]string) *Server {
    s := &Server{
        id:        id,
        peers:     peers,
        peerAddrs: peerAddrs,
    }
    // Configuration never changes after this point
    return s
}
```

### No Membership Change Operations

The implementation provides no APIs for:

- Adding nodes to the cluster
- Removing nodes from the cluster
- Changing cluster configuration
- Joint consensus configurations

### Educational Purpose

eliben/raft is designed for educational purposes:

- **Goal**: Teach Raft consensus algorithm concepts
- **Focus**: Core Raft mechanisms (leader election, log replication, safety)
- **Scope**: Simplified implementation for learning
- **Non-goal**: Production-ready features like dynamic membership

### Static Progress Tracking

Progress tracking is initialized once and never recreated:

```go
type Server struct {
    // ... other fields ...

    // Fixed progress tracking for static peers
    nextIndex  map[int]int  // Never changes peer set
    matchIndex map[int]int  // Never changes peer set
}

func (s *Server) becomeLeader() {
    // Initialize progress for all peers (once)
    for _, peer := range s.peers {
        s.nextIndex[peer] = s.log.lastIndex() + 1
        s.matchIndex[peer] = 0
    }
    // These maps are never recreated or modified in structure
}
```

Since the peer set never changes, there's no opportunity for:

- Progress entries to be deleted and recreated
- Delayed responses from old sessions
- Session isolation issues

## Why This Implementation Is Not Vulnerable

### No Session Lifecycle Changes

The vulnerability requires:

1. ✗ Node removal from cluster
2. ✗ Node addition back to cluster
3. ✗ Delayed response from before removal

eliben/raft cannot perform steps 1 or 2, so the vulnerability cannot occur.

### Fixed Progress State

Progress tracking is created once per leadership term:

```
Timeline | Event                                    | Progress State
---------|------------------------------------------|------------------
T1       | Server becomes leader (term=5)           | nextIndex[A,B,C] created
         | Initialize progress for all peers        | matchIndex[A,B,C] = 0
         |                                          |
T2-TN    | Normal operation                         | Progress updated
         | AppendEntries sent and responses handled | Same map instances
         |                                          |
         | NO membership changes possible           | ✓ No deletion/recreation
         |                                          |
Term end | Server steps down or new leader          | Old progress discarded
         |                                          |
Next term| New leader elected                       | New term, new progress
         |                                          | Different term isolation
```

Each term gets fresh progress state, but within a term, the progress maps are stable.

### Implicit Session Isolation via Term

While eliben/raft doesn't explicitly track sessions, term changes provide natural session boundaries:

- **Leadership change**: New term, all progress reset
- **Within term**: Peer set is immutable
- **No rejoin within term**: Impossible by design

Therefore, delayed responses from previous terms are rejected by term validation:

```go
func (s *Server) handleAppendEntriesResponse(resp AppendEntriesResponse) {
    if resp.Term > s.currentTerm {
        s.becomeFollower(resp.Term)
        return
    }

    if resp.Term < s.currentTerm {
        // Old term, ignore
        return
    }

    // resp.Term == s.currentTerm
    // Within same term, peer set is immutable
    // No session isolation issue possible
}
```

## Comparison: If Membership Changes Were Added

If someone extended eliben/raft to support membership changes without adding session isolation, it would become vulnerable:

### Hypothetical Vulnerable Extension

```go
// ❌ VULNERABLE if implemented this way:
func (s *Server) RemoveNode(nodeID int) {
    // Remove from peer list
    delete(s.nextIndex, nodeID)
    delete(s.matchIndex, nodeID)
    s.peers = removeFrom(s.peers, nodeID)
}

func (s *Server) AddNode(nodeID int, addr string) {
    // Re-add to peer list
    s.peers = append(s.peers, nodeID)
    s.peerAddrs[nodeID] = addr
    s.nextIndex[nodeID] = s.log.lastIndex() + 1
    s.matchIndex[nodeID] = 0  // Fresh state
    // ❌ No session tracking
}

func (s *Server) handleAppendEntriesResponse(resp AppendEntriesResponse) {
    // ❌ No session validation
    match := s.matchIndex[resp.PeerID]
    s.matchIndex[resp.PeerID] = resp.LastLogIndex  // Vulnerable!
}
```

This would create the same vulnerability as hashicorp/raft, etcd-io/raft, etc.

### Protected Extension Approach

If membership changes were added with proper session isolation:

```go
// ✓ PROTECTED approach:
type Server struct {
    // ... other fields ...
    nextIndex       map[int]int
    matchIndex      map[int]int
    sessionVersion  map[int]uint64  // Track session per peer
    nextSessionID   uint64
}

func (s *Server) AddNode(nodeID int, addr string) {
    s.peers = append(s.peers, nodeID)
    s.peerAddrs[nodeID] = addr
    s.nextIndex[nodeID] = s.log.lastIndex() + 1
    s.matchIndex[nodeID] = 0

    // Assign unique session version
    s.sessionVersion[nodeID] = s.nextSessionID
    s.nextSessionID++
}

func (s *Server) sendAppendEntries(peerID int) {
    sessionVersion := s.sessionVersion[peerID]

    request := AppendEntriesRequest{
        SessionVersion: sessionVersion,  // Include in request
        // ... other fields ...
    }

    s.sendRPC(peerID, request)
}

func (s *Server) handleAppendEntriesResponse(resp AppendEntriesResponse) {
    // Validate session version
    if resp.SessionVersion != s.sessionVersion[resp.PeerID] {
        // Stale response from old session
        return
    }

    // Safe to update progress
    s.matchIndex[resp.PeerID] = resp.LastLogIndex
}
```

## Educational Value

### What eliben/raft Teaches Well

- Leader election mechanism
- Log replication protocol
- Commit protocol and safety
- Term-based validation
- Basic request-response handling

### What It Intentionally Omits

- Dynamic membership changes
- Log compaction / snapshots
- Client interaction protocols
- Session isolation mechanisms
- Production optimizations

### Learning Opportunity

The absence of membership changes in eliben/raft actually highlights an important lesson:

**Session isolation is a subtle, complex problem** that goes beyond basic Raft. Many implementations (including production ones) get this wrong, as shown by the survey results.

Students learning from eliben/raft should be aware:

1. Real Raft clusters need dynamic membership
2. Dynamic membership requires session isolation
3. Simple implementations can miss this requirement
4. Even popular production implementations have this bug

## References

### Repository Information

- **Purpose**: Educational Raft implementation
- **Scope**: Core Raft algorithm only
- **Completeness**: Intentionally simplified
- **Production use**: Not intended

### Related Educational Implementations

Other educational Raft implementations also typically omit membership changes:

- Focus on core algorithm understanding
- Avoid production complexity
- Simplified for learning

### Production Implementations

For production use, consider implementations with proper session isolation:

- **Protected**: OpenRaft, braft, Apache Ratis, NuRaft, RabbitMQ Ra, sofa-jraft, canonical-raft
- **Vulnerable**: hashicorp/raft, dragonboat, raft-rs, LogCabin, etcd-io/raft, and others

## Conclusion

eliben/raft is **not vulnerable** to the replication session isolation bug because it does not support membership changes. The static cluster configuration eliminates the possibility of node removal and rejoin, which are required for the bug to occur.

This is neither a strength nor a weakness of the implementation - it's simply outside the scope of an educational project. However, anyone extending this implementation to add membership changes should be aware of the session isolation requirement and study the protected implementations for reference.
