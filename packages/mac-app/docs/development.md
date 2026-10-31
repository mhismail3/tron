# Tron Mac development

The Mac runbook: build, test, reinstall and release. Architecture: [Mac README](../README.md);
payload rules: [gateway-payload](../scripts/README.md). Every Stable transition (app
replacement, Gateway update, promotion, rollback, restart) is the user's or maintainer's;
agents prepare and validate artifacts and report the exact action.

## Stage the gateway

Install the pinned generator once (`scripts/install-ci-tools.sh xcodegen`). The Xcode target
runs `ensure-gateway-bundle.sh` before compiling when the payload is missing, so the built app
needs no global Pi, Node or XcodeGen.

```bash
packages/mac-app/scripts/ensure-gateway-bundle.sh
packages/mac-app/scripts/bundle-gateway.sh --allow-unconfigured-push [--skip-install [--skip-download]]
packages/mac-app/scripts/bundle-gateway.sh --verify-only   # read-only
packages/mac-app/scripts/bundle-gateway.sh --clean
node scripts/gateway-install-inputs.mjs check packages/gateway full
```

`config/PushService.xcconfig` is the maintainer-owned public push origin shared with iOS;
`--allow-unconfigured-push` stages a dev payload without push. A Stable source update keeps
its validated base's configuration; when a newer contract invalidates the selection, repair
may use only the configured artifact, the launcher's bundled root or the checkout's prepared
bundle, in that order. Notification state lives outside payload versions.

