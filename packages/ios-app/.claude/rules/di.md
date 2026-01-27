---
paths:
  - "**/Core/DI/**"
---

# Dependency Injection

`DependencyContainer` is the central DI container. Injected via SwiftUI environment.

## Access Pattern

```swift
// In views
@Environment(\.dependencies) var dependencies

// Access services
dependencies.rpcClient
dependencies.eventStoreManager
dependencies.eventDatabase
```

## Service Lifecycle

- **Persistent**: `eventDatabase`, `pushNotificationService`, `deepLinkRouter`
- **Recreated on server change**: `rpcClient`, `skillStore`, `eventStoreManager`

## Initialization

```swift
// App startup
let container = DependencyContainer()
try await container.initialize()  // async init for database
```

## Rules

- Never create services directly, always get from container
- `@Observable` for reactive UI updates to connection state
- Server settings changes trigger service recreation
- Call `initialize()` before using database-dependent services

---

## Update Triggers

Update this rule when:
- Adding services to DependencyContainer
- Changing service lifecycle (persistent vs recreated)
- Modifying initialization order

Verification:
```bash
grep -l "DependencyContainer" packages/ios-app/Sources/Core/DI/*.swift
```
