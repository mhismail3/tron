---
paths:
  - "**/App/**"
  - "**/*AppDelegate*"
  - "**/TronMobileApp*"
  - "**/DeepLink*"
---

# App Lifecycle

App startup, deep links, and scene phase handling.

## Startup Sequence

1. `TronMobileApp.init()` - Register fonts, EventRegistry
2. `DependencyContainer.initialize()` - Database, services
3. `isReady = true` - Show ContentView
4. Setup push notifications
5. Register device token when connected

## Key Files

| File | Purpose |
|------|---------|
| `TronMobileApp.swift` | App entry, scene setup |
| `AppDelegate.swift` | Push notification handling |
| `DependencyContainer.swift` | Service initialization |
| `DeepLinkRouter.swift` | URL/notification routing |

## Deep Link Handling

URL scheme: `tron://`

| Intent | URL Pattern |
|--------|-------------|
| Session | `tron://session/{id}` |
| Settings | `tron://settings` |
| Voice Notes | `tron://voice-notes` |

Flow:
1. `onOpenURL` or notification received
2. `DeepLinkRouter.handle()` parses intent
3. Intent stored in `pendingIntent`
4. App consumes and navigates

## Scene Phase

```swift
.onChange(of: scenePhase) { old, new in
    switch new {
    case .active: reconnect()
    case .background: disconnect()
    case .inactive: break
    }
}
```

## Rules

- EventRegistry must register before any events arrive
- Device token registration waits for RPC connection
- Deep links navigate after container is ready

---

## Update Triggers

Update this rule when:
- Changing initialization order
- Adding deep link routes
- Modifying scene phase handling

Verification:
```bash
grep -l "EventRegistry.shared.registerAll" packages/ios-app/Sources/App/
grep -l "DeepLinkRouter" packages/ios-app/Sources/App/TronMobileApp.swift
```
