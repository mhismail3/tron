# Tron for Mac

The Mac app installs and supervises the Tron Gateway as a Login Item, shows its status in the
menu bar, runs onboarding, and replaces or updates the signed Gateway payload. Each folder
under `Sources/` and `scripts/` has its own `<name>.module.json`
(`scripts/tron docs modules packages/mac-app`).

It does not own sessions, agent state or the Gateway protocol. See
[development](docs/development.md) (build, test, reinstall, release),
[computer control](docs/computer-control.md), the [native host](Sources/NativeHost/README.md)
and [payload staging and selection](scripts/README.md).

## Owners

- `Sources/App/`: startup modes, lifecycle, single instance, coordinated Quit.
- `Sources/Wizard/`: location, installation, permissions, Tailscale, pairing, finish.
- `Sources/MenuBar/`: status poller, controls, pairing window, Gateway logs, feedback.
- `Sources/Server/`: `LaunchAgent/` (SMAppService), `Health/` (authenticated health,
  restart and stop clients, one response-envelope decoder), `Paths/` (identities, paths).
- `Sources/Support/Pairing/`: invitation URL and QR. `Sources/Resources/Library/`: the
  Login Item and LaunchAgent skeletons. `Sources/NativeHost/`: the permission host.

User-facing names are Tron or Tron Agent; `com.tron.server` stays the internal launchd label.
The wrapper writes redacted JSONL to `<Tron home>/logs/mac.jsonl` through `TronLog` (a serial
utility queue). Wrapper and Gateway share no memory; only owner-only Gateway files
(`gateway/local-auth.json`, enrollment) cross. The wrapper never scans, syncs or recreates the
internal workspace (`<tronHome>/workspace`); replacement and `TronUninstaller.removeLocalState`
preserve it and `gateway/workspace-state`
([contract](../gateway/docs/internal-workspace.md)); wizard state is
`<tronHome>/internal/mac/wizard-state.json`.

## Variants

`MacStartupMode.resolve` is the single startup authority: test host and CLI first, Xcode Debug
→ read-only observation, installed Release → wizard or onboarded lifecycle, misplaced Release →
a visible error. Debug never creates a LaunchAgent.

| Variant | Login Item | Label | Home | Port |
|---|---|---|---|---|
| Installed Stable | `Tron Agent.app` | `com.tron.server` | `~/.tron` | 9847 |
| Developer Debug | `scripts/tron dev` supervisor | none | `~/.tron-dev` (+ `/agent`) | 9848 |
| Xcode companion | read-only wrapper UI | none | `~/.tron` | 9847 |

Stable passes `--host tailscale` (eligible IPv4 before IPv6, then address and interface order;
an explicit host wins); the CLI is loopback unless `--tailscale`. Debug pairing appends `(Dev)`.
Both share `~/.tron/internal/machine-group-id`; everything else is per profile, and credential,
enrollment, network-cache and marker paths need an explicit `TronGatewayProfile`. Launch-management policy evaluates the runtime variant, Gateway profile and isolated-install
mode: only installed Release may manage Stable, never an isolated install. It observes an authenticated Debug Gateway (exact supervisor and child identities,
sole 9848 listener, selected manifest, `system.info`) and may show its pairing, never controls it.

## Supervision and status

- `SMAppService` registers; launchd owns the process: `RunAtLoad`,
  `KeepAlive.SuccessfulExit=false`, `ExitTimeOut=20`, a throttle and
  `TRON_GATEWAY_SUPERVISED=1`. The C launcher redirects stderr to the home's logs and execs
  `<payload>/runtime/node-<arch> --max-old-space-size=4096 <payload>/app/dist/index.js` plus the
  agent's arguments; `StableGatewayProvenance.launchArguments` and `scripts/tron mac verify`
  compare that exact command line (`GatewayLauncherArgvTests`).
- Stable ownership requires the exact parent, markers, helper metadata, sole 9847 listener PID,
  selected immutable payload (or validated bundled fallback), command and authenticated
  `system.info` version, channel, revision, fingerprint and epoch. `LaunchAgentRegistrationPlan`
  derives keep, refusal or an ordered bootout/unregister/register list once and executes it
  sequentially, stopping at the first failure; failed capture or an unobserved PID refuses repair.
- `ServerStatusPoller` pings every 30 s; full Stable admission reruns only when the runtime fence
  changes (launchd PID and start identity, selection and manifest stamps). Refusals are re-proved
  every cycle; Tailscale resolution is reused about five minutes; explicit actions resolve live
  and run full admission. A refusal shows **Update required** with `why` in
  `observer.state-changed`. Runtime differing from the selection shows **Update incomplete** with
  **Rerun Gateway Update** (`gateway.update`, `mode: auto`, reconciled by `command.status`).
- Menu Restart sends authenticated `gateway.restart` (never `launchctl kickstart`, which is
  deployment recovery only). Health, restart and log clients share one WebSocket handshake,
  deadline and envelope decoder (`type=response`, Boolean `ok`, never result plus error); log
  capture has one 5 s deadline and a 1 MiB frame cap (probes 256 KiB). Stable never falls back to
  loopback; credentials use one bounded owner-only no-symlink reader; the Tailscale cache is an
  exact version-1 owner-only file of canonical addresses.
