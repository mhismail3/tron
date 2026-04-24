---
paths:
  - "packages/mac-app/**/Wizard/**"
  - "packages/mac-app/**/WizardState*"
  - "packages/mac-app/**/WizardView*"
  - "packages/mac-app/**/InstallPlanner*"
  - "packages/mac-app/**/InstallStep*"
  - "packages/mac-app/**/PermissionProbe*"
  - "packages/mac-app/**/TailscaleProbe*"
  - "packages/mac-app/**/ExistingInstallDetector*"
---

# Mac Wizard Steps

First-run onboarding wizard: step enum, persistence, error surfaces, install pipeline.

## High-Level Flow

```
TronMacApp @main
  └─ AppDelegate.applicationDidFinishLaunching
       ├─ SingleInstanceLock.acquire()   ← fails → terminate with log
       └─ setup.onboardedSentinelExists()
            ├─ false → RootView (mode=.wizard) → WizardView    (this rule's domain)
            └─ true  → installMenuBar  +  RootView (mode=.menuBarOnly)

RootView (SwiftUI)
  └─ switch mode in: .loading | .wizard | .menuBarOnly
       wizard         → WizardView(initialStep: wizardEntryStep)
                        + NSApp.setActivationPolicy(.regular)
       menuBarOnly    → MenuBarHostView (1×1 hidden window placeholder)
                        + NSApp.setActivationPolicy(.accessory)

WizardView
  └─ switch state.step in:
       welcome → tailscale → existingInstall → permissions → install → pairingInfo → done

DoneStep "Finish"
  └─ setup.touchOnboardedSentinel()      ← atomic tempfile+rename
  └─ post .tronWizardDidComplete          ← AppDelegate hops to menu bar
```

### Menu-bar → wizard re-entry (post-onboarding)

Once a user has completed onboarding, the menu-bar's "Show pairing info…" item reopens the wizard at `pairingInfo`. The flow keeps SwiftUI in charge of mode and activation policy — `AppDelegate` only owns the LaunchAgent / sentinel side.

```
MenuBarItemBuilder posts .tronWizardShowPairingInfo
  └─ MenuBarHostView observes the notification (SwiftUI .onReceive)
       └─ calls onShowPairingInfo() (closure passed by RootView)
            └─ RootView seeds wizardEntryStep = .pairingInfo
            └─ RootView flips mode = .wizard
                 └─ .task(id: mode) restores activation policy + window
                 └─ WizardView is constructed with initialStep: .pairingInfo
                      └─ WizardState(initialStep:) overrides persisted step AND
                         writes the override back so kill+relaunch lands here
```

This replaces the earlier `presentPairingInfoWindow(setup:)` AppDelegate path that tried to construct a fresh `WizardView` outside the SwiftUI scene graph (it couldn't render because the window wasn't in the WindowGroup).

## Step Catalog

| Step | View | Blocks advance? | Key side effect |
|------|------|-----------------|-----------------|
| `welcome` | `WelcomeStep` | NO | none — also exposes "I already have Tron running" skip-to-pairing |
| `tailscale` | `TailscaleStep` | NO ("I have Tailscale" advances regardless) | `TailscaleProbe.probe()` populates `state.tailscaleStatus` |
| `existingInstall` | `ExistingInstallStep` | NO (auto-skips if installed) | reads `ExistingInstallDetector` snapshot set on `WizardView.onAppear` |
| `permissions` | `PermissionsStep` | FDA + Notifications REQUIRED (Continue button hard-disabled until granted); Accessibility skippable | `PermissionProbe.probe(…)` on appear + re-probe on return from System Settings. Plan §A.4 envisions a skip-with-confirm-dialog path — not yet implemented |
| `install` | `InstallStep` | YES — must reach `.success` or `.alreadyInstalled` | copies `Bundle.main.url("tron-agent")` → `~/.tron/system/Tron.app/Contents/MacOS/tron`; writes plist; `launchctl bootstrap`; polls `system.ping` |
| `pairingInfo` | `PairingInfoStep` | NO (display-only); "I'm paired" disabled until both bearer token AND a real Tailscale IP are resolved | reads `auth-token.json` + `settings.json` (no placeholder fallback — surfaces a `PairingFailureReason` to differentiate "no token" vs "no Tailscale IP"); generates QR via `QRCodeGenerator`; copy actions |
| `done` | `DoneStep` | NO | flips the gate via `touchOnboardedSentinel` + `state.complete()` |

Ordering is canonical via `WizardStep.allCases`. Any reorder needs matching updates in `WizardState.advance()`, `WizardView.swift` dispatcher, and `WizardStepTests`.

## State Persistence

| Key | Type | Storage | Reset by |
|-----|------|---------|----------|
| `tron.mac.wizardStep` | String rawValue | injected UserDefaults | `WizardState.reset()` |
| `tron.mac.wizardComplete` | Bool | injected UserDefaults | `WizardState.reset()` |
| `~/.tron/system/.onboarded` | File (on-disk) | filesystem | delete the file |

The Mac side does NOT use iCloud-synced UserDefaults — `@Observable` + injected `UserDefaults.standard` only. The onboarding completion is gated on the **file** sentinel, not the UserDefaults bool, because the CLI-install path (`scripts/tron install`) doesn't touch UserDefaults.

`WizardState(defaults:initialStep:)` accepts an optional `initialStep` override. When set (the menu-bar re-entry path supplies `.pairingInfo`), the override wins over the persisted step AND is written back to the same UserDefaults key, so a subsequent kill+relaunch lands the user on the overridden step rather than wherever they were before. When `initialStep` is nil, behavior is unchanged: read the persisted rawValue, fall back to `.welcome` on absent / unparseable values.

