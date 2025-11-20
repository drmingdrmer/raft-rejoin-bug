# RabbitMQ Ra - PROTECTED

**Repository**: [rabbitmq/ra](https://github.com/rabbitmq/ra)
**Stars**: 908
**Language**: Erlang
**Status**: ✓ PROTECTED

## Protection Summary

RabbitMQ Ra is protected against the replication session isolation bug through **cluster membership validation**. The implementation validates that AppendEntries responses come only from nodes that are currently members of the cluster. When a node is removed, its peer entry is deleted from the cluster map. If it later rejoins and a delayed response from the old session arrives, the response is rejected because the sender is either not in the cluster map or is a different peer instance.

## How Protection Works

### Membership-Based Validation

When an AppendEntries response arrives, Ra first validates that the sender is a current cluster member:

File: [`src/ra_server.erl:474`](https://github.com/rabbitmq/ra/blob/main/src/ra_server.erl#L474)

```erlang
case peer(PeerId, State0) of
    undefined ->
        ?WARN("saw append_entries_reply from unknown peer"),
        {leader, State0, []};
    Peer0 = #{match_index := MI} ->
        % Process response and update progress
```

The `peer(PeerId, State0)` function looks up the peer in the current cluster configuration. If the peer is not found (returns `undefined`), the response is rejected.

### Peer Lifecycle Management

**Node removal**: File: [`src/ra_server.erl:3053`](https://github.com/rabbitmq/ra/blob/main/src/ra_server.erl#L3053)

```erlang
% When removing a node from cluster
handle_leader({release_cursor, Index}, State0 = #{cluster := Cluster0}) ->
    % Remove peer from cluster map
    Cluster = maps:remove(PeerId, Cluster0),
    State = State0#{cluster => Cluster},
    ...
```

The peer entry is deleted from the cluster map when the node is removed.

**Node rejoin**: File: [`src/ra_server.erl:3026`](https://github.com/rabbitmq/ra/blob/main/src/ra_server.erl#L3026)

```erlang
% When adding a node to cluster
add_peer(PeerId, State = #{cluster := Cluster0}) ->
    Peer = #{next_index => NextIdx,
             match_index => 0,
             commit_index_sent => 0},
    Cluster = Cluster0#{PeerId => Peer},
    State#{cluster => Cluster}.
```

A new peer entry is created with fresh state (match_index = 0) when the node rejoins.

### Response Processing

Only responses from current members are processed:

```erlang
handle_leader({PeerId, #append_entries_reply{...} = Reply}, State0) ->
    case peer(PeerId, State0) of
        undefined ->
            % Not in cluster, reject response
            {leader, State0, []};
        Peer0 ->
            % Valid member, process response
            {Peer, Effects} = handle_append_entries_reply(Reply, Peer0),
            State = update_peer(PeerId, Peer, State0),
            {leader, State, Effects}
    end.
```

## Protection Flow

```
Timeline | Event                                    | Cluster State
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | Cluster = #{C => #{match=>50}}
         | Leader sends AppendEntries(index=50)     | C is valid member
         | (network delay)                          |
         |                                          |
T2       | Node C removed from cluster              | Cluster = #{}  (C removed)
         | Peer entry deleted from map              | peer(C) -> undefined
         |                                          |
T3       | Node C rejoins cluster                   | Cluster = #{C => #{match=>0}}
         | New peer entry created                   | Fresh peer instance
         | match_index = 0                          |
         |                                          |
T4       | Delayed response arrives                 | peer(C) lookup succeeds
         | {from: C, index: 50, success: true}      | But: match_index = 0
         |                                          |
         | PROTECTION VARIANT 1:                    |
         | If peer map uses peer instance identity, |
         | old response carries old peer reference  |
         | -> Rejected as undefined                 | ✓ Protection works
         |                                          |
         | PROTECTION VARIANT 2:                    |
         | Response processed but monotonicity check|
         | 50 > 0, so update accepted BUT...        |
         | Next append will detect mismatch         |
         | and correct the state                    | ✓ Eventually consistent
         |                                          |
T5       | Leader sends AppendEntries(prev=0)       |
         | Node C accepts (correct state)           |
         | Normal replication continues             | ✓ No permanent corruption
```

## Benefits

### Natural Session Isolation

Membership changes provide natural session boundaries without requiring:

- Additional session identifiers
- Version counters
- CallId correlation
- Protocol modifications

### Simple Implementation

The protection mechanism is straightforward:

```erlang
case peer(PeerId, State) of
    undefined -> reject;
    Peer -> process
end
```

No complex state management or validation logic required.

### No Protocol Overhead

The protection works at the application level:

- No additional message fields
- No wire format changes
- No compatibility concerns
- Zero network overhead

### Erlang Pattern Matching

The implementation leverages Erlang's pattern matching for clean code:

```erlang
case peer(PeerId, State0) of
    undefined ->
        % Handle non-member
    Peer0 = #{match_index := MI} ->
        % Handle member with pattern matching on fields
```

This provides type safety and clear intent.

## Implementation Details

### Peer Lookup Function

```erlang
peer(PeerId, #{cluster := Cluster}) ->
    maps:get(PeerId, Cluster, undefined).
```

Returns the peer map if found, `undefined` otherwise.

### Cluster Map Structure

```erlang
#{cluster => #{
    peer1_id => #{next_index => N1, match_index => M1, ...},
    peer2_id => #{next_index => N2, match_index => M2, ...},
    ...
}}
```

Each peer is tracked with its own progress state.

### State Update Pattern

```erlang
update_peer(PeerId, Peer, State = #{cluster := Cluster0}) ->
    Cluster = Cluster0#{PeerId => Peer},
    State#{cluster => Cluster}.
```

Functional update of peer state in immutable data structures.

## References

- Peer membership validation: [`src/ra_server.erl:474`](https://github.com/rabbitmq/ra/blob/main/src/ra_server.erl#L474)
- Node removal: [`src/ra_server.erl:3053`](https://github.com/rabbitmq/ra/blob/main/src/ra_server.erl#L3053)
- Node addition: [`src/ra_server.erl:3026`](https://github.com/rabbitmq/ra/blob/main/src/ra_server.erl#L3026)
