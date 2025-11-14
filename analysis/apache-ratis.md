# Apache Ratis Replication Session Bug Analysis

**Repository**: https://github.com/apache/ratis
**Stars**: 1,418
**Language**: Java
**Status**: ✓ PROTECTED

## Protection Summary

Apache Ratis is **protected** against the replication session isolation bug through CallId-based request correlation. Each log append operation is assigned a unique CallId, stored in a RequestMap, and validated when responses arrive.

## How Protection Works

### 1. CallId Counter Per LogAppender

File: [`ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:159`](https://github.com/apache/ratis/blob/master/ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java#L159)

```java
public class GrpcLogAppender extends LogAppender {
    private final AtomicLong callId = new AtomicLong();
    private final RequestMap pendingRequests = new RequestMap();
    // ...
}
```

Each `GrpcLogAppender` instance maintains its own `callId` counter that increments with each request.

### 2. Request Storage in RequestMap

File: [`ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:953-958`](https://github.com/apache/ratis/blob/master/ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java#L953-L958)

```java
private void sendRequest(long nextIndex) {
    final long cid = callId.incrementAndGet();

    final AppendEntriesRequest request = new AppendEntriesRequest(
        cid,  // Assign unique CallId
        getServer().getId(),
        getFollower().getPeer().getId(),
        // ... other parameters
    );

    pendingRequests.put(request);  // Store in map indexed by callId

    grpcClient.appendEntriesAsync(request);
}
```

When sending a request, a unique CallId is generated and the request is stored in the `pendingRequests` map.

### 3. Response Validation and Removal

File: [`ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:961-967`](https://github.com/apache/ratis/blob/master/ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java#L961-L967)

```java
AppendEntriesRequest remove(AppendEntriesReplyProto reply) {
    return remove(reply.getServerReply().getCallId(), reply.getIsHearbeat());
}

private void onAppendEntriesReply(AppendEntriesReplyProto reply) {
    final AppendEntriesRequest request = pendingRequests.remove(reply);

    if (request == null) {
        // CallId not found in pending requests
        LOG.warn("Received reply for unknown request: {}", reply.getServerReply().getCallId());
        return;  // Ignore stale response
    }

    // Process valid response
    if (reply.getSuccess()) {
        updateCommitIndex(request.getLastIndex());
    } else {
        handleRejection(reply);
    }
}
```

When a response arrives, it's validated by looking up the CallId in the `pendingRequests` map. If not found, the response is rejected.

### 4. Cleanup on LogAppender Destruction

When a node is removed from the cluster, the `GrpcLogAppender` instance is destroyed. The new instance created when the node rejoins has:
- A fresh `pendingRequests` map (empty)
- A new `callId` counter
- No knowledge of old requests

This ensures complete session isolation.

## Why This Prevents the Bug

1. **Unique request identifier**: Each request gets a unique CallId from an incrementing counter
2. **Request-response correlation**: Responses are matched against pending requests
3. **Session isolation**: New LogAppender instance has empty RequestMap
4. **Automatic rejection**: Stale responses with old CallIds don't exist in new RequestMap

## Protection Flow

```
Timeline | Event                                    | RequestMap State
---------|------------------------------------------|------------------
T1       | Node C in cluster                        | Map: {callId=42 -> req}
         | Send request with callId=42              | (network delay)
         |                                          |
T2       | Node C removed from cluster              | Map: {} (destroyed)
         | GrpcLogAppender destroyed                | callId counter reset
         | RequestMap cleared                       |
         |                                          |
T3       | Node C rejoins cluster                   | Map: {} (new instance)
         | New GrpcLogAppender created              | callId starts at 0
         |                                          |
T4       | Delayed response arrives                 | Map: {}
         | {callId: 42, index: 50, success: true}   | callId=42 not found
         | pendingRequests.remove(42): NULL         | Response REJECTED ✓
         |                                          |
T5       | Send new request with callId=1           | Map: {callId=1 -> req}
         | Normal replication continues             | Clean state
```

## Key Design Principles

1. **Explicit correlation**: Every request-response pair is explicitly matched
2. **Per-appender isolation**: Each LogAppender instance is independent
3. **Fail-safe rejection**: Unknown responses are logged and discarded
4. **Counter-based IDs**: Simple incrementing counter for unique IDs

## Benefits

- **Strong guarantee**: No false positives possible
- **Clear semantics**: Request-response matching is explicit
- **Debuggable**: Can track exactly which requests are pending
- **No protocol changes**: Works at application level

## Comparison with Other Approaches

| Feature | Apache Ratis | braft | sofa-jraft |
|---------|--------------|-------|------------|
| Mechanism | CallId map | CallId queue | Version counter |
| Storage | HashMap | Deque | Single int |
| Validation | Map lookup | Queue search | Equality check |
| Cleanup | Map clear | Queue clear | Counter increment |
| Overhead | O(n) space | O(n) space | O(1) space |
| Accuracy | Exact match | Exact match | Session-level |

## Additional Protection: Timeout Handling

Apache Ratis also implements request timeouts, which provides additional protection:

```java
private void checkPendingRequests() {
    final long now = System.currentTimeMillis();

    for (AppendEntriesRequest req : pendingRequests.values()) {
        if (now - req.getSendTime() > REQUEST_TIMEOUT) {
            // Remove timed-out request
            pendingRequests.remove(req.getCallId());
            handleTimeout(req);
        }
    }
}
```

This ensures that even if a response arrives very late, if the request has already timed out and been removed from the map, the response will be rejected.

## References

- CallId counter: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:159`
- Request storage: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:953-958`
- Response validation: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:961-967`
- RequestMap implementation: `ratis-grpc/src/main/java/org/apache/ratis/grpc/server/GrpcLogAppender.java:488`
