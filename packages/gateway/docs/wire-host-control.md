# Supervised host control wire contract

[Gateway wire index](../README.md#transport)

Update, replacement, device install and administrative drain contracts. This is a reference, not authorization to transition Stable. Manual application procedures remain in [Mac development](../../mac-app/docs/development.md) and [iOS development](../../ios-app/docs/development.md).

Command and plain-text source paths retain their original repository/Gateway-root context; Markdown links are document-relative.

## Gateway updates and immutable payloads

Gateway updates are an explicit, bounded control-plane contract. Rebuild, update,
rollback, promotion, and restart mutations of Stable are maintainer operations:
repository agents and automation may prepare and validate source or artifacts, but
must not submit those RPCs or run `scripts/tron dev handoff`. Agents may start,
restart and stop the isolated Debug Gateway (`scripts/tron dev`, port 9848) to
validate their changes (AGENTS.md rule 8). The maintainer performs the confirmed
action that transitions Stable. `gateway.update.status`
projects only the selected channel's `deployment-state.json`, `current.json`,
`previous.json`, and version manifests (each document is capped at 64 KiB); malformed
or oversized state fails closed. `gateway.update` accepts only `channel` (`stable` or `dev`), `mode` (`source`,
`artifact`, or `auto`), candidate version/fingerprint, and a command ID. Artifact
promotion requires both exact candidate fields; version-only requests fail closed.
`gateway.rollback` is the authenticated, receipt-backed companion mutation; it accepts
only a bounded channel and command ID and launches the supervised helper's existing
rollback operation. Each runtime is bound to `TRON_GATEWAY_CHANNEL`: Stable can
inspect/mutate only Stable, and Debug only Debug; developer handoff is a local CLI
operation rather than a cross-channel RPC. Both mutations acknowledge helper admission only; status remains
authoritative and includes the active command ID and rollback availability.
`gateway.update.config` separately accepts only a trusted repository `sourceRoot` and
optional `artifactRoot`; both are checked as absolute, non-symlinked directories before
being stored in `gateway/update-config.json`. It invokes no client-supplied command or
path. The LaunchAgent-owned helper reads that projection only. In source mode it imports
`buildSourcePayload` from the configured trusted checkout's `scripts/gateway-payload-deploy.mjs`,
so changes to build logic take effect on that rebuild, not the following one. The installed
helper retains the operation lock, progress, manifest/fingerprint admission, selection,
readiness and rollback; it never delegates `apply` to source code. Missing source build
exports or incompatible candidate contracts fail closed without a fallback to stale build
logic. `deploy.source-builder` records the selected builder file's SHA-256 alongside the
command ID. `node --test scripts/gateway-payload-deploy.test.mjs` exercises a newer source
builder through the real apply CLI, immutable staging, failure progress, and rejection of a
corrupted candidate before selection. Source rebuild compiles the explicitly selected
checkout without consulting gate receipts or main-check state. Mac Replace selects
fetched origin/main through its detached full-build path when needed. The source builder invokes the
repository's local TypeScript compiler with its checked-in config and a private temporary
`outDir` (it never writes the trusted repository's `packages/gateway/dist`), then stages
only verified output. The helper copies the active payload once into a private
`.source-staging-*` directory directly under the channel root, outside `versions/`
and its retention scan. Full payload copies use `/bin/cp -c -R` to request APFS
clone-on-write; macOS `cp` falls back to a byte copy when cloning is unavailable.
Post-copy fingerprints remain the integrity check. A per-channel source-build lock keeps cleanup of crash-left
staging directories from touching a live build; validated staging is atomically
renamed into `versions/` inside the store-locked publication transaction. Every
publication seals the staged tree but keeps its root writable across that rename,
because macOS 15 refuses to rename a directory its owner cannot write; the root is
sealed in `versions/` before any candidate state names the version. The trusted
source checkout's lockfile-pinned Gateway development dependencies are the compiler's
input. Before compiling, the builder compares applicable npm hidden-lock package
records with the source lock, then walks the actual install to require every locked package for
this platform/mode at its locked name and version, with no missing or extra package directories.
Unsupported package-directory symlinks are rejected before their nested dependency trees are
traversed, so a link cannot redirect the validator outside the install.
The hidden lock is not compared byte-for-byte with the root lock: npm omits root metadata,
platform-inapplicable optional packages, and—on production installs—development packages. This
structural check does not cryptographically re-hash every installed package file. Source rebuild
records a bounded `app/build-inputs.json` receipt for the explicit compiler, copied deployment and
provider helpers, provider pin metadata, configuration, and toolchain inputs used to produce each
payload. The provider pin checker separately binds copied archive bytes to their hashes. Dirty
development builds are allowed, but the receipt must match those exact bytes; returning to a clean
checkout at the same `sourceRevision` therefore cannot reuse output built from reverted edits.
Unrelated untracked files are not build inputs. A checkout's install drifts whenever `main` moves
its lock without a reinstall, so when that check fails the builder repairs the checkout's
`packages/gateway/node_modules` itself (#1010). It runs `npm ci` there with the active payload's
pinned Node and npm, under the source-build lock and only after the lock is proved equal to the
running payload's. It then requires `package.json` and `package-lock.json` to be byte-identical
and the install to verify. npm ci replaces only `node_modules`, so tracked files and other
untracked files are untouched. The deploy log records `deploy.source-install-repair` and
`deploy.source-install-repaired`. If the repair fails (for example, offline with a cold npm cache),
the rebuild fails before compilation. Its Settings error then names the exact command to run. A
symlinked or otherwise unsafe install is refused, not repaired. This repair touches only the
checkout's compile-only install. Source-only updates
require the package lock and dependency declarations
to match the selected validated payload exactly and reuse that payload's complete fingerprinted
`node_modules` tree. They never invoke npm or depend on registry availability, package-manager
shutdown, or fresh native-module signatures; dependency changes require a newly signed app or
artifact. The delegated provider is the exception: a source update stages the source
revision's `pi-subagents-pin.json`, its check and install scripts, and exactly the
artifacts both pin selections name, verifying each against the pin's digest before
publication, as Mac packaging does. A provider update therefore needs only Rebuild
from Source, and a payload never claims a revision while carrying an older provider. The deploy helper fingerprints sorted `app/**` and `runtime/**` entries using
bounded batches of 16 file reads; the batch bound overlaps storage latency
without issuing one read operation per file at once. Sorted canonical lines
keep its SHA-256 byte-identical to the Mac payload hash script and launcher;
all three reject control bytes in covered paths.
The optional capture addon belongs to the installed Mac app beside its
Native Host, outside the Gateway payload. Source-only updates neither require nor
replace it; the capture loader checks its API version when explicitly opened.
Native-client changes use a manual Mac app update. Artifact mode only promotes a
verified candidate, and auto prefers staged artifacts
before source. A successful RPC acknowledges helper launch, not eventual
build or promotion success; asynchronous helper failures are reported in update progress. An old
helper may still stage or copy a candidate, but the new `.bin/pi` runtime contract fails closed
before a source-only transition can become healthy; the manual reinstall replaces launcher and
payload together. A
planned restart publishes a distinct `draining` phase and may wait without a startup deadline
for already-accepted runs; only after the exact captured old PID/start identity disappears or
changes does the bounded startup deadline begin. Readiness requires one different PID/start
identity stable across an authenticated exact fingerprint/revision/epoch probe. Normal candidate
startup belongs exclusively to launchd; listener absence cannot authorize a kickstart because a
live startup process may not have bound yet. Candidate startup uses the launcher's atomic
attempt/commit marker. After the candidate deadline, recovery restores and revalidates the prior
selection under that marker's lock, then conditionally kickstarts and verifies the restored payload
directly; it never depends on RPC to the failed Gateway.
Debug handoff is exposed as Debug
origin only when its bounded provenance (candidate version/fingerprint, tested Debug fingerprint,
source revision, tested runtime epoch, and candidate runtime epoch) matches the verified Stable
candidate manifest. Handoff requires byte-exact equality of the Node version and complete
`runtime/` subtree with installed Stable. Debug staging therefore uses the installed app's
validated signed runtime when its Node version matches the candidate; if versions differ, it
retains the official runtime and handoff refuses with the manual signed-app replacement
instruction. Generic automatic/source updates never infer a Debug-origin
candidate from state; promotion must pin its exact candidate version and fingerprint.
`gateway.update.config.status` and `gateway.update.status` are bounded projections; the latter
includes build/staging/draining/promotion/rollback/failure progress. Generated update diagnostics
are normalized to one line and capped at 2 KiB of UTF-8 before persistence; historical diagnostic
text is similarly normalized on projection, while update identity and document validation remain
strict. When a promoted candidate fails after its restart request, the helper reads the
newest 256 KB of `logs/gateway.jsonl` and `logs/deploy.jsonl` for a `gateway.fatal-startup` or
`launcher.candidate-rolled-back` record at or after that request whose `runtimeEpoch` or
`payloadVersion` names the candidate, and leads the reported error with it (for example "New build
crashed at startup: ERR_MODULE_NOT_FOUND: …"); a Gateway crash is preferred over a launcher record.
Each helper operation appends its timeline to `logs/deploy.jsonl`, and the C
launcher appends its own `launcher.*` records to that same file, so a rollback's
cause outlives the process that produced it. The events, levels and rotation cap
of both streams are owned by [`docs/observability.md`](observability.md);
log failures never affect a deployment. The mutation is usable only
when the helper is configured, in which case `gateway-update.v1` appears in capabilities. Candidate transition health uses a 60-second default deadline; an owned decimal-millisecond override is admitted only from 2,000 through 300,000 milliseconds.

## Mac application replacement

The Stable channel advertises `mac-replace.v1`, the Gateway side of the one-tap Mac app
replacement (#984). The orchestrator (`scripts/tron_mac_replace.py`, run as its own launchd job)
is the single writer of its journal under `<tronHome>/../.tron-maintenance/replace/<operation>/`;
the Gateway only reads it. `mac.replace.status` projects the current journal (bounded to 512 KiB)
plus each worker the replacement stopped with its state (`resumable`, `resumed`, `stopping`,
`unavailable`) derived from Home's task store. `mac.replace.plan` runs the configured source
checkout's `--plan --json` and returns which path a replacement takes (`quick`, `full`, `none`)
and why. `mac.replace.start` (receipt-backed) runs `--start` only on the supervised Stable Gateway
of this account's own `~/.tron`; any other Gateway reads status only. `mac.replace.complete` is
called by the orchestrator once an attempt settles: the Gateway reads the journal itself and
pushes one notification per attempt. `mac.replace.resumeWorker` resumes a stopped worker in place
(same session, as a `.resume-N` successor task) and refuses one already resumed.

## iOS device install and target binding

A separate supervised macOS control plane advertises `ios-device-install.v3`. After configuring the source checkout in Settings, bind the intended phone from the Mac (after the Gateway payload containing this contract is manually installed) with `scripts/tron-ios-device-bind.mjs --device-id <paired-device-id> --target-identifier <CoreDevice-identifier>`. Obtain the latter from `xcrun devicectl list devices`; obtain the former with the read-only `scripts/tron-ios-device-bind.mjs --list`, which prints paired IDs, names, and creation timestamps. Confirm the intended pairing explicitly when names are duplicated. The helper defaults to Stable's local Tailscale address and port 9847; `--channel dev` selects the separate Debug home and loopback port 9848. Local credential reads reuse the existing bounded, no-symlink credential reader. `--host` accepts only `tailscale` or `127.0.0.1`, never a remote hostname. Receipt-backed `device.install.config` binds one authorized Gateway device to a validated Tron source checkout; it never accepts a physical target from iOS. The one-time Mac-local `scripts/tron-ios-device-bind.mjs` command calls the local-only `device.install.target.bind` operation with the intended CoreDevice identifier after `devicectl` discovery; the Gateway verifies that exact target is connected and has Developer Mode enabled, then persists the owner-only binding. At install admission the Mac revalidates that exact binding and fails closed if it is unavailable or changed; it never substitutes another physical device. Because `devicectl` reports a paired phone as connected only while a CoreDevice tunnel is open, binding and install admission first request that exact device (`devicectl device info details`), which opens the tunnel for an idle wired or same-network phone; a failed request leaves the ordinary retryable refusal. CoreDevice identifiers, serials, UDIDs, and complete discovery documents remain owner-only Mac state. The per-device configuration is stored under `gateway/ios-device-installs/` with mode `0600`; source roots must be absolute, symlink-free directories containing the canonical iOS project, pinned-toolchain configuration, fixed install helper, artifact validator, and protocol validator. Config/status reads revalidate paired-device authority and never accept an executable, scheme, build configuration, bundle ID, or arbitrary command from RPC; only the authenticated local Mac binding operation accepts a validated CoreDevice identifier.

`device.install.target.bind` is accepted only on the authenticated local Mac wrapper; it is serialized with installs, preserves the source configuration, and is rejected while an install is active. `device.install` admits only the paired-device ID, command ID, and bounded build mode (`fast-debug` or `optimized`), serializes one Mac-wide install, and launches an immutable Gateway-bundled helper detached from the initiating socket. The accepted build mode is immutable in the status/active records and receipt-backed command. That helper re-reads owner-only configuration, revalidates the source, and invokes only `scripts/tron-ios-device install --device-id <owner-bound target>` (adding `--fast-debug` only for the explicit fast-debug mode). It passes the absolute fingerprinted XcodeGen executable from the active signed payload; the source checkout's cache and launchd `PATH` are not runtime dependencies. The script requires the canonical pinned version, fixes `Tron Device` + `LocalDevice`, rejects Release/DevicePerformance, validates development signing and the exact Gateway protocol contract, overwrite-installs without uninstalling, and relaunches the app. The script holds that physical device's host-wide lease for the whole build, install and launch, so an install that finds another command (an agent's `scripts/tron-ios-device` in any worktree) on the same device fails with the helper's exit 73 naming that holder instead of installing over it. Stable-channel installs remain Mac-first and verify `/Applications/Tron.app`; Debug-channel installs use the explicit source protocol target. `device.install.status` is the bounded reconnect-safe authority for requested/running/succeeded/failed state and the selected build mode. Generated multi-line tool output is normalized before persistence and legacy generated multi-line failures are admitted through the same bounded sanitizer, so a failed build cannot poison later status/config reads. Dispatch acknowledgement does not claim completion. A two-hour helper deadline and owner-only active record prevent overlapping Xcode builds; Gateway update, rollback, and restart admission are mutually exclusive with an active iOS install, and revocation removes the device's source/target mapping. No Stable Gateway transition, production archive, App Store upload, or automated production deployment is part of this path.

## Device labels

Authorized device names are projected from one Gateway-owned record: a validated custom label takes precedence, followed by the last exact Mac-observed physical-device name, then the original pairing-time name. `device-label.v1` advertises receipt-backed `device.label`, accepting a bounded label (trimmed on save, control characters rejected) or explicit `null` reset; it never changes credentials, push registration, or install identity. Successful local binding and the existing install-admission discovery update the observed name only for the exact connected bound target. Binding, install discovery/name publication, label changes, and revocation share the target pairing's identity lane, so a delayed observation cannot overwrite a newer binding or recreate a revoked record. `devices.changed` invalidates connected presentation-owned reads without adding background discovery or blocking control-event intake. Offline devices retain their last observed name; an OS rename becomes visible on the next admitted binding/install discovery. Physical identifiers remain Mac-local and are never included in the device list. Naming metadata persists with the existing device record; a Gateway predating these fields must not be assumed to support that updated document on rollback.

## Supervised process exit and completion proof

Remote restart is advertised only when `TRON_GATEWAY_SUPERVISED=1` is present from a managed LaunchAgent or repository background supervisor; direct foreground processes fail closed for remote restart. Planned restart exits with code 75 only after the registry drain completes. A handled signal in a supervised runtime also exits 75, while an ordinary foreground signal remains a clean exit; process replacement belongs to the supervisor. Node's own `process.exit` can block forever after the shutdown has completed, inside its threadpool teardown, and launchd relaunches only once the process is gone. A non-zero exit after shutdown is therefore backed by a detached watcher (`lifecycle/exit-after-shutdown.ts`) that holds a pipe to the Gateway and SIGKILLs that exact process if it still exists after `EXIT_STALL_GRACE_MS` (5 s), recording `gateway.exit-stalled`. Under `KeepAlive.SuccessfulExit=false` a signal death relaunches exactly like exit 75. A clean exit 0 is never backed this way, because a kill would relaunch a Gateway its caller asked to stop. `gateway.stopped` includes the exact PID for diagnosis, not lifecycle authority. After an intentional stop has settled every shutdown owner, the Gateway atomically replaces `gateway/stop-completed.json` with `{version:1,pid,drainId}` for the accepted drain. This single bounded receipt survives transport retirement/log rotation; old receipts cannot match a new drain UUID. Publication failure logs `gateway.stop-completion.failed` but preserves exit 0 rather than turning an intentional stop into a crash. Mac Quit observes the exact receipt alongside the captured process identity and bounds its post-completion wait to five seconds. Reachable preparing/waiting drain status remains unbounded; missing completion evidence plus lost drain observation yields bounded uncertainty, not an inferred successful shutdown. Only a proven post-completion stall permits Mac Quit to recover: it rechecks the exact launchd PID/command/start identity, boots out that job (never disables the Login Item), and verifies process disappearance before helper retirement. Removing the job prevents crash relaunch; missing completion evidence never authorizes recovery. The normal exit-0 path keeps the job registered. `exit-after-shutdown.e2e.test.ts` covers real source Gateway restart/stop exits; signed `MacQuitGatewayTests` exercises the built Mac owner and bundled Gateway under disposable launchd supervision, including held accepted model work, missing/stale receipts, receipt-write failure, automatic completed-exit recovery, explicit retry after uncertainty, and no intentional-stop relaunch.

## Administrative drain, terminals and payload transitions

Administrative restart drains accepted work and exits with the supervised restart
code. If blocker progress stops for 180 seconds, or the authenticated `gateway.restart`
request explicitly includes `restartNow: true`, shutdown uses the existing exact
cancellation, bounded grace, and runtime disposal path. Still-marked runs recover as
interrupted or `outcomeUnknown`; shutdown never claims a non-durable receipt succeeded.
Unexpected signal/error shutdown uses the same bounded cleanup grace.

App terminals (#479) are owned by `machine/terminal-service.ts`. A live PTY
is busy while a device has it open, while its shell has any child process
(a foreground program or a background job), or while its last input left a
half-typed line (input not ending in Enter, Ctrl-C or Ctrl-D). Output alone is
not use. `gateway.restart` and `gateway.stop` close every live terminal that is
not busy, with the reason "Closed for a Gateway restart", and refuse only when a
busy terminal remains, naming how many and why ("1 running a program"). An idle
pass every 30 seconds also closes a terminal that is not busy once no input or
attachment has touched it for `setup.terminalIdleMinutes` (Mac layer, default
60 minutes, Off keeps them; read at every pass, so a change applies without a
restart). A closed terminal keeps its `closedReason` in `terminal.list` and on
`terminal.exit`, and its replay ends with the bracketed reason, so a client that
shows it reads why it ended. A terminal is never closed while busy.
`terminal-idle.e2e.test.ts` drives a real supervised Gateway (report:
`test-results/terminal-idle.e2e.json`); `terminal-service.integration.test.ts`
covers the idle pass with an injected clock.
`GatewayWorkRegistry` is a
bounded, process-local registry with separate normal and derived-settlement capacity. It
never persists or expires work by age and does not duplicate Pi's runtime, JSONL, or run
markers. Prompt preflight transfers one token into accepted foreground, queue, or
extension-command ownership without a release/reacquire gap. Exact accepted queue owners
run naturally during a graceful drain; only an explicit client clear/replace settles them
without execution. A command-triggered agent turn owns a distinct foreground token even
while the command handler unwinds; agent settlement retires that token independently when
the turn fails or produces no successful assistant completion. During drain, a foreground
token is marked suspect only when no exact live runtime, queue, prompt, command, or terminal
settlement projection represents it and Pi no longer reports a live run. The owning slot
then removes its exact durable marker before retiring that process-local orphan, reasserting
the marker if exact ownership returns while cleanup yields; age alone never authorizes
cleanup. Foreground work without any captured owning slot fails the drain invariant instead
of waiting forever, allowing supervised shutdown/replacement to recover. Direct Bash and
idle compaction persist interruption markers before canonical SDK work, and reliable
bounded-frequency marker/terminal-receipt retries keep the same owner live until durability
succeeds.
Package mutation admission fences SDK install/remove/update failures as unknown
outcomes, including partial update batches. Definite preflight failures remain
retryable; source interpretation (tilde paths, file URLs and Git shorthand)
remains with the SDK rather than a second package parser. Advisory completion
publication cannot erase an uncertain mutation's receipt fence.

Package inventory/update discovery and provider login remain exact administrative owners
until their underlying asynchronous operation settles; retiring mobile UI does not infer
provider settlement. Registry tokens are the normal drain authority. Exact-owned
nonterminal extension artifacts are the sole compatibility exception until the pinned
extension host exposes direct detached-work registration. A logically resumable `paused`
artifact keeps its `paused` state and resumable history, but it stops being live work—and
stops blocking administrative drain—only after its exact-owned versioned `processTerminal`
proof reports `observed` and validates the matching runner plus every writer process tree.
Missing, pending, unknown,
mismatched, or malformed proof remains conservative. Process exit never fabricates
workflow completion, success, failure, or a terminal receipt.
The pinned SDK exposes no disposal API for the retained administration resource loader or
model runtime, so admission closure plus exact operation settlement is the truthful
resource boundary; Tron does not pretend those SDK objects were explicitly disposed.

`gateway.drain.status` returns a bounded in-memory `AdministrativeDrainSnapshot` before
and during a drain. The accepted `gateway.restart` response includes the same initial
drain identity and revision while retaining its legacy fields; `{ commandId,
restartNow: true }` can escalate an existing drain without waiting behind it. The
authenticated `gateway.stop` request uses the same receipt, terminal-admission, and
administrative-drain owners. It does not cancel accepted provider-login work: the
login remains a blocker until its own response/completion settles. After the stop receipt
settles, the process owner awaits the canonical drain and exits successfully only after
an exact zero-blocker completion proof. While that proof is pending, status remains
`preparing`/`waiting` and the app stays open; a rejected wait or failed final proof
records `failed`, keeps work admission closed, and permits an explicit new stop or
restart request. An explicit Restart Now retains restart's existing relaunch behavior;
intentional stop itself never requests a restart. Intentional stop uses exit 0, while
restart uses the relaunch code. The Stable LaunchAgent's `KeepAlive.SuccessfulExit=false`
therefore suppresses relaunch only for intentional successful stop while retaining
crash and restart recovery. Because the drain has already closed ordinary work
admission, its receipt write is admitted as derived settlement work of that drain. Its accepted receipt only acknowledges the request to stop waiting; a lost response is retried with the
same command ID and does not duplicate shutdown. Snapshots contain category counts, at most
64 blocker summaries with session identity, category, state, age, and progress timestamp
when available (plus the method for an `rpc-mutation`: a receipt-backed RPC still
executing, which can be a minutes-long compaction or branch summary rather than
receipt persistence), omitted and suspect-projection counts,
and monotonic revisions—never session/run IDs, prompts, output, paths, provider data, or
credentials. They are diagnostics only; exact tokens, runtime settlement, terminal
artifacts, and durable receipts remain liveness authority. While waiting the Gateway also
emits bounded `gateway.restart-drain.waiting` records every 15 seconds with blocker
session, category, state and age, plus stall/completion records. A drain waits for
accepted work until it settles, but stalls after the oldest blocker makes no progress
for 180 s; unrelated blockers arriving, settling, or progressing do not reset that
bound. Progress is a change in blocker state or its progress timestamp; when a blocker
has no progress timestamp, admission time is its fixed progress baseline. If every
remaining blocker is a suspect `terminal-receipt-persistence` owner (an unresolved
canonical write or failed extension receipt), the Gateway proceeds immediately and
writes one error record per session/category; a mix with live work still waits under
the same oldest-blocker bound. This can shorten how long accepted work is waited for
when one blocker is stuck, and avoids waiting 180 s when only unresolved owners remain.
Persistence retry, blocked and terminal-receipt failures are also written to
`gateway.jsonl` with session identity. Active log rotation keeps the previous file
within its one-MiB bound; fast successful RPCs are omitted.
Live PTYs block restart and stop because process retirement cannot preserve them. Both
close terminal admission atomically only after proving no PTY is live, so an already-dispatched
`terminal.open` cannot resume across the cutoff and spawn a shell.
The installed Release wrapper supervises Stable only. `scripts/tron dev` owns the
separate Debug lifecycle on 9848 through the same immutable payload store and launcher.
Its loopback-by-default handoff copies only an authenticated, selected Debug
artifact whose version and fingerprint match the clean candidate `scripts/tron dev`
admitted (re-checked under the Debug payload lock)
into Stable as an inactive candidate after proving the same exact Debug
identity before and after the copy; it never selects or restarts Stable. Compatibility
is checked against the actual installed/active Stable runtime, and Node/helper drift
requires a manual Mac app replacement. Promotion pins version and fingerprint,
atomically selects, requests a real drain-aware restart, and accepts readiness only
from a different stable PID/start plus the candidate's exact fingerprint, source revision,
and runtime epoch. Apply and rollback serialize per channel; failed pointer changes restore
the prior selection and use direct, fixed Stable supervisor recovery with exact health
verification rather than RPC to the failed process. Status keeps observed live identity separate from the
selected pointer so publication cannot report readiness early. Each immutable payload fingerprints a regular `app/PushService.xcconfig`.
Stable staging, promotion, source updates, rollback, launcher/Swift admission,
and packaging require its one exact non-empty public HTTPS origin; dev alone
may carry one explicit empty assignment. Stable source updates normally inherit the selected validated payload. If a new
payload requirement makes that predecessor inadmissible, bootstrap is limited to
three explicit, fully fingerprint-validated runtime bases: the configured artifact,
the bundled payload root exported by the signed launcher, then the prepared Gateway
bundle under the already-admitted source checkout. The copied base is revalidated
against the exact admitted manifest before any candidate file changes, closing the
mutable-projection race. No historical version scan or unvalidated runtime fallback
is allowed. Source updates preserve that base's product configuration and complete
fingerprinted dependency tree rather than consulting environment configuration or npm.
They share the bundle assembly lock while reading source dependencies and compiling,
require byte-identical active/source locks and dependency declarations, and verify the
lock root against `package.json`; dependency changes require a newly signed app or
artifact. Preflight loads every host-architecture native module before
pointer publication, and a failed first external candidate restores the validated
bundled fallback rather than requiring a `previous.json` pointer. Notification state stays
outside payload version directories. Payload staging,
promotion, and rollback use `scripts/gateway-payload-deploy.mjs`. A source build reuses its computed fingerprint for the resulting manifest, and promotion reuses its validated candidate manifest for preflight; copies, launcher admission, and post-restart identity checks still verify their own payload boundaries. Restart requests use the authenticated drain-aware Gateway protocol; direct self-stop
is rejected. The deploy then waits for the exact old PID and start identity to leave the
process table. The old Gateway keeps its listener for as long as its drain takes, so the deploy never
signals while that listener is held. Once the listener is released, the process gets
`DRAIN_EXIT_STALL_LIMIT_MS` (30 s) to exit. If it is still there, the deploy records
`deploy.old-process-stalled`, re-reads that exact identity, and SIGKILLs it, which launchd treats as the
relaunch the restart requested. This bound also covers an old Gateway that predates the exit watcher. Clients receive `system.stopping`, reconnect with bounded backoff, and replace
live state from a new authoritative snapshot. Staging preserves package-manager relative
symlinks verbatim so copied artifacts remain self-contained; cleanup never follows links,
which lets it remove a malformed failed staging tree without touching an external target.
An unexpected process death remains an interruption represented by the durable run marker
and is never automatically replayed.