## Install Pipeline (hardest step)

The install step is split into three pure pieces + one view:

1. **`InstallPlanner.plan(sourceBinary:paths:existingInstall:) -> Result<InstallPlan, Failure>`**
   Pure-value planner. Takes target paths + an existing-install snapshot, returns either a plan (with `requiresLoad: Bool` — false when installed + plist already present, true otherwise) or a typed failure (`sourceBinaryMissing`, `targetParentNotWritable`).
   Also renders the LaunchAgent plist XML (mirrors `scripts/tron:create_launchd_plist`), with XML entity escaping for labels that contain `<`, `>`, `&`, `"`.
   Tests in `Tests/Services/InstallPlannerTests.swift`.

2. **`BinaryInstaller.install(plan:)` + `BinaryInstaller.writePlist(plan:)`**
   Side-effect runners. Atomic via tempfile + `FileManager.replaceItemAt`. `install` also writes a minimal `Info.plist` inside the inner `Tron.app` so TCC identifies the binary by bundle ID, not raw path.
   Tests in `Tests/Wizard/InstallStepBinaryInstallerTests.swift`.

3. **`LaunchAgentManaging.load(plistPath:label:) -> LaunchAgentOutcome`**
   Protocol surface for `launchctl`. Live implementation shells out with a 10s timeout; mock records calls and returns configured outcomes.

4. **`InstallStep` view** — orchestrates (1)-(3) as a five-stage progress UI (`copyBinary` → `writePlist` → `loadAgent` → `awaitPing`). Each stage has a pending/running/succeeded/failed(String) state and a retry path. Failure surfaces an `InstallOutcome` that the Pairing step uses for gating.

### Existing-install path

`ExistingInstallDetector.detect()` returns `.installed(version:)` if both binary + plist exist, `.partial(reason:)` if only one, `.none` otherwise. `InstallPlanner` honors this:

- `.installed(version:)` + plist-on-disk → `requiresLoad = false`, pipeline is idempotent (copy + writePlist still run but `launchctl load` is skipped).
- `.installed(version:)` + plist-missing → `requiresLoad = true`, full pipeline.
- `.partial(reason:)` → always `requiresLoad = true`.
- `.none` → always `requiresLoad = true`.

The InstallStep view has its own auto-skip branch on entry: if `state.existingInstallStatus` is already `.installed`, it short-circuits to `installOutcome = .alreadyInstalled` without running the pipeline at all.

## Error Surfaces

`InstallOutcome` maps to plan-defined user-facing messages in `InstallStep.outcomeDescription`:

| Outcome | Recovery path |
|---------|---------------|
| `.sourceBinaryMissing` | "Bundled tron-agent binary is missing — please reinstall the DMG." |
| `.copyFailed(String)` | Surface system error + Retry button |
| `.plistWriteFailed(String)` | Same |
| `.launchctlFailed(String)` | Same — most common is "binary missing" (wrong plist path) or launchd refusal |
| `.awaitPingTimedOut` | "The server did not respond in time. Check Console.app or run `tron logs`." |

## Invariants

- **The wizard NEVER shells out to `scripts/tron install`.** Everything is native Swift via `EnvironmentSetup` so tests don't need a subshell.
- **`touchOnboardedSentinel()` is idempotent.** ISO8601 with fractional seconds ensures repeated touches produce distinct bodies (matches Rust's serde_json timestamp format).
- **No wizard step writes to `~/.tron/system/auth-token.json`.** That file is owned by the agent; the wizard only reads it. If the file is missing on the Pairing step, the user sees "(not generated)" and the pipeline has failed earlier.
- **Navigation is strictly forward via `state.advance()` + bounded backward via `state.goBack()`.** No direct `state.step = .foo` writes outside WizardState.
- **Power-user skip (`state.skipToPairing()`) goes directly to `.pairingInfo`.** Used by the Welcome step's "I already have Tron running" button.
- **Mode + activation policy live in `RootView`, not `AppDelegate`.** The "Show pairing info…" menu-bar action posts a notification observed by `MenuBarHostView`, which signals `RootView` via a closure to flip mode and seed `wizardEntryStep`. AppDelegate observes only LaunchAgent / sentinel events, never SwiftUI mode.

## Key Files

- `Sources/Wizard/WizardState.swift` — the `@Observable` step machine; accepts `initialStep:` override at init
- `Sources/Wizard/WizardView.swift` — dispatcher + shared chrome; `init(initialStep:)` forwards to `WizardState`
- `Sources/Wizard/Steps/*.swift` — one per `WizardStep` case
- `Sources/TronMacApp.swift` — `RootView` owns mode + `wizardEntryStep`; `MenuBarHostView` observes `.tronWizardShowPairingInfo`
- `Sources/MenuBar/MenuBarItemBuilder.swift` — emits the `.tronWizardShowPairingInfo` notification
- `Sources/Services/Onboarding/InstallPlanner.swift` — pure planner + plist renderer
- `Sources/Services/Onboarding/{ExistingInstallDetector,PermissionProbe,TailscaleProbe}.swift`
- `Sources/Services/Server/TronCLI.swift` — single source of truth for `tron` binary resolution (used by menu-bar actions + feedback)
- `Tests/Wizard/{WizardState,WizardStep,InstallStepBinaryInstaller,MockLaunchAgentManager}Tests.swift`
- `Tests/Services/{InstallPlanner,BearerTokenReader,TronCLIResolver,…}Tests.swift`

## References

- Plan §A (Tron.app): `~/.claude/plans/i-want-to-add-partitioned-storm.md`
- Architecture: `packages/mac-app/docs/architecture.md`
- Dev loop: `packages/mac-app/docs/development.md`