- `Subprocess`: observations get 5 s and 1 MiB per stream and fail on invalid UTF-8; accepted
  commands await completion despite UI cancellation and an unconfirmed outcome is unknown, never
  replayed. Signing inspection uses observations and requires one bundle and team identifier.
- AppKit termination goes through `ApplicationTermination` on the main run loop, outside the main
  dispatch queue (`MenuBarTerminationTests`).

## Quit

`MacQuitCoordinator` reads the exact Stable PID, command and start identity, sends one
receipt-backed `gateway.stop`, and waits for that process to go with no replacement; a reachable
preparing or waiting drain is unbounded. Only the Gateway's `gateway/stop-completed.json` receipt
starts the 5 s exit-stall grace; five seconds without it or a reachable drain is reported
uncertainty and Quit fails, work untouched. A proven stall rechecks identity and boots out only
that job, after its effective loaded `exit timeout` plus 5 s (missing, infinite or > 120 s
refuses); it never signals the Gateway. Duplicate callers share one attempt; a retry keeps the
accepted drain; each stop writes one `app.quit.gateway-exit`. Quit keeps both Login Items
approved; startup restarts the Gateway only while ServiceManagement reports `.enabled`. Replace
Mac App uses the same owner through a private `~/.tron-maintenance/replace/quit/request.json` /
`result.json` handoff bound to version, nonce and the exact wrapper PID/start; wrappers without
`TronReplacementQuitVersion=1` are refused.

## Wizard, pairing and feedback

`WizardState` owns one Install/Retry task (duplicates share it; navigation never cancels it) and
publishes progress atomically (`wizard.progress-write`); malformed or newer records stop at
Welcome. Completion counts only once `.onboarded` is written. Pairing reads
`gateway/enrollment.json` (0600, 10 minutes, one-time code) after an authenticated `system.info`
admission, re-checked before reading; refreshes carry a latest-request fence. The QR is
`tron://pair?host=<tailscale>&port=<port>&code=<one-time>&label=<mac>`; tokens never enter it.
Pairing needs a healthy Gateway, an unexpired enrollment, a Tailscale address and an 8–32
character code. Feedback export (`FeedbackIssueComposer`, `DiagnosticsRedactor`) masks credential
fields, Bearer runs, URL userinfo and local paths before the 7,000-character issue URL or
clipboard fallback.

## Signals

Streams, levels and retention: [observability](../gateway/docs/observability.md). The Mac
modules and the repository's deploy and replacement scripts (`repo/dev`, `repo/mac`) have no
README yet, so their rows live here. `TronLog` has no debug call sites; the launcher writes one
record per decision, so a healthy launch of a committed selection records nothing.

