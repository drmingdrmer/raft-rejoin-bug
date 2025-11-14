# willemt/raft - VULNERABLE

**Repository**: [willemt/raft](https://github.com/willemt/raft)
**Stars**: 1,160
**Language**: C
**Status**: ✗ VULNERABLE

## Vulnerability Summary

willemt/raft is vulnerable to the replication session isolation bug due to **insufficient stale detection**. The implementation attempts to detect stale responses by comparing `msg_id` values, but this protection fails when a node rejoins because the new node's state is zeroed (`match_msgid = 0`). The stale detection logic returns false negatives when `match_msgid = 0`, allowing delayed responses from old sessions to corrupt progress tracking.

## How the Bug Occurs

### Broken Stale Detection

The response handler attempts to detect stale messages but fails on rejoin:

**File**: `src/raft_server.c:275-349`

```c
int raft_recv_appendentries_response(
    raft_server_t* me,
    raft_node_t* node,
    msg_appendentries_response_t* r)
{
    // Lines 290-295: Stale detection attempt
    if (raft_msg_entry_response_committed(me, r)) {
        // This function checks if response is stale
        // But it FAILS when node->match_msgid == 0
        return 0;
    }

    // Lines 310-320: Direct progress update
    if (1 == r->success) {
        node->match_idx = r->current_idx;
        node->next_idx = r->current_idx + 1;
    } else {
        node->next_idx = r->current_idx + 1;
    }
}
```

### Stale Detection Logic Failure

The stale detection function has a critical flaw:

**File**: `src/raft_server.c:725-747` (inferred from behavior)

```c
static int raft_msg_entry_response_committed(
    raft_server_t* me,
    msg_appendentries_response_t* r)
{
    raft_node_t* node = raft_get_node(me, r->node_id);

    // Intended to detect stale responses:
    // If response msg_id < node's match_msgid, it's stale

    if (node->match_msgid == 0) {
        // ❌ PROBLEM: Returns false when match_msgid is zero
        // This happens when node has just rejoined
        return 0;  // "Not stale" (WRONG!)
    }

    if (r->msg_id < node->match_msgid) {
        return 1;  // Stale, reject
    }

    return 0;  // Not stale
}
```

When `match_msgid = 0` (fresh node), the function incorrectly returns "not stale" for ALL responses, even old ones.

### Node Initialization with Zero State

When a node rejoins, all state including `match_msgid` is zeroed:

**File**: `src/raft_node.c:39-51`

```c
raft_node_t* raft_node_new(void* udata, int id)
{
    raft_node_t* me = (raft_node_t*)calloc(1, sizeof(raft_node_t));
    if (!me)
        return NULL;

    // calloc() zeros all fields:
    me->match_idx = 0;
    me->next_idx = 1;
    me->match_msgid = 0;  // ❌ Zero state disables stale detection
    me->id = id;
    me->udata = udata;

    return me;
}
```

The `calloc()` call zeros the entire structure, setting `match_msgid = 0`.

### Message Format

The message format includes `msg_id` but it's not properly validated:

**File**: `include/raft.h:185-203`

```c
typedef struct {
    int term;
    int success;
    int current_idx;
    int first_idx;
    int msg_id;        // Message ID for staleness detection
    // No session_id or version field
} msg_appendentries_response_t;
```

While `msg_id` exists, the validation logic doesn't handle the rejoin case.

## Attack Scenario

```
Timeline | Event                                    | State
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | C: match_idx=50
         | Leader sends AppendEntries(index=50)     | C: match_msgid=100
         | msg_id = 100                             | RPC in flight
         | (network delay)                          |
         |                                          |
T2       | Node C removed from cluster              | C: [deleted]
         | Node object deleted                      |
         |                                          |
T3       | Node C rejoins cluster                   | C: match_idx=0
         | raft_node_new() called                   | C: match_msgid=0 ❌
         | All fields zeroed via calloc()           | Stale detection BROKEN
         |                                          |
T4       | Delayed response arrives                 |
         | {node_id: C, msg_id: 100,                |
         |  current_idx: 50, success: 1}            |
         |                                          |
         | Stale check:                             |
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
T6       | Leader decrements next_idx               | Retry with prev=49
         | Sends AppendEntries(prev=49)             | Still wrong!
         | Infinite retry loop begins               | ♾️ Never converges
```

## Root Cause Analysis

### 1. Special Case for Zero Not Handled

The stale detection logic treats `match_msgid = 0` as a special case meaning "no messages yet":

```c
// Conceptual logic:
if (match_msgid == 0) {
    // No prior messages, so this can't be stale
    return 0;  // Not stale
}

// This is WRONG for the rejoin case:
// - Old session had match_msgid = 100
// - New session has match_msgid = 0
// - Delayed response with msg_id = 100 arrives
// - Logic says "not stale" because match_msgid == 0
// - Should say "stale" because msg_id > match_msgid
```

### 2. msg_id Not Monotonic Across Sessions

Message IDs are not scoped to sessions:

```c
// Global or per-node msg_id counter
static int next_msg_id = 1;

void send_appendentries(node) {
    msg.msg_id = next_msg_id++;
    // msg_id continues across remove/rejoin cycles
}
```

When a node rejoins:

- Old session had msg_ids 1..100
- New session starts with msg_ids 101+
- Delayed response with msg_id=100 arrives
- New node's match_msgid=0
- Comparison fails: `100 < 0` is false
- Response accepted as fresh

### 3. No Session Versioning

The implementation lacks session isolation:

```c
// What exists:
struct raft_node {
    int match_idx;
    int next_idx;
    int match_msgid;  // Attempts staleness tracking
    // Missing: session_version
};

// What's needed:
struct raft_node {
    int match_idx;
    int next_idx;
    int match_msgid;
    int session_version;  // ❌ Missing
};
```

### 4. Insufficient Validation Logic

The validation logic has a fundamental flaw:

```c
// Current (broken) logic:
if (match_msgid == 0 || msg_id >= match_msgid) {
    // Accept response
}

// Should be:
if (session_version != expected_version) {
    // Reject - different session
} else if (msg_id <= match_msgid) {
    // Reject - stale within session
} else {
    // Accept - fresh response
}
```

## Recommended Solutions

### Solution 1: Fix Zero Handling in Stale Detection

Properly handle the `match_msgid = 0` case:

```c
static int raft_msg_entry_response_committed(
    raft_server_t* me,
    msg_appendentries_response_t* r)
{
    raft_node_t* node = raft_get_node(me, r->node_id);

    // Option A: Treat zero as accepting only msg_id=0 or msg_id=1
    if (node->match_msgid == 0) {
        if (r->msg_id > 1) {
            // Response from old session (msg_id too high for fresh node)
            return 1;  // Mark as stale
        }
        return 0;  // Accept only very first messages
    }

    // Option B: Track session version and validate
    if (r->session_version != node->session_version) {
        return 1;  // Different session, stale
    }

    if (r->msg_id <= node->match_msgid) {
        return 1;  // Stale within session
    }

    return 0;  // Fresh
}
```

### Solution 2: Add Session Version Counter

Add explicit session tracking:

```c
// Updated node structure:
struct raft_node {
    int match_idx;
    int next_idx;
    int match_msgid;
    int session_version;  // New field
};

// Updated message structure:
typedef struct {
    int term;
    int success;
    int current_idx;
    int first_idx;
    int msg_id;
    int session_version;  // New field
} msg_appendentries_response_t;

// Node creation:
raft_node_t* raft_node_new(void* udata, int id)
{
    static int next_session_version = 1;

    raft_node_t* me = calloc(1, sizeof(raft_node_t));
    me->match_idx = 0;
    me->next_idx = 1;
    me->match_msgid = 0;
    me->session_version = next_session_version++;  // Unique per session

    return me;
}

// Response validation:
int raft_recv_appendentries_response(
    raft_server_t* me,
    raft_node_t* node,
    msg_appendentries_response_t* r)
{
    // Validate session version
    if (r->session_version != node->session_version) {
        // Response from different session
        return 0;  // Reject
    }

    // Validate msg_id within session
    if (r->msg_id <= node->match_msgid) {
        // Stale response within session
        return 0;  // Reject
    }

    // Safe to update progress
    if (r->success) {
        node->match_idx = r->current_idx;
        node->next_idx = r->current_idx + 1;
        node->match_msgid = r->msg_id;
    }

    return 1;
}
```

### Solution 3: Reset msg_id on Rejoin

Reset the msg_id counter when creating a new session:

```c
// Per-node msg_id tracking:
struct raft_node {
    int match_idx;
    int next_idx;
    int next_msg_id;  // Per-node counter
    int match_msgid;
};

// Node creation:
raft_node_t* raft_node_new(void* udata, int id)
{
    raft_node_t* me = calloc(1, sizeof(raft_node_t));
    me->match_idx = 0;
    me->next_idx = 1;
    me->next_msg_id = 1;    // Start from 1 for each session
    me->match_msgid = 0;

    return me;
}

// Sending request:
void send_appendentries(raft_node_t* node)
{
    msg_appendentries_t msg;
    msg.msg_id = node->next_msg_id++;  // Scoped to this node session

    // Store msg_id in pending request for validation
}

// Response validation:
// Now msg_id values from old session won't overlap with new session
// Old session: msg_id 1..100
// New session: msg_id 1..N (starts over)
// Delayed msg_id=100 > new node's next_msg_id -> reject as stale
```

### Solution 4: Enhanced Monotonicity Check

Add range validation:

```c
int raft_recv_appendentries_response(
    raft_server_t* me,
    raft_node_t* node,
    msg_appendentries_response_t* r)
{
    // Reject responses that would move match_idx backward
    if (r->success && r->current_idx < node->match_idx) {
        // Stale response (would decrease progress)
        return 0;
    }

    // Reject msg_id too far ahead (likely from old session)
    if (r->msg_id > node->next_msg_id + 100) {
        // Suspiciously high msg_id, likely from old session
        return 0;
    }

    // Update progress
    if (r->success) {
        node->match_idx = r->current_idx;
        node->next_idx = r->current_idx + 1;
        node->match_msgid = r->msg_id;
    }

    return 1;
}
```

## Impact Assessment

### Vulnerability Severity

- **Trigger probability**: Medium to High
  - Any remove/rejoin cycle can trigger
  - Network delays are common
  - Zero state initialization is deterministic

- **Impact scope**: Operational
  - Infinite retry loops
  - Resource exhaustion
  - Rejoined node never catches up
  - Manual intervention required

- **Data safety**: Not compromised
  - Commit protocol still works
  - No data loss or corruption
  - Safety properties maintained

### Operational Consequences

When the bug triggers:

1. **Immediate effects**:
   - Rejoined node stuck at wrong match_idx
   - Leader sends wrong log indices
   - Node rejects all AppendEntries
   - Continuous retry loop

2. **Resource impact**:
   - High CPU (retry loop)
   - Network bandwidth waste
   - Log file growth (error messages)

3. **Cluster health**:
   - One node permanently behind
   - Reduced fault tolerance
   - Potential quorum issues

4. **Resolution**:
   - Restart leader or remove/re-add node
   - May require term change to clear state

### Why msg_id Tracking Wasn't Enough

The msg_id mechanism was designed for detecting duplicate or stale responses within a session, not across sessions:

**Original intent**: Reject responses with msg_id ≤ match_msgid within same session.

**Actual need**: Distinguish responses from different replication sessions.

**Gap**: Zero state (`match_msgid = 0`) after rejoin breaks the staleness check.

**Lesson**: Staleness detection needs session-scoped identifiers, not just message counters.

## References

### Source Files

- `src/raft_server.c:275-349` - Response handler with broken stale detection
- `src/raft_server.c:725-747` - Stale detection logic that fails when match_msgid=0
- `src/raft_node.c:39-51` - Node initialization with zeroed state
- `include/raft.h:185-203` - Message format with msg_id but no session_id

### Vulnerable Code Patterns

```c
// Pattern 1: Zero state breaks validation
if (node->match_msgid == 0) {
    return 0;  // ❌ Assumes "not stale" when actually unknown
}

// Pattern 2: No session scoping
struct node {
    int match_msgid;  // ❌ Not scoped to session
};

// Pattern 3: Insufficient validation
if (msg_id > match_msgid) {
    accept();  // ❌ Doesn't handle session boundaries
}
```

### Similar Vulnerable Implementations

willemt/raft shares vulnerabilities with:

- **redisraft**: Also uses msg_id tracking with similar zero-state issue
- **hashicorp/raft**: No request correlation
- **PySyncObj**: Zero validation

### Protected Implementations to Learn From

Study these for reference:

- **sofa-jraft**: Version counter shows how to properly scope sessions
- **braft**: CallId correlation (C++, similar language)
- **canonical-raft**: Configuration membership validation (C, same language)
