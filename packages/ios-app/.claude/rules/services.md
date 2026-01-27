---
paths:
  - "**/Services/**"
---

# Services Layer

Network, storage, and infrastructure services. Injected via `DependencyContainer`.

## Network Architecture

```
RPCClient (WebSocket transport)
    ├── SessionClient    - session lifecycle
    ├── AgentClient      - message sending, forking
    ├── ModelClient      - model listing
    ├── FilesystemClient - file operations
    ├── EventSyncClient  - event synchronization
    ├── ContextClient    - context management
    ├── MediaClient      - transcription, voice notes
    └── MiscClient       - skills, canvas, device, etc.
```

## RPC Pattern

Domain clients use `RPCTransport` protocol:

```swift
struct MyClient {
    let transport: RPCTransport

    func doThing() async throws -> Response {
        try await transport.call(method: "my.method", params: params)
    }
}
```

## Key Services

- `EventStoreManager` - Session list, event sync, dashboard polling
- `WebSocketService` - Low-level WebSocket with auto-reconnect
- `SkillStore` - Cached skill definitions

## Rules

- Domain clients are lazy properties on RPCClient
- All RPC methods go through domain clients, not raw RPCClient calls
- EventStoreManager owns session list state

---

## Update Triggers

Update this rule when:
- Adding new RPC domain clients
- Changing service architecture
- Modifying WebSocket transport

Verification:
```bash
grep -l "Client" packages/ios-app/Sources/Services/Network/*.swift | head -5
```