| Signal | Level | Meaning |
|---|---|---|
| `app.started` | info | Once per launch: `appVersion`, `build` |
| `app.instance-already-running` | warning | A second wrapper instance started and handed off, then exits |
| `app.version-marker` | warning | The recorded app version could not be written (`outcome=failed`); a redundant startup pass follows |
| `app.font-load` | warning | A bundled font is missing or cannot register (`Support/Theme/TronFontLoader.swift`) |
| `observer.state-changed` | info | The applied Gateway status changed (`MenuBar/MenuBarController.swift`): `old`, `new`, `why`; for Update required, `why` names the refusing Stable admission check |
| `launch-agent.register` | info; warning when macOS needs approval; error otherwise | Each registration attempt (`Server/LaunchAgent/LiveLaunchAgentManager.swift`): `outcome` (`success`, `requires-approval`, `missing`, `not-registered`, `unknown`, `failed`) |
| `launch-agent.unregister` | info on success or already unregistered; error on failure | Each unregister request: `outcome` |
| `launch-agent.kickstart` | info when the command exits 0; error otherwise | Each kickstart attempt: `outcome`, `unknown` when unconfirmed |
| `launch-agent.command-start` | warning when the Debug companion refuses the production agent; error otherwise | A command-mode start was rejected or failed: `outcome` (`refused`, `failed`) |
| `update.ui-state` | info; warning when it settles after a request failure | The update flow entered or left a UI state (`MenuBar/Actions/MenuBarActionHandler.swift`): `commandId`, `old`, `new`, `outcome` |
| `wizard.step` | info | The onboarding wizard changed its in-memory step (`Wizard/Flow/WizardState.swift`): `old`, `new`, `outcome` |
| `wizard.progress-write` | info on success; error on failure | Atomic progress publication: `new`, `outcome`, bounded `why`; inspect this, not `wizard.step`, for persistence |
| `wizard.completed` | info | The wizard completed in a mode without the production menu bar: `outcome=not-managed` |
| `wizard.completion` | error | The onboarded sentinel could not be written (`Wizard/Flow/WizardView.swift`); onboarding would repeat |
| `app.quit.gateway-exit` | info when clean or recovered; error when blocked | One final record per coordinated Gateway stop (`App/Lifecycle/MacQuitCoordinator.swift`), shared by Quit and Replace Mac App: `commandId`, `pid`, `elapsedMs`, `outcome` (`clean`, `recovered`, `blocked`) |
| `app.quit.gateway-exit-stalled` | warning | The completion receipt was observed but the exact process stayed alive 5 s; Quit boots out that job without disabling the Login Item: `commandId`, `why` (PID), `outcome=recovering` |
| `app.quit.gateway-retirement` | info | Just before receipt-gated bootout: `pid`, `outcome=waiting`; the effective launchd exit timeout and margin in the message |
| `app.quit.gateway-bootout-uncertain` | warning | `launchctl` removal returned nonzero or timed out; identity is followed to the same deadline, never replayed |
| `app.quit.replacement-receipt` | error | The private replacement Quit result could not be published (`App/Lifecycle/TronMacApp.swift`); termination still follows the real stop result |
| `app.quit.gateway-observation-lost` | error | Five seconds without completion evidence or a reachable drain, then the bounded probe: `commandId`, `why`, `outcome=blocked`; work is untouched |
| `launcher.candidate-launched` | info | `deploy.jsonl`: a pending candidate consumed its single launch attempt (`packages/mac-app/scripts/tron-gateway-launcher.c`): `payloadVersion`, `runtimeEpoch` |
| `launcher.candidate-rolled-back` | error | The candidate did not commit and the previous selection was restored: the candidate's version and epoch; the deploy helper's cause lookup |
| `launcher.bundled-fallback` | warning | An admitted store's selection was refused and the bundled payload runs: both versions named |
| `launcher.selection-rejected` | warning | A pending attempt marker could not be reconciled, so nothing launched (exit 75): claimed version and epoch, reason |
| `staged npm runtime content is not from the pinned Node archive` | `bundle-gateway.sh` stderr | The copied npm runtime differs from the pinned archive; refusal exits 2, keeps the published tree and removes its staging, backup and lock (`test-bundle-gateway-rebuild.sh`) |
| `payload verifier fixtures: generated-input precondition failed; adversarial matrix not run` | test stderr | Unsigned generated inputs failed the baseline; exit 2 is a precondition failure, never a pass; strict rejection stays exit 78 (`test-gateway-payload-precondition.py`) |
| `deploy.<state>` — states `starting`, `building`, `staging`, `promoting`, `draining`, `ready`, `rollback`, `rolled-back`, `failure` | info; error for `failure`, `rollback`, `rolled-back` | `deploy.jsonl` (`scripts/gateway-payload-deploy.mjs`): one record per state with the ending phase's duration: `commandId`, `durationMs`, `error` |
| `deploy.source-builder` | info | Source apply selected the trusted checkout's builder: `commandId`, `durationMs`, `builderSha256` |
| Replace Preflight: `Quick rebuild dependencies do not match package-lock` | error | The checkout install is missing or partial; run the pinned install command in the error, then retry. The operation's `logs/preflight.log` names the first verifier mismatch; workers have not been stopped. |
| `deploy.source-install-repair` | warning | The checkout's `node_modules` did not match its lock, so the builder runs `npm ci` with the pinned runtime: `commandId`, `drift` (first mismatch) |
| `deploy.source-install-repaired` | info | That `npm ci` finished with manifest and lock unchanged and the install verified: `durationMs` (repair time) |
| `deploy.old-process-exited` | info | The drained process disappeared: `commandId`, `durationMs` |
| `deploy.old-process-stalled` | warning | The old Gateway released its listener `DRAIN_EXIT_STALL_LIMIT_MS` (30 s) ago and its exact identity still exists; the deploy SIGKILLs it: `pid`, `releasedForMs` |
| `deploy.finished` | info on success; error otherwise | Every terminal path, exactly once: `commandId`, `durationMs`, `outcome`, `error` |
| `Debug native payload package identity differs: <package-lock key> (version\|integrity); rebuild and install a signed app before staging` | staging stderr | `stagePayload` refuses before publication: a Mach-O file's owning-package identity differs or is missing; rebuild and install the signed app |
| `Debug native payload installed Mach-O file is missing or substituted: <payload-relative path>; rebuild and install a signed app before staging` | staging stderr | The installed snapshot cannot supply the candidate's native file |
| `Debug native payload package lock is malformed; rebuild and install a signed app before staging` | staging stderr | Native identity cannot be admitted from a valid v3 lock; staging fails closed |
| `Debug native payload native alias leaves npm tree: <payload-relative path>; rebuild and install a signed app before staging` | staging stderr | A native alias targets worktree bytes outside the npm inventory |
| Failed replacement step's `error.message` (`client-output`, Gateway error code, `connection-lost`, `timeout`, or `unreachable`) | failed step in `~/.tron-maintenance/replace/<operation>/journal.json`, iPhone and `journal.log` | An RPC could not return to the orchestrator (`scripts/tron_mac_replace_platform.py`): method, exit code and stdout byte count for invalid child output, close code, Gateway code. Exit 0 with exactly 65,536 invalid bytes is an unflushed pipe (`test-tron-mac-replace.py --rpc-only`) |
