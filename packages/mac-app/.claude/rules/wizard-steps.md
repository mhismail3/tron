---
paths:
  - "packages/mac-app/**/Wizard/**"
  - "packages/mac-app/**/WizardState*"
  - "packages/mac-app/**/WizardView*"
  - "packages/mac-app/**/InstallPlanner*"
  - "packages/mac-app/**/InstallArtifactCleaner*"
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
       welcome → tailscale → install → permissions → pairingInfo → done

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
| `install` | `InstallStep` | YES — first click starts install; second click continues after `.success` / `.alreadyInstalled` | owns existing-install detection, install, installed-state display, and cleanup; waits for explicit Install CTA before copying `Bundle.main.url("tron-agent")` → `~/.tron/system/Tron.app/Contents/MacOS/tron`; writes bundle metadata/resources; ad-hoc signs the inner app for TCC; writes plist; `launchctl bootstrap` or `kickstart -k` if already loaded; polls string-id `system.ping` while skipping broadcast frames; success shows an install-complete status banner plus fresh-start cleanup |
| `permissions` | `PermissionsStep` | FDA + Screen Recording + Accessibility REQUIRED (Continue button hard-disabled until all three are granted) | polls `system.probePermissions` on the agent; Screen Recording settings click first calls `system.requestPermission` so the agent creates its own TCC row; a wizard-opened Settings pane starts a short-lived grant watcher that kickstarts/reprobes until that permission turns green; app focus normally rechecks only |
| `pairingInfo` | `PairingInfoStep` | NO (display-only); "I'm paired" disabled until both bearer token AND a real Tailscale IP are resolved | reads `auth-token.json` + `settings.json` (no placeholder fallback — surfaces a `PairingFailureReason` to differentiate "no token" vs "no Tailscale IP"); generates QR via `QRCodeGenerator`; copy actions |
| `done` | `DoneStep` | NO | flips the gate via `touchOnboardedSentinel` + `state.complete()` |

Ordering is canonical via `WizardStep.allCases`. Any reorder needs matching updates in `WizardState.advance()`, `WizardView.swift` dispatcher, and `WizardStepTests`.

### Visual shell

`WizardShell` owns the shared chrome: one pinned header row (icon + title + progress), bottom action bar, and animated step body. The header/progress/bottom layers are pinned so body changes cannot move controls; the header row is a single center-aligned `HStack` so the step icon, title, and progress pill share one vertical center on every page. The shell reports one fixed `480 × WizardLayout.height` content size, where `WizardLayout.height` is the tallest step's preferred height. Do not reintroduce per-step window resizing: horizontal page bodies should slide inside one stable viewport rather than through a clipping rectangle that is changing size. The progress shell uses one flat outer capsule; the `X / total` count is bare text with no nested pill, while the bar itself carries the tactile treatment. The progress fill is drawn by one animatable Canvas-backed `WizardProgressTrack`, so growth/shrink animation happens inside a single rendered track instead of moving as a separate SwiftUI subview during page transitions. Wizard typography uses the bundled Exo 2 font and registers it at app startup via `TronFontLoader`; all non-code step copy should go through `TronTypography` tokens rather than ad-hoc `.font(.body)` / `.font(.headline)` calls.

Welcome has one optical layout: centered intro copy only. Existing-install detection is intentionally not surfaced on Welcome; the Install step owns that status so the first page cannot jump when detection completes.

Tailscale uses a top-biased body band with generous spacing and a taller status card; it should not collapse into a tiny centered cluster on sparse states. Icon-led cards use `WizardInfoCard` + `WizardIconTextRow`: the card's horizontal inset must equal the icon-to-text spacing, the leading icon must sit in a fixed-width column so wide symbols do not visually hug the card's left edge, and subtext must wrap instead of truncating. Card containers use `WizardGlassCardBackground` / `.wizardGlassCard()` so light and dark mode both show a subtle transparent emerald fill, glassy border, and shadow without a visible gradient. Already-installed Install states also use an upper content band rather than perfect vertical centering, with a roomier install status banner and separate "Need a fresh start?" cleanup card below it; the cleanup action uses the same `wizardTertiary` square icon button language as the Permissions settings buttons and the shared card inset so the retry copy does not hug the card edge. Completed install rows are denser than active rows, and the post-install status/cleanup stack must use `installedSummaryTransition` so success feels like a completed sequence instead of a sudden card pop.