The build also compiles the universal Node-API capture client into
`Contents/Library/Native/tron-native-capture.node` (`native-gateway-client/build.py` checks
the Node header pins that `scripts/tron-node pin` writes; see
[capture client](computer-control.md#direct-gateway-capture-client)), embeds the native host
(`PRODUCT_NAME=TronNativeHost`; the copy/sign phase is the only embedder), and copies
`TronSearchEmbeddingHelper` into `Contents/Resources`. The Gateway admits that helper only as
the exact signed artifact (`MYGKXH6TY4`, hardened runtime, real path) after a synthetic
qualification (512 dimensions, paraphrase similarity, a negative control, stable revision);
`TRON_SEARCH_EMBEDDING_HELPER` is honored only with `NODE_ENV=development`. Otherwise search
stays lexical. Qualify with synthetic JSONL frames, never private transcripts.

## Generate and build

```bash
scripts/tron mac generate
cd packages/mac-app
../../scripts/tron-xcodebuild build -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData
```

`scripts/tron-xcodebuild` runs at most four CPU-sized jobs at nice +10, with no host-wide
queue ([iOS resource ownership](../../ios-app/docs/development.md#parallel-worker-resource-ownership)).
The build fails closed when staging cannot complete. The post-build phase signs nested Login
Items and the Node runtimes with `TronNode.entitlements` (V8 needs `allow-jit`; native
modules stay minimally entitled) before resealing the app. `TRON_CI_XCODE_VERSION` is the CI
reference, not an upper bound: a later Xcode is usable when generation, Release build,
payload validation and installed verification all pass.

## Efficient focused tests

CI compiles the app and tests unsigned (`CODE_SIGNING_ALLOWED=NO`) and runs nothing; hosted
`TronMacIntegrationTests` need the team's signing certificate, so run them locally. Build once,
then select suites:

```bash
../../scripts/tron-xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:TronMacIntegrationTests/SingleInstanceLockTests \
  -resultBundlePath build/Focused.xcresult
```

Run test execution with scratch `HOME`/`TMPDIR`, but never carry them into the signed build or
substitute ad-hoc signing. The suite holds only real-boundary tests: spawned processes and
pipes (`SubprocessTests`, `CodeSignatureProbeTests`, `CuaProcessOwnerTests`,
`MenuBarTerminationTests`, `SingleInstanceLockTests`), a loopback WebSocket
(`MenuBarLogReaderTransportTests`), the built launcher and payload trees
(`GatewayLauncherArgvTests`), the native host in a demand-launched Mach service
(`NativeHostRetirementTests`), real files (`WizardProgressFilesystemTests`,
`TronLogFilesystemTests`, `GatewayNetworkCacheFilesystemTests` for numeric version-1
admission, Boolean refusal and owner-only writer round trips), and `MacQuitGatewayTests`, which runs the Quit coordinator against
the signed bundled Gateway in a disposable launchd job with the shipped `KeepAlive` and
`ExitTimeOut` (clean exit, a held model request past 20 s, caller cancellation, stall recovery
without relaunch, missing or stale receipts, retry, restart-75). Then run
`packages/mac-app/scripts/test-signed-pi-payload-smoke.sh` on the built app.

The lock probe deliberately splits each newline-framed marker across writes; its reader
waits for the complete line within the existing deadline, never treating pipe chunks as records.

Script checks (pinned Node, `scripts/tron-node exec`): `node --test --test-concurrency=2
scripts/gateway-payload-deploy.test.mjs`, `node --test scripts/gateway-install-inputs.test.mjs`
(real `npm ci` repair, #1010), the payload scripts in [gateway-payload](../scripts/README.md#verify),
`python3 scripts/test-verify-mac-install.py` (fixture app and real TLS listeners, report in
`test-results/mac-verify/report.json`) and `python3 scripts/test-tron-mac-replace.py`.
Pi SDK rollback: `cd packages/gateway && npm run test:pi-sdk-rollback`.

## Permission identity and stale listings

Keep `Tron.app` (`com.tron.mac`) at `/Applications/Tron.app` with its one native host. FDA
belongs to the wrapper; Screen Recording may show as Tron and Accessibility as Tron Native Host;
computer use needs both and never Input Monitoring. A first capture may raise a separate
direct-capture dialog that the grant booleans do not reveal: the user handles it, and
automation inspects the whole desktop first. If Settings shows Tron enabled but its row stays
ungranted, use **Permissions… → Restart Helper**; never restart the Gateway, reset grants or
kill a draining helper. Retired identities may be removed with System Settings' minus control:
`com.tron.agent`, `com.tron.mac.dev`, `com.tron.qualification.computer-use`,
`com.tron.qualification.native-observer`, `com.tron.qualification.native-capture`. Never reset
TCC globally or edit its databases.

## Scripted checkpoint

`scripts/tron checkpoint` fetches current main, reuses the signed Mac full-build path
(including its bundled Gateway), and prints PASS/FAIL for each of five stage-current
smoke groups. Existing real-Gateway simulator journeys own pairing, fixture state,
leases and the three host slots; supplementary real Registry/socket/process tests
cover Home memory/Profile, settings approvals, display persistence, SSH and protocol.
Each group names its executed probes in `test-results/checkpoint/<sha>/report.json`;
logs and xcresults survive failures, and later groups still run after a failed probe.
This is a smoke selection, not exhaustive product or deployed-device qualification:
future Profile/Knowledge/approval stages update their probes as those features ship.
It does not measure the five program metrics or claim real APNs/device validation.
The SSH oracle starts a temporary high-port tailnet listener with fixture keys/state;
it never changes Remote Login, user SSH keys or the live Gateway.

Agents use `scripts/tron checkpoint --test-mode`: committed HEAD instead of fetched
main, a disposable signed-build checkout and isolated Gateway/state, no reinstall
preparation, install, live restart or live-state mutation. Default mode is also validation
only. The maintainer may run `scripts/tron checkpoint --prepare-reinstall` to invoke existing
`mac reinstall --app` preparation only after every smoke group passes; this writes the
existing live maintenance receipt/active pointer and can block other replacements until
finished or abandoned. It is mutually exclusive with test mode. That existing
command does **not** install or restart anything: Finder replacement, launch and live
verification remain the maintainer's manual actions below; rebuild the iPhone if its
slice changed. A green simulator checkpoint alone is not a deployed-cohort claim.

## Reinstall a local Release build

A manual developer installation, not a deployment. It is also the bootstrap for a lockstep
protocol bump or a launcher/plist change (the new launcher refuses an older selection and runs
its bundled Gateway; a registered plist changes only by reinstall and Pause/Resume). Never
remove `~/.tron` or `~/.tron/agent`: they hold Gateway state, credentials, sessions and the
internal workspace ([contract](../../gateway/docs/internal-workspace.md)).

Build with a worktree-local derived-data path:

```bash
scripts/tron mac generate
cd packages/mac-app
../../scripts/tron-xcodebuild -project TronMac.xcodeproj -scheme TronMac \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Release build
```

Then the maintainer chooses **Quit Tron** in the old app (it drains, stops and verifies the
exact Gateway and retires the native helper; if anything is unproven it stays open), replaces
`/Applications/Tron.app` in Finder only after Quit succeeds, launches the new copy and waits for
Running. Do not install a new iOS app before `scripts/tron mac verify` passes: it requires
Stable's launchd PID to be the sole 9847 listener running the validated payload with matching
authenticated `system.info`, the current runtime contract (including the pinned XcodeGen tree,
signed or the pinned upstream digest), an incompatible older selection only if the launcher
rejected it, a coherent Debug if present, and no loaded or on-disk legacy Debug, Preview or
dev-takeover job. It probes each exact owner's listeners in order (LAN TLS may refuse) and
executes only the host-native runtime. Then check a historical chat, a fresh worker, browser,
Ask User, pairing, settings, trust, models and packages; a pass proves supervision, not data
continuity.

### Resumable local reinstall preparation

```bash
scripts/tron mac reinstall --app packages/mac-app/build/DerivedData-Release/Build/Products/Release/Tron.app
scripts/tron mac reinstall --select-bundled-offline  # optional: retire external Stable payloads
scripts/tron mac reinstall --confirm-offline         # after Quit succeeded and writers stopped
scripts/tron mac reinstall --verify                  # after Finder replacement, launch, Resume
scripts/tron mac reinstall --finish
```

Maintainer-only on live state (agents test on fixtures). It never replaces apps, changes
LaunchAgents, starts or stops Gateways or approves permissions. The first call validates both
apps and teams and records the candidate's code and resource seals
(`scripts/verify-mac-install.sh --artifact-only` plus the signed Pi smoke test). Offline means
`com.tron.server` and `com.tron.mac.native-host` registered with `state = not running` and no
PID, and no loaded Debug, Preview or takeover job (`service-loaded`). Private
`~/.tron-maintenance/<operation-id>/` receipts hold revision, phase, identities, backups (agent
home, every other `~/.tron` entry, the old app, machine-group file, browser config; never
Keychain or browser profiles) and SHA-256 manifests with modes, ACLs, xattrs and link text; only
`com.apple.provenance`/`quarantine` copy values may differ. `--select-bundled-offline` renames
the whole `gateway/payloads/stable` into `retired-stable-payloads` and must finish before
`--confirm-offline`; `--verify` then requires the bundled runtime (`scripts/tron mac verify
--require-bundled`). One lock serializes the commands; reruns resume; `--restart` begins a
fresh inventory (refused mid-step or after verify); `--abandon` archives a superseded operation;
`--status` shows the checkpoint. Nothing is retried, reset or rolled back automatically;
`--finish` removes only the active pointer. Rollback restores the protected backup only when no
accepted new work would be lost.

`~/.tron-maintenance` is the single local recovery root. Register a separately verified
pre-cutover set with `scripts/tron mac reinstall --recovery-relocate --operation-id <id>
--source <root>` and check it with `--recovery-verify --operation-id <id>`; the rename is
exclusive and resumable. Retention is manual: keep one coherent set until its successor passed
restore and continuity checks. These are local checkpoints, not off-device backups.

## One-tap Mac app replacement

`scripts/tron mac replace` (iPhone Settings → Connections → Quick Rebuild → **Replace Mac
App**, or the Mac, #984) replaces the app and its bundled Gateway in one tracked operation.

```bash
scripts/tron mac replace --plan              # quick, full or none, and why
scripts/tron mac replace --start             # start, retry or resume
scripts/tron mac replace --status --follow
```

- **Path and revision.** Fetched `origin/main`. Quick (the Gateway's source update) when the
  payload lock, dependency manifest and protocol match and `packages/mac-app` is unchanged;
  otherwise a full signed Release build and swap. A remaining Knowledge namespace always
  requires the full offline path.
- **Runner.** Its own launchd job (`com.tron.mac.replace.<id>`) on a private script copy:
  preflight → build → verify signature → stop workers → stop Gateway → swap → start → verify →
  finish. RPC goes to the listener the `com.tron.server` PID holds on 9847 with the
  `local-auth.json` bearer; failures name `client-output`, the Gateway code,
  `connection-lost`, `timeout` or each unreachable endpoint.
- **Preflight** checks source, HEAD, disk, signing, registrations, protocol with the requesting
  iPhone (`--allow-protocol-change`) and that no `mac reinstall` is active; it refuses wrappers
  without `TronReplacementQuitVersion`, which need one manual reinstall first. Quick also
  verifies the checkout's installed dependency tree against its lock before stopping workers;
  missing or partial installs fail here with the pinned `npm ci --include=dev` repair command.
  An unchanged payload lock alone does not prove the checkout is ready to compile.
- **Workers** stop through Home's task stop path and can be resumed in place; **Stop** is the
  app's coordinated Quit through the replacement handoff.
- **Swap** clones `~/.tron` (`state-snapshot`), moves the Stable payload channel and old app into
  the operation directory and installs the verified build. A failure after the swap restores and
  verifies the previous app and payloads; the snapshot is never restored over newer data.
  For a maintainer-approved Knowledge retirement, the swap first runs the pinned
  `retire-knowledge.py` and its read-only `--verify` while still offline, after the raw snapshot
  and before retiring either prior artifact. A private owner-only
  `~/.tron-maintenance/knowledge-cutover-pending.json` explicitly approves version `1`,
  `priorAppRevision`, `priorGatewayRevision`, `converterSHA256`, `artifactDirectory` and
  `artifactManifestSHA256` (the prior identities, not the candidate). Preflight checks every
  `ARTIFACTS-SHA256.json` entry, recounts live records and reserves build + full logical snapshot
  + archive/export capacity before stopping anything. Missing approval, changed identities, active Debug/Preview jobs,
  privacy refusals or verification failures prevent candidate start. Absence of Knowledge is
  a no-op. The bounded journal links hash-fenced counts/inventories and the independently
  verified archive/export under `knowledge-cutover-<attempt>`; exports are ordinary workspace
  files named `knowledge-export-<operation>-<attempt>`. On failure or interrupted execution,
  the same rollback first restores only the Knowledge/Profile namespaces and initialization
  markers from the verified raw snapshot, preserving displaced bytes, then verifies the prior
  app and external payload inventories before relaunching. The decisive gate loads Profile,
  every canonical chat, Home chapters/memory/summaries and an ordinary exported source with
  the candidate's own shipped read owners, offline and without initializing a runtime. It
  checks the note count and unchanged Home/chat bytes. A durable start intent is the commit
  boundary: thereafter retries only start/verify the candidate, never reconvert or restore data.
  The prior runtime is not qualified on converted data, so post-start failures retain the new
  build and archive, clearly report unconfirmed health and allow Replace to retry verification.
  Successful post-start Profile/Home/chat-catalog reads consume the approval. Archives,
  exports, every attempt's raw snapshot and prior artifacts remain local recovery checkpoints.
  One kernel `rebuild.lock` excludes concurrent Mac replacements and physical iOS installs;
  converter/verifier children inherit it, so a killed runner cannot release a still-active cutover.
- **Verify** requires the running revision and protocol, the app's cdhash and `scripts/tron mac
  verify --require-bundled`. Builds live in `~/.tron-maintenance/replace/builds/<revision>`
  (current and previous kept); git and builds run with Homebrew's bin on `PATH` for git-lfs.
- E2E: `python3 scripts/test-tron-mac-replace.py` (fixture app and job, never Stable;
  `--rpc-only`, `--quit-only`, `--checkout-only` for single boundaries; artifacts under
  `test-results/mac-replace-*.json`).

## Debug Gateway

```bash
scripts/tron dev start       # build, stage, offline provider activation, start on 9848
scripts/tron dev restart     # stage and drain-restart
scripts/tron dev status
scripts/tron dev stop
scripts/tron dev handoff     # maintainer only: tested Debug artifact → inactive Stable candidate
```

Debug builds the selected worktree directly, runs the installed signed launcher with the `dev`
selection and keeps `~/.tron-dev` (provider install in `~/.tron-dev/internal/pi-subagents/`,
[Gateway install contract](../../gateway/README.md#tron-owned-pi-subagents-build)). It is
loopback unless `--tailscale`; later commands inherit the recorded host and reject a conflict.
A short atomic command lock fails concurrent commands closed; an orphan child with the exact
recorded identity is stopped, a foreign listener never. Staging takes every Mach-O file under
`app/node_modules` from the installed app's validated bundle, matched by package version and
integrity, and its signed runtime when the Node version matches; otherwise handoff refuses with
"rebuild and install a signed app". Handoff compares Node and `runtime/` byte for byte with
Stable and never changes Stable's selection or restarts it.

## Release

Manual. Archive with the Developer ID identity; `packages/mac-app/scripts/package-dmg.sh`
(needs `create-dmg`) verifies deep strict signatures, the payload fingerprint, both Node
architectures and JIT entitlements, runtime execution (host-native only; the foreign runtime
is checked statically), the production tree, the Login Item and
`scripts/validate-native-host.py`, before imaging and from the mounted DMG. Notarize and staple
the app and DMG and publish deliberately. Never add an automated release or deployment.
