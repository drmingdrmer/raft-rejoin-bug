# RedisRaft - VULNERABLE

**Repository**: [RedisLabs/redisraft](https://github.com/RedisLabs/redisraft)
**Stars**: 841
**Language**: C
**Status**: ✗ VULNERABLE

## Vulnerability Summary

RedisRaft is vulnerable to the replication session isolation bug due to **msg_id reset on rejoin**. The implementation embeds willemt/raft library and inherits its msg_id-based stale detection mechanism. However, this protection is undermined by a missing NULL check that causes the implementation to use uninitialized node state, and by the fact that rejoined nodes have `match_msgid = 0`, which breaks the staleness detection logic.

## How the Bug Occurs

### Missing NULL Check

The response handler has a critical missing NULL check:

**File**: `src/raft.c:888-893`

```c
static void handleAppendEntriesResponse(
    RedisRaftCtx *rr,
    Node *node,
    raft_appendentries_resp_t *r)
{
    raft_node_t *raft_node = raft_get_node(rr->raft, node->id);

    // ❌ MISSING: NULL check for raft_node
    // If node was removed, raft_node could be NULL

    // Direct call without validation:
    raft_recv_appendentries_response(rr->raft, raft_node, r);

    // If raft_node is NULL, this crashes or uses invalid memory
    // If raft_node is newly created, it has match_msgid = 0
}
```

The code doesn't check if `raft_node` is NULL before using it.

### Underlying willemt/raft Vulnerability

RedisRaft uses willemt/raft library, which has broken stale detection:

**File**: `deps/raft/src/raft_node.c:40-56`

```c
raft_node_t* raft_node_new(void* udata, int id)
{
    raft_node_t* me = (raft_node_t*)calloc(1, sizeof(raft_node_t));
    if (!me)
        return NULL;

    // All fields zeroed by calloc():
    me->next_idx = 1;
    me->match_idx = 0;
    me->match_msgid = 0;  // ❌ Zero state breaks stale detection
    me->id = id;
    me->udata = udata;

    return me;
}
```

When a node rejoins, `match_msgid = 0` causes the stale detection to fail.

### Stale Check Failure

The stale detection logic in willemt/raft fails with zero state:

**File**: `deps/raft/src/raft_server.c:725-747`

```c
static int raft_msg_entry_response_committed(
    raft_server_t* me,
    msg_appendentries_response_t* r)
{
    raft_node_t* node = raft_get_node(me, r->node_id);

    // When node rejoins, match_msgid = 0
    if (node->match_msgid == 0) {
        // ❌ PROBLEM: Returns "not stale" for all responses
        // Even responses from old session are accepted
        return 0;  // "Not stale" - WRONG!
    }

    if (r->msg_id < node->match_msgid) {
        return 1;  // Stale
    }

    return 0;  // Not stale
}
```

### Two-Layer Vulnerability

RedisRaft has a two-layer vulnerability:

**Layer 1 (RedisRaft wrapper)**:

- Missing NULL check when retrieving node
- May use stale or invalid node pointer
- No session validation in wrapper code

**Layer 2 (willemt/raft library)**:

- Zero state (`match_msgid = 0`) breaks stale detection
- No session versioning
- Insufficient validation logic

## Attack Scenario

```
Timeline | Event                                    | State
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | C: match_idx=50
         | Leader sends AppendEntries(index=50)     | C: match_msgid=100
         | msg_id = 100                             | RPC in flight
         | (network delay)                          |
         |                                          |
T2       | Node C removed from cluster              | raft_node[C] deleted
         | raft_remove_node(C) called               | C: [deleted]
         |                                          |
T3       | Node C rejoins cluster                   | raft_node[C] created
         | raft_add_node(C) called                  | C: match_idx=0
         | raft_node_new() creates fresh node       | C: match_msgid=0 ❌
         |                                          |
T4       | Delayed response arrives                 |
         | {node_id: C, msg_id: 100,                |
         |  current_idx: 50, success: 1}            |
         |                                          |
         | RedisRaft handler:                       |
         | raft_node = raft_get_node(C)             | Gets NEW node
         | // Missing NULL check ❌                 |
         |                                          |
         | willemt/raft stale check:                |
         | raft_msg_entry_response_committed()      |
         | -> node->match_msgid == 0                | ❌ Returns "not stale"
         | -> returns 0 (NOT stale)                 | Wrong!
         |                                          |
         | Progress update:                         |
         | node->match_idx = 50   // ❌ CORRUPTED  | C.match = 50 ✗
         | node->next_idx = 51    // ❌ CORRUPTED  | C.next = 51 ✗
         | node->match_msgid = 100                  |
         |                                          |
T5       | Leader sends AppendEntries(prev=50)      | Wrong index!
         | Node C rejects (doesn't have index 50)   | Conflict
         | response.success = 0                     |
         |                                          |
T6       | Infinite retry loop begins               | ♾️ Never converges
```

## Root Cause Analysis

### 1. Dependency on Vulnerable Library

RedisRaft uses willemt/raft which has fundamental session isolation issues:

```c
// Inherited vulnerability:
// deps/raft/ - willemt/raft library
//   - No session versioning
//   - Zero state breaks stale detection
//   - msg_id not scoped to sessions
```

### 2. Insufficient Wrapper Validation

The RedisRaft wrapper doesn't add protection:

```c
// Current (vulnerable) wrapper:
static void handleAppendEntriesResponse(...) {
    raft_node_t *raft_node = raft_get_node(rr->raft, node->id);
    // ❌ No NULL check
    // ❌ No session validation
    // ❌ Delegates directly to library

    raft_recv_appendentries_response(rr->raft, raft_node, r);
}

// Should be:
static void handleAppendEntriesResponse(...) {
    raft_node_t *raft_node = raft_get_node(rr->raft, node->id);

    if (raft_node == NULL) {
        // Node not in cluster, reject response
        return;
    }

    if (raft_node->session_version != r->session_version) {
        // Response from old session, reject
        return;
    }

    raft_recv_appendentries_response(rr->raft, raft_node, r);
}
```

### 3. No Session Tracking at RedisRaft Layer

RedisRaft doesn't add session tracking above the library:

```c
// Missing in RedisRaft:
typedef struct Node {
    int id;
    char addr[256];
    // Missing: uint64_t session_version;
} Node;

typedef struct RedisRaftCtx {
    raft_server_t *raft;
    // Missing: session tracking
} RedisRaftCtx;
```

### 4. Trust in Library Validation

RedisRaft assumes the underlying library provides sufficient validation:

```c
// Assumption: willemt/raft will reject stale responses
raft_recv_appendentries_response(rr->raft, raft_node, r);

// Reality: Library validation fails when match_msgid = 0
```

## Recommended Solutions

### Solution 1: Add NULL Check (Immediate)

Fix the missing NULL check as an immediate mitigation:

```c
static void handleAppendEntriesResponse(
    RedisRaftCtx *rr,
    Node *node,
    raft_appendentries_resp_t *r)
{
    raft_node_t *raft_node = raft_get_node(rr->raft, node->id);

    // Add NULL check
    if (raft_node == NULL) {
        RRLog(LOG_DEBUG, "Response from non-member node %d, ignoring", node->id);
        return;
    }

    raft_recv_appendentries_response(rr->raft, raft_node, r);
}
```

Note: This only prevents crashes, doesn't fix the session isolation bug.

### Solution 2: Add Session Versioning to RedisRaft

Implement session tracking at the RedisRaft layer:

```c
// Enhanced Node structure:
typedef struct Node {
    int id;
    char addr[256];
    uint64_t session_version;  // New field
} Node;

// Enhanced message structure:
typedef struct {
    int node_id;
    int msg_id;
    int current_idx;
    int success;
    uint64_t session_version;  // New field
} raft_appendentries_resp_t;

// Node creation:
static void addNode(RedisRaftCtx *rr, int node_id) {
    static uint64_t next_session_version = 1;

    Node *node = createNode(node_id);
    node->session_version = next_session_version++;

    raft_add_node(rr->raft, node_id);

    // Store mapping
    rr->nodes[node_id] = node;
}

// Sending request:
static void sendAppendEntries(RedisRaftCtx *rr, Node *node) {
    raft_appendentries_req_t req;
    req.session_version = node->session_version;  // Include version
    // ... send request ...
}

// Handling response:
static void handleAppendEntriesResponse(
    RedisRaftCtx *rr,
    Node *node,
    raft_appendentries_resp_t *r)
{
    raft_node_t *raft_node = raft_get_node(rr->raft, node->id);

    if (raft_node == NULL) {
        return;  // Not in cluster
    }

    // Validate session version
    if (r->session_version != node->session_version) {
        RRLog(LOG_DEBUG, "Stale response from node %d (session %lu != %lu)",
              node->id, r->session_version, node->session_version);
        return;
    }

    // Safe to process
    raft_recv_appendentries_response(rr->raft, raft_node, r);
}
```

### Solution 3: Fix willemt/raft Library

Submit upstream fix to willemt/raft:

```c
// deps/raft/src/raft_node.c
typedef struct raft_node {
    int id;
    int next_idx;
    int match_idx;
    int match_msgid;
    int session_version;  // New field
} raft_node_t;

raft_node_t* raft_node_new(void* udata, int id)
{
    static int next_session_version = 1;

    raft_node_t* me = calloc(1, sizeof(raft_node_t));
    me->id = id;
    me->next_idx = 1;
    me->match_idx = 0;
    me->match_msgid = 0;
    me->session_version = next_session_version++;  // Unique per node creation

    return me;
}

// deps/raft/src/raft_server.c
int raft_recv_appendentries_response(
    raft_server_t* me,
    raft_node_t* node,
    msg_appendentries_response_t* r)
{
    // Validate session version
    if (r->session_version != node->session_version) {
        return 0;  // Stale session
    }

    // Existing validation and processing...
}
```

### Solution 4: Membership Validation

Add configuration-based validation:

```c
static void handleAppendEntriesResponse(
    RedisRaftCtx *rr,
    Node *node,
    raft_appendentries_resp_t *r)
{
    // Check node is in current configuration
    if (!isNodeInConfiguration(rr, node->id)) {
        RRLog(LOG_WARNING, "Response from node %d not in configuration", node->id);
        return;
    }

    raft_node_t *raft_node = raft_get_node(rr->raft, node->id);
    if (raft_node == NULL) {
        return;
    }

    raft_recv_appendentries_response(rr->raft, raft_node, r);
}
```

## Impact Assessment

### Vulnerability Severity

- **Trigger probability**: Medium to High
  - Redis deployments often have dynamic membership
  - Network delays are common
  - Zero state initialization is deterministic
  - Missing NULL check adds crash risk

- **Impact scope**: Operational + Stability
  - Infinite retry loops (from inherited willemt/raft bug)
  - Potential crashes (from missing NULL check)
  - Resource exhaustion
  - Manual intervention required

- **Data safety**: Not compromised
  - Raft commit protocol still works
  - No data loss or corruption
  - Safety properties maintained

### RedisRaft-Specific Concerns

As a Redis module providing Raft consensus:

1. **High visibility**: Redis is widely deployed
2. **Production usage**: Used for Redis cluster consensus
3. **Stability expectations**: Crashes are unacceptable
4. **Performance sensitivity**: Retry loops waste resources

### Operational Consequences

When the bug triggers:

1. **Immediate effects**:
   - Rejoined node stuck with wrong progress
   - Continuous retry loop (CPU, network waste)
   - Possible crash if NULL check missing

2. **Redis cluster impact**:
   - One Raft node permanently behind
   - Reduced fault tolerance
   - Potential split-brain if quorum affected

3. **Detection**:
   - High CPU on leader
   - Network traffic spikes
   - Redis log entries showing conflicts
   - Module crash dumps (if NULL check missing)

4. **Mitigation**:
   - Restart Redis instance (leader)
   - Remove and re-add node with term change
   - Upgrade to fixed version

## References

### Source Files

- `src/raft.c:888-893` - RedisRaft response handler with missing NULL check
- `deps/raft/src/raft_node.c:40-56` - willemt/raft node initialization with `match_msgid = 0`
- `deps/raft/src/raft_server.c:725-747` - Stale detection logic that fails when `match_msgid = 0`

### Dependency Chain

```
RedisRaft (wrapper)
  └── willemt/raft (library)
      ├── raft_node.c - Node state management
      ├── raft_server.c - Core Raft logic
      └── Stale detection - Broken with zero state
```

Both layers contribute to the vulnerability.

### Vulnerable Code Patterns

```c
// Pattern 1: Missing NULL check
raft_node_t *node = raft_get_node(raft, id);
raft_recv_response(raft, node, response);  // ❌ No NULL check

// Pattern 2: Zero state breaks validation
if (node->match_msgid == 0) {
    return 0;  // ❌ Assumes "not stale"
}

// Pattern 3: Trust in library
// Wrapper assumes library validates correctly
raft_recv_response(raft, node, response);  // ❌ Library validation broken
```

### Similar Vulnerable Implementations

RedisRaft shares vulnerabilities with:

- **willemt/raft**: Directly inherits the bug (1,160 stars)
- **hashicorp/raft**: No session isolation (8,826 stars)
- **raft-java**: No request correlation (1,234 stars)

### Protected Implementations to Learn From

Study these for reference:

- **canonical-raft**: Configuration membership validation (C, similar language)
- **braft**: CallId-based session tracking (C++, similar to C)
- **sofa-jraft**: Version counter per replicator
- **NuRaft**: RPC client ID validation

### Recommendations for RedisRaft

**Immediate** (hotfix):

1. Add NULL check in `handleAppendEntriesResponse()`
2. Add configuration membership validation

**Short-term**:

1. Implement session versioning at RedisRaft layer
2. Add comprehensive response validation

**Long-term**:

1. Contribute fix to upstream willemt/raft
2. Or consider switching to a protected Raft library
3. Add comprehensive test coverage for membership changes