Permissions rows do not show separate "Required" badges; the page intro is the short user-facing sentence "Tron needs these permissions to use your computer for you." The primary row subtexts start with "Lets Tron" and stay compact: FDA says "Lets Tron read and edit files.", Screen Recording says "Lets Tron see your screen.", and Accessibility says "Lets Tron click and type for you." Each row has a smaller instruction line: FDA and Accessibility say "Click gear and enable Tron."; Screen Recording says "Click gear, then drag this icon into the first app list." Permission cards use moderate row geometry (`PermissionsStepLayout.cardHorizontalPadding`, `statusIconColumnWidth`, and `iconTextSpacing`) so the page has breathing room without losing a single-line helper. The inline Re-check action is left-padded to align its icon with the permission status column and says "Checking permissions..." while it runs the stronger kickstart+probe fallback. Screen Recording is the one row that must ask the agent before opening Settings: macOS only adds a Screen Recording row after the target process calls `CGRequestScreenCaptureAccess()`, and asking from the wrapper would add the wrong app. Because System Settings can still fail to auto-insert the app row, the Screen Recording card also exposes a clickable/draggable `~/.tron/system/Tron.app` shortcut next to the settings gear; clicking reveals it in Finder and dragging starts a plain AppKit `NSView` file drag with both `public.file-url` and `NSFilenamesPboardType` payloads so the Settings manual-add list sees the same kind of app-bundle drag Finder provides. The shortcut is just the app icon with a lift shadow, but its invisible hit target is larger than the icon and overrides `mouseDownCanMoveWindow` so dragging it cannot move the installer window. Disabled primary buttons use the non-emerald disabled visual branch in `WizardPrimaryButtonStyle`, not just the active button at reduced opacity.

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
   Side-effect runners. Atomic via tempfile + `FileManager.replaceItemAt`. `install` also writes a minimal `Info.plist` inside the inner `Tron.app`, copies `AppIcon.icns` when the wrapper bundle provides it, strips quarantine, and runs `/usr/bin/codesign --force --sign - --timestamp=none` so TCC identifies the binary by `com.tron.server`, not Cargo's raw executable signature.
   Tests in `Tests/Wizard/InstallStepBinaryInstallerTests.swift`.

3. **`LaunchAgentManaging.load(plistPath:label:) -> LaunchAgentOutcome` + `InstallLaunchAgentRunner.ensureLoaded(...)`**
   Protocol surface for `launchctl`. Live implementation shells out; mock records calls and returns configured outcomes. During install, `.alreadyLoaded` is treated as a stale-job signal and followed by `restart(label:)` / `launchctl kickstart -k` so launchd uses the plist and binary just written.

4. **`InstallStep` view** — uses short user-facing copy and does not mutate disk or launchd until `WizardState.requestInstall()` increments `installRequestID`. It is the single install gate: `.none` and `.partial` detection results wait for the Install CTA, while `.installed` is rendered as a completed install state with cleanup available. Before the first click, the stage area shows only "Installation not started"; it must not list all pending work. `WizardState.handledInstallRequestID` records the latest consumed request so remounting the page after navigating back from Permissions cannot replay the pipeline; only a new Install/Retry click creates new work. During the active run, the summary can appear when every local stage row is succeeded; on remount, completed rows are derived synchronously from terminal `installOutcome` so check icons slide with the rest of the page instead of popping in from a later `.task`, and their compact spacing keeps the completed summary away from the pinned buttons. After success or an already-installed detection, the install-summary stack animates in, confirms "Tron is installed", and refreshes the current server status through `setup.pingServer`; the adjacent fresh-start cleanup card unloads/removes app + LaunchAgent artifacts while preserving user data. After explicit user action, it progressively reveals only stages that have started (`copyBinary` / prepare server → `writePlist` / add startup item → `loadAgent` / start server → `awaitPing` / confirm running). Fast stages intentionally hold the running state briefly so users can perceive the sequence instead of watching three checks appear at once. The ping client uses a string request ID (matching the Rust RPC wire type), ignores `connection.established` / broadcast frames, and waits for the matching response. Each stage has a pending/running/succeeded/failed(String) state and a retry path. Failure surfaces an `InstallOutcome` that the Pairing step uses for gating.

5. **`InstallArtifactCleaner.clean(...)`** — installer recovery only. It unloads `com.tron.server` when launchd has it loaded, removes `~/.tron/system/Tron.app` and `~/Library/LaunchAgents/com.tron.server.plist`, removes an empty `~/.tron/system/deployment/` directory, and preserves auth, settings, database, sessions, workspace files, and non-empty dev/deploy/update artifacts. Exposed from failed and completed Install UI. Successful cleanup silently returns the Install step to "Installation not started"; only cleanup failures render inline text.

### Existing-install path

`ExistingInstallDetector.detect()` returns `.installed(version:)` when the installed server binary exists and the app bundle signature is bound to `com.tron.server`, `.partial(reason:)` when the LaunchAgent plist exists without the binary or the bundle signature needs repair, and `.none` otherwise. Auth/settings/database files are user data, not install artifacts, and are deliberately ignored by this detector so cleanup can preserve them. `InstallStep` and `InstallPlanner` honor this:

