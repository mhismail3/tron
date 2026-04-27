---
paths:
  - "**/App/**"
  - "**/*AppDelegate*"
  - "**/TronMobileApp*"
  - "**/DeepLink*"
  - "**/Onboarding/**"
  - "**/InitializationErrorView*"
  - "**/AppInitializer*"
---

# App Lifecycle

App startup, first-run onboarding sheet, scene phase, and deep links.

## Startup Sequence

Startup has three pieces: pre-`init()` static work, async DI container
initialization, and the first-run pairing-sheet flag.

1. `TronMobileApp.init()` (synchronous, before `body` evaluates):
   - `TronFontLoader.registerFonts()`
   - `EventRegistry.shared.registerAll()` — must run before any events arrive.
2. `WindowGroup` body — `rootContent()` switches on `initializer.state`:
   - `.loading` → `ProgressView`
   - `.failed(message)` → `InitializationErrorView` with retry
   - `.ready` → `readyContent()`
3. `readyContent()` always mounts `ContentView`; when
   `@AppStorage("onboardingComplete")` is false it presents
   `OnboardingFlowView` as a medium-detent Liquid Glass sheet with a
   hidden drag handle, swipe navigation, and floating progress dots.
   Successful pairing calls `state.complete()` to flip the flag and
   dismiss the sheet.

`AppInitializer.initialize { try await container.initialize() }` runs
on `WindowGroup.task`. The DI container build (DB, services) is the only
step that can fail with a user-actionable error; everything else is
either declarative state or registered-once globals.

**Push-notification permission flow** intentionally does NOT trigger
silently from `initializeApp()` or onboarding. Users enable it from
Settings. Startup and post-pairing only re-check status and register an
already-authorized token; they never prompt.

## Key Files

| File | Purpose |
|------|---------|
| `App/TronMobileApp.swift` | App entry, scene setup, dashboard root, onboarding sheet |
| `App/AppDelegate.swift` | APNs device-token + remote-notification routing |
| `Services/AppInitializer.swift` | Two-phase init state machine (loading/ready/failed) |
| `Services/Container/DependencyContainer.swift` | Service initialization |
| `Services/DeepLinking/DeepLinkRouter.swift` | URL/notification routing |
| `ViewModels/State/OnboardingState.swift` | `@Observable` onboarding-sheet state, AppStorage keys |
| `Views/Onboarding/OnboardingFlowView.swift` | Four-step onboarding sheet coordinator |

## First-run Gate

```swift
@AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
```

The literal key `"onboardingComplete"` is also exposed as
`OnboardingState.completionStorageKey` so test code does not drift from
the AppStorage binding. `false` means the dashboard still mounts, with
the onboarding sheet presented above it.

## Deep Link Handling

URL scheme: `tron://`

| Intent | URL Pattern |
|--------|-------------|
| Session | `tron://session/{id}` |
| Settings | `tron://settings` |
| Voice Notes | `tron://voice-notes` |
| Notification inbox | `tron://notifications/{toolCallId}` |
| Share extension | `tron://share` |
| Pairing (Mac QR) | `tron://pair?host=…&port=…&token=…[&label=…]` — handled by `TronMobileApp` before `DeepLinkRouter` |

Flow:
1. `onOpenURL` in `TronMobileApp` OR APNs payload via
   `NotificationCenter.default.publisher(for: .navigateToSession)`.
2. `DeepLinkRouter.handle(url:)` / `handle(notificationPayload:)`
   parses to a `DeepLinkIntent` and stores it in `pendingIntent`.
3. The `.onChange(of: container.deepLinkRouter.pendingIntent)` handler
   in `TronMobileApp.body` consumes the intent and dispatches.
4. Pairing URLs are intercepted by `TronMobileApp.handlePairingURL`,
   which fills the onboarding form, jumps to the connect page, and
   presents the sheet. Paste still works inside the form via
   `Binding<String>.pasteAware`.

## Scene Phase

```swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    container.setBackgroundState(newPhase != .active)
    if newPhase != .active { Task { await container.draftStore.flushPending() } }
    if newPhase == .active && oldPhase != .active {
        // 1. Pending share content?
        if PendingShareService.load() != nil { ... }
        // 2. Notification badge sync.
        // 3. Connection-state-aware reconnect:
        switch container.rpcClient.connectionState {
        case .connected: // verify, force-reconnect if dead
        case .deployRestarting: // owns its own retry budget
        case .disconnected, .failed, .connecting, .reconnecting:
            await container.manualRetry()
        case .unauthorized:
            // Parked state — auto-retrying just re-401s. User must
            // open the re-pair sheet first.
        }
    }
}
```

`InteractionPolicy` debounces by 500ms after a reconnect transitions
to `.connected` to avoid send-button-flashing during fast re-handshakes;
`SessionRefreshService` coalesces refresh requests across all callers.

## Connection State Wiring

| State | UI surface | Auto-action |
|-------|-----------|-------------|
| `.connected` | Hidden pill | none |
| `.connecting` / `.reconnecting` | Yellow pill spinner | none (in-progress) |
| `.disconnected` / `.failed` | Red pill, tap → `manualRetry()` | scene-foreground triggers manualRetry |
| `.unauthorized` | Red pill, tap → re-pair sheet | none — user must supply new bearer |
| `.deployRestarting` | Amber pill, "Restarting…" text | server-owned reconnect budget |

`ConnectionStatusPill.swift` owns the rendering; the policy lives in
`ConnectionManager` (`runOnReconnect`, `manualRetry`); `ToastCenter` /
`ToastBanner` surface non-fatal transient errors via
`ErrorHandler.handle()`. Use `handleFatal()` only for truly modal
failures (session-not-found, version-incompatible).

## Rules

- `EventRegistry` must register before any events arrive.
- Push-notification permission requests live in Settings. Startup and
  post-pairing may only register an already-authorized token.
- Device-token registration waits for RPC connection
  (`onChange(of: container.rpcClient.connectionState)`).
- `ContentView` mounts regardless of `onboardingComplete`; the sheet is
  the first-run affordance.
- `.unauthorized` is a parked state. No auto-retry on foreground.

---

## Update Triggers

Update this rule when:
- Changing initialization order
- Adding deep link routes
- Modifying scene phase handling
- Adding/changing onboarding steps
- Changing the first-run gate
- Adding `ConnectionState` cases or changing pill/toast routing

Verification:
```bash
grep -l "EventRegistry.shared.registerAll" packages/ios-app/Sources/App/
grep -l "DeepLinkRouter" packages/ios-app/Sources/App/TronMobileApp.swift
grep -l "onboardingComplete" packages/ios-app/Sources/App/TronMobileApp.swift packages/ios-app/Sources/ViewModels/State/OnboardingState.swift
```
