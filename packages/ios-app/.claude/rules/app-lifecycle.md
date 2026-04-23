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

App startup, first-run gating, scene phase, and deep links.

## Startup Sequence

The path is gated at three points: pre-`init()` static work, async DI
container initialization, and the first-run / onboarding-complete flag.

1. `TronMobileApp.init()` (synchronous, before `body` evaluates):
   - `TronFontLoader.registerFonts()`
   - `EventRegistry.shared.registerAll()` — must run before any events arrive.
   - `OnboardingMigrationDecider.runMigrationIfNeeded()` — flips
     `@AppStorage("onboardingComplete")=true` for existing TestFlight
     users that already have cached `connectionPresets[]`. Pure idempotent
     check — never undoes an explicit reset.
2. `WindowGroup` body — `rootContent()` switches on `initializer.state`:
   - `.loading` → `ProgressView`
   - `.failed(message)` → `InitializationErrorView` with retry
   - `.ready` → `readyContent()`
3. `readyContent()` — first-run gate on `@AppStorage("onboardingComplete")`:
   - `false` → `OnboardingFlowView` (the wizard owns its own state and
     calls `state.complete()` to flip the flag).
   - `true` → `ContentView` (chat) plus a `.task` that does the
     existing-user push-notification reconnect check.

`AppInitializer.initialize { try await container.initialize() }` runs
on `WindowGroup.task`. The DI container build (DB, services) is the only
step that can fail with a user-actionable error; everything else is
either declarative state or registered-once globals.

**Push-notification permission flow** intentionally does NOT trigger
silently from `initializeApp()`. It runs from inside the onboarding
`NotificationsStep` (so the user gets context first) AND from the
existing-user `.task` on `ContentView` (which only re-checks status +
registers an existing token, never prompts).

## Key Files

| File | Purpose |
|------|---------|
| `App/TronMobileApp.swift` | App entry, scene setup, first-run gate |
| `App/AppDelegate.swift` | APNs device-token + remote-notification routing |
| `Services/AppInitializer.swift` | Two-phase init state machine (loading/ready/failed) |
| `Services/Container/DependencyContainer.swift` | Service initialization |
| `Services/DeepLinking/DeepLinkRouter.swift` | URL/notification routing |
| `Services/Onboarding/OnboardingMigrationDecider.swift` | One-shot migration for legacy installs |
| `ViewModels/State/OnboardingState.swift` | `@Observable` wizard state, AppStorage keys |
| `Views/Onboarding/OnboardingFlowView.swift` | Step coordinator |

## First-run Gate

```swift
@AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
```

The literal key `"onboardingComplete"` is also exposed as
`OnboardingState.completionStorageKey` so test code and the migration
decider don't drift from the AppStorage binding.

Migration: `OnboardingMigrationDecider` runs synchronously inside
`init()` BEFORE `@AppStorage` reads, so the flag iOS reads on first
post-upgrade launch already reflects the migration. It only flips the
flag when `cachedConnectionPresets` (the `SettingsState.cachedPresetsKey`
literal `"cachedConnectionPresets"`) has at least one entry AND the flag
isn't already true. Reset paths (e.g. diagnostics page) intentionally
clear `onboardingComplete` AND that cache, so the migration won't
silently re-skip the wizard.

## Deep Link Handling

URL scheme: `tron://`

| Intent | URL Pattern |
|--------|-------------|
| Session | `tron://session/{id}` |
| Settings | `tron://settings` |
| Voice Notes | `tron://voice-notes` |
| Notification inbox | `tron://notifications/{toolCallId}` |
| Share extension | `tron://share` |
| Pairing (onboarding QR) | `tron://pair?host=…&port=…&token=…[&label=…]` — handled by `PairingURLParser` inside the onboarding step, NOT by `DeepLinkRouter` |

Flow:
1. `onOpenURL` in `TronMobileApp` OR APNs payload via
   `NotificationCenter.default.publisher(for: .navigateToSession)`.
2. `DeepLinkRouter.handle(url:)` / `handle(notificationPayload:)`
   parses to a `DeepLinkIntent` and stores it in `pendingIntent`.
3. The `.onChange(of: container.deepLinkRouter.pendingIntent)` handler
   in `TronMobileApp.body` consumes the intent and dispatches.
4. Pairing URLs are intercepted by the universal-paste helper
   (`Binding<String>.pasteAware`) inside the onboarding form and the
   re-pair sheet — they never reach `DeepLinkRouter`.

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
- Migration decider must run synchronously inside `init()` before
  `@AppStorage` is observed.
- Push-notification permission requests live in `NotificationsStep` AND
  the post-onboarding `.task` — never silently behind `ContentView`.
- Device-token registration waits for RPC connection
  (`onChange(of: container.rpcClient.connectionState)`).
- `ContentView` only mounts when `onboardingComplete == true`. Don't
  bypass the gate.
- `.unauthorized` is a parked state. No auto-retry on foreground.

---

## Update Triggers

Update this rule when:
- Changing initialization order
- Adding deep link routes
- Modifying scene phase handling
- Adding/changing onboarding steps
- Changing the first-run gate or migration logic
- Adding `ConnectionState` cases or changing pill/toast routing

Verification:
```bash
grep -l "EventRegistry.shared.registerAll" packages/ios-app/Sources/App/
grep -l "DeepLinkRouter" packages/ios-app/Sources/App/TronMobileApp.swift
grep -l "OnboardingMigrationDecider.runMigrationIfNeeded" packages/ios-app/Sources/App/TronMobileApp.swift
grep -l "onboardingComplete" packages/ios-app/Sources/App/TronMobileApp.swift packages/ios-app/Sources/ViewModels/State/OnboardingState.swift
```