- `.installed(version:)` → `InstallStep` marks `.alreadyInstalled`, renders completed stages, shows current server status, and exposes cleanup; the primary CTA continues to `.permissions`.
- `.partial(reason:)` → always `requiresLoad = true`.
- `.none` → always `requiresLoad = true`.

If lower-level callers use `InstallPlanner` directly, `.installed(version:)` + plist-on-disk yields `requiresLoad = false`; `.installed(version:)` + plist-missing yields `requiresLoad = true`.

## Error Surfaces

`InstallOutcome` maps to plan-defined user-facing messages in `InstallStep.outcomeDescription`:

| Outcome | Recovery path |
|---------|---------------|
| `.sourceBinaryMissing` | "Bundled tron-agent binary is missing — please reinstall the DMG." |
| `.copyFailed(String)` | Surface system error + Retry button |
| `.plistWriteFailed(String)` | Same |
| `.launchctlFailed(String)` | Same — most common is "binary missing" (wrong plist path) or launchd refusal |
| `.awaitPingTimedOut` | "The server did not respond in time. Check Console.app or run `tron logs`." |

Failed install outcomes also surface the cleanup action so the user can unload/remove launch artifacts before retrying without deleting auth, settings, or database files.

## Invariants

- **The wizard NEVER shells out to `scripts/tron install`.** Everything is native Swift via `EnvironmentSetup` so tests don't need a subshell.
- **Welcome keeps one centered hero position.** Existing-install detection must not add Welcome UI; the Install step owns the installed-state card.
- **The install pipeline is user-confirmed.** `InstallStep` may mark a fully existing install as `.alreadyInstalled` on entry, but it never copies binaries, writes plists, or invokes launchd from view appearance alone.
- **Agent changes must be rebundled before Mac dogfood.** The wrapper installs `Sources/Resources/tron-agent`; Xcode does not rebuild the Rust server. After touching Rust RPCs, permission probes, TCC behavior, or install/startup code that the wizard exercises, run `packages/mac-app/scripts/bundle-agent.sh` so the staged binary matches source.
- **Handled install requests never replay on remount.** SwiftUI may recreate `InstallStep` when users go Back from Permissions and forward again, but an `installRequestID` at or below `handledInstallRequestID` is display-only.
- **Deployment artifacts are not installer artifacts.** The wizard writes `~/.tron/system/Tron.app` and the LaunchAgent plist only. `~/.tron/system/deployment/` is for `tron dev`, deploy, and update state and may be absent or empty after onboarding.
- **Cleanup preserves user data.** `InstallArtifactCleaner` removes only LaunchAgent/app artifacts plus an empty `deployment/` directory; auth tokens, provider auth, settings, databases, sessions, workspace files, and non-empty dev/deploy/update artifacts are out of scope.
- **LaunchAgent `.alreadyLoaded` is restarted during install.** A stale loaded label can still point at an older process image after the app bundle was moved or deleted; install must kickstart it after rewriting the plist.
- **Accessibility TCC requires a stable signed bundle identity.** The installed inner `Tron.app` must pass `codesign -dv --verbose=4` with `Identifier=com.tron.server`, a bound Info.plist, and sealed resources before the user grants Accessibility. If detection sees the old linker-generated identity, it reports `.partial` so the install step repairs it.
- **Permissions app-activation does not imply restart.** `NSApplication.didBecomeActiveNotification` fires for ordinary focus changes and System Settings navigation. `PermissionsStep` must consume a wizard-opened `PermissionSettingsReturn` before kickstarting launchd on activation; otherwise it only rechecks permissions. Immediate grant detection is handled by the short-lived settings grant watcher started from the gear click, not by treating every focus change as restart-worthy.
- **Screen Recording rows require an agent-side prompt.** Opening the System Settings URL is not enough to add Tron to the list. The wrapper calls `system.requestPermission` for Screen Recording only after a user clicks that gear button, and never during install/startup/polling.
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
- `Sources/Services/Onboarding/InstallArtifactCleaner.swift` — cleanup/removal of installer launch artifacts
- `Sources/Services/Onboarding/{ExistingInstallDetector,PermissionProbe,TailscaleProbe}.swift`
- `Sources/Services/Server/TronCLI.swift` — single source of truth for `tron` binary resolution (used by menu-bar actions + feedback)
- `Tests/Wizard/{WizardState,WizardStep,InstallStepBinaryInstaller,MockLaunchAgentManager}Tests.swift`
- `Tests/Services/{InstallPlanner,BearerTokenReader,TronCLIResolver,…}Tests.swift`

## References

- Plan §A (Tron.app): `~/.claude/plans/i-want-to-add-partitioned-storm.md`
- Architecture: `packages/mac-app/docs/architecture.md`
- Dev loop: `packages/mac-app/docs/development.md`
