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
            ├─ false → RootView → WizardView    (this rule's domain)
            └─ true  → installMenuBar            (menu-bar mode)

WizardView
  └─ switch state.step in:
       welcome → tailscale → existingInstall → permissions → install → pairingInfo → done

DoneStep "Finish"
  └─ setup.touchOnboardedSentinel()      ← atomic tempfile+rename
  └─ post .tronWizardDidComplete          ← AppDelegate hops to menu bar
```

## Step Catalog

| Step | View | Blocks advance? | Key side effect |
|------|------|-----------------|-----------------|
| `welcome` | `WelcomeStep` | NO | none — also exposes "I already have Tron running" skip-to-pairing |
| `tailscale` | `TailscaleStep` | NO ("I have Tailscale" advances regardless) | `TailscaleProbe.probe()` populates `state.tailscaleStatus` |
| `existingInstall` | `ExistingInstallStep` | NO (auto-skips if installed) | reads `ExistingInstallDetector` snapshot set on `WizardView.onAppear` |
| `permissions` | `PermissionsStep` | FDA + Notifications REQUIRED (skip → confirm dialog); Accessibility skippable | `PermissionProbe.probe(…)` on appear + re-probe on return from System Settings |
| `install` | `InstallStep` | YES — must reach `.success` or `.alreadyInstalled` | copies `Bundle.main.url("tron-agent")` → `~/.tron/system/Tron.app/Contents/MacOS/tron`; writes plist; `launchctl bootstrap`; polls `system.ping` |
| `pairingInfo` | `PairingInfoStep` | NO (display-only) | reads `auth-token.json` + `settings.json`; generates QR via `QRCodeGenerator`; copy actions |
| `done` | `DoneStep` | NO | flips the gate via `touchOnboardedSentinel` + `state.complete()` |

Ordering is canonical via `WizardStep.allCases`. Any reorder needs matching updates in `WizardState.advance()`, `WizardView.swift` dispatcher, and `WizardStepTests`.

## State Persistence

| Key | Type | Storage | Reset by |
|-----|------|---------|----------|
| `tron.mac.wizardStep` | String rawValue | injected UserDefaults | `WizardState.reset()` |
| `tron.mac.wizardComplete` | Bool | injected UserDefaults | `WizardState.reset()` |
| `~/.tron/system/.onboarded` | File (on-disk) | filesystem | delete the file |

The Mac side does NOT use iCloud-synced UserDefaults — `@Observable` + injected `UserDefaults.standard` only. The onboarding completion is gated on the **file** sentinel, not the UserDefaults bool, because the CLI-install path (`scripts/tron install`) doesn't touch UserDefaults.

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

## Key Files

- `Sources/Wizard/WizardState.swift` — the `@Observable` step machine
- `Sources/Wizard/WizardView.swift` — dispatcher + shared chrome
- `Sources/Wizard/Steps/*.swift` — one per `WizardStep` case
- `Sources/Services/Onboarding/InstallPlanner.swift` — pure planner + plist renderer
- `Sources/Services/Onboarding/{ExistingInstallDetector,PermissionProbe,TailscaleProbe}.swift`
- `Tests/Wizard/{WizardState,WizardStep,InstallStepBinaryInstaller,MockLaunchAgentManager}Tests.swift`
- `Tests/Services/{InstallPlanner,BearerTokenReader,…}Tests.swift`

## References

- Plan §A (Tron.app): `~/.claude/plans/i-want-to-add-partitioned-storm.md`
- Architecture: `packages/mac-app/docs/architecture.md`
- Dev loop: `packages/mac-app/docs/development.md`
