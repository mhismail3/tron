# Tron for Mac

The Mac app installs and supervises the Tron Gateway as a Login Item, shows its status in the
menu bar, runs onboarding, and replaces or updates the signed Gateway payload. Each folder
under `Sources/` and `scripts/` has its own `<name>.module.json`
(`scripts/tron docs modules packages/mac-app`).

See:

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Computer control](docs/computer-control.md)

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
