# Tron Mac architecture

`Tron.app` is the installer, supervisor, pairing surface, and menu-bar status UI
for the always-running Tron agent. The Login Item launches a minimal universal C
shim, which execs the exact bundled Node runtime and Tron Gateway payload. Each
immutable payload also carries exact architecture-specific command directories.
Their `node` aliases resolve to those same runtime binaries. The technical `pi`
alias is always the exact relative link `../../app/node_modules/.bin/pi`; that
npm-created projection must resolve to the declared executable inside the pinned
`pi-coding-agent` package. The projection and both aliases are covered by the
payload fingerprint and signed launcher validation.

User-facing terminology is Tron or Tron Agent. Historical `com.tron.server`
launchd labels remain stable internal identifiers so upgrades do not orphan old
registrations.

## Runtime variants

`MacStartupMode.resolve` is the single startup authority. It resolves test-host
and CLI command paths first, then routes Xcode Debug to read-only observation,
installed Release to wizard/onboarded lifecycle, and misplaced or unsupported
Release bundles to a visible companion/error path. RootView, AppDelegate, and
startup maintenance consume that same resolved mode; Debug never creates a
LaunchAgent.

| Variant | Login Item | Label | Home | Port |
|---|---|---|---|---|
| Installed Stable | `Tron Agent.app` | `com.tron.server` | `~/.tron` | 9847 |
| Developer Debug | `scripts/tron dev` supervisor | none (no SMAppService) | `~/.tron-dev` + `~/.tron-dev/agent` | 9848 |
| Xcode companion | read-only wrapper UI | none | `~/.tron` | 9847 |

The LaunchAgent passes `--host tailscale`; gateway startup resolves and binds the
actual Tailscale interface rather than all interfaces. The Gateway and wrapper
use the same deterministic policy: eligible IPv4 before IPv6, then address and
interface order; IPv6-only tailnets remain supported. Deployment health and
restart traffic resolve the same name; an explicit host always overrides it.
Developer CLI operation
is loopback unless `--tailscale` is explicit. Debug pairing appends `(Dev)` to
the Mac's friendly name so the `9848` profile is distinct from the stable connection. Stable and Debug share the single machine-group identity at
`~/.tron/internal/machine-group-id`; all other Gateway state remains profile-owned.
The retired `~/.tron-machine-group-id` source is never read as startup fallback:
an operator migration must preserve its exact bytes and retire it before either
profile starts.

## Source owners

- `packages/mac-app/Sources/App/` — wrapper modes, lifecycle, single-instance ownership
- `packages/mac-app/Sources/Wizard/` — location, installation, permissions, Tailscale, pairing, finish
- `packages/mac-app/Sources/MenuBar/` — status poller, controls, pairing window, gateway logs
- `packages/mac-app/Sources/Server/LaunchAgent/` — the retained internal name for SMAppService ownership
- `packages/mac-app/Sources/Server/Health/` — authenticated `system.info` gateway probe
- `packages/mac-app/Sources/Server/Paths/` — canonical wrapper identities and filesystem paths
- `packages/mac-app/Sources/Support/Pairing/` — strict invitation URL and QR generation
- `packages/mac-app/Sources/Resources/Library/` — tracked Gateway Login Item and LaunchAgent skeletons
- `packages/mac-app/Sources/NativeHost/` — signed Aqua permission host source and metadata; the built app is embedded once at `Contents/Library/Native/Tron Native Host.app`
- `packages/mac-app/scripts/bundle-gateway.sh` — generated gateway payload owner

The retired Mac Operator accessibility/socket bridge is absent. The agent uses
its normal filesystem, terminal, extensions, and tools; the wrapper is not a
worker host.

## Internal workspace preservation

The Gateway resolves Tron's durable internal workspace as `<tronHome>/workspace`
(Stable `~/.tron/workspace`, Debug `~/.tron-dev/workspace`). Implementation-owned
operational files live under `<tronHome>/internal/`; delegated provider artifacts
use `<tronHome>/internal/subagents/`, and the Mac wizard uses
`<tronHome>/internal/mac/wizard-state.json`. These are separate owners, not a
shared generic state store. Ordinary retained documents belong in `files/`;
`state/<owner>/` is reserved for real capability-owned data. Canonical JSONL and
runtime stores remain under the separate Pi `agentDir`.

The wrapper does not scan, index, synchronize or recreate this workspace.
Application replacement and `TronUninstaller.cleanLocalState`, including local
settings/credential resets, preserve both workspace content and the Gateway's
`gateway/workspace-state` lifecycle evidence. Missing/unsafe workspace recovery is
manual; never remove it as an application or signing repair. The Gateway owns the
[initialization, backup and restore contract](../../gateway/docs/internal-workspace.md).

## Native host and first-time permissions

`Tron.app` embeds one dedicated Aqua `Tron Native Host` with the stable bundle
identifier `com.tron.mac.native-host`. Core onboarding continues to require FDA
only; the same page offers explicitly optional preparation of native permissions.
Completing that page does not enable computer control or imply an input backend
exists. The menu's Permissions window uses the same bounded surface after
onboarding, without rewriting the saved wizard step or repeating installation.
Closing that window retires its probes/watchers, not accepted consent commands.
Actual computer-control execution must independently require all of its native
grants and safety gates. Its bundled Aqua LaunchAgent declares a
Mach service with the same name and associates it with the Tron app. Explicit
setup first enables this service through SMAppService; if macOS requires background
approval, the separate helper step opens Login Items settings and remains visibly
unfinished. A valid bundled agent can initially report ServiceManagement
`notFound`; explicit Enable attempts registration for both `notFound` and
`notRegistered` after bundle validation. Registration errors propagate to an
inline setup error instead of being collapsed into a silent unavailable state. Permission Allow buttons are enabled only after a fresh service status
reports enabled. Approval itself never queues a delayed TCC request: the user then
chooses the explicit permission action. Once approved, launchd owns
activation and singleton lifetime across menu closure and login. Probes may wake
an already registered service but never register it, request TCC, or restart the
Gateway. Explicit uninstall first joins native retirement and unregisters that
helper, then removes the Gateway service and local runtime files. Native retirement
failure preserves Gateway registration and local state. The helper queries Accessibility
and Screen Recording from its own signed process, so a wrapper Boolean or the
Node Gateway cannot become permission authority. FDA remains the wrapper's
existing filesystem probe.

The host validates initial peers with
`NSXPCListener.setConnectionCodeSigningRequirement`; both connection directions
use `NSXPCConnection.setCodeSigningRequirement` before activation. Requirements
bind fixed product identifiers, the signed build's team and the actual bundled
peer's CDHash, not an arbitrary old build with the same identifier. Endpoint
bytes, PID and UID are not authentication. The declared Mach service carries
connections directly; no endpoint file, custom singleton lock or filesystem
rendezvous exists. Delegates stay strongly owned through the run loop.

The injected platform boundary separates read-only status/probes, explicit service
activation/removal and explicit TCC requests. Offline coordinator tests check that
neither probing nor premature consent registers a service, background approval
never silently launches consent, and accepted consent survives waiter cancellation.
Each disposable probe owns its connection and bounded cancellation. A consent
request has a separately retained owner and joins its real reply/error rather
than expiring after a UI timeout. Native TCC operations serialize on the helper's
main queue. A false preflight/request does not invent an explicit-denial history.
Requests carry an operation UUID and the wrapper applies an exact latest-request
fence, then publishes only a fresh post-command probe. The host retains sixteen
bounded command receipts to reject conflicting/duplicate permission requests;
these receipts are not a cache of current grants. TCC may be revoked: a fresh unavailable/revoked response replaces an old
badge rather than preserving a cached permanent grant. There is no automatic
prompt retry. Once registration is enabled, setup keeps an explicit Restart Helper
action available, including when only Screen Recording still reports unavailable.
Screen Recording may be attributed to the responsible outer Tron app while AX is
attributed to the native host; macOS restarting only the outer app after a grant
can leave the existing host with an old preflight result. Restart Helper joins
locally accepted consent and native capture retirement, unregisters before
registering, stops at the first error, and never itself asks for TCC. **Disable
Helper for Update** performs joined drain/unregister without re-enabling, using
the old authenticated wrapper before application replacement. It is not an automatic update/relaunch guarantee. Before adding input
execution, this lifecycle boundary must also join the native input owner; the
current service has no input work. Debug/read-only wrapper modes cannot request
permissions or activate the Stable helper. Actual signed-service TCC attribution, update/relaunch behavior
and background approval require release qualification; the separate observation
qualification app's grant is not assumed to transfer.

Capture has a distinct `com.tron.mac.native-host.capture` Mach service in the same
Aqua process. Its single shared Objective-C protocol is implemented in the inert
`TronNativeCaptureHost` static library; only the executable starts listeners. The
library can therefore be linked into offline tests without activating a helper.
The capture role independently authenticates its actual XPC peer against current
Stable job/process/payload provenance and signed Node bytes; it cannot request
permissions or service lifecycle changes. Opaque capture-only catalogs, one native
stream, bounded reads, demand expiry and joined retirement are specified in the
[installed capture wire contract](computer-control.md#installed-capture-wire-contract).

The API-versioned Node-API client is bundled beside the host in `Contents/Library/Native`,
not in a Gateway payload. The Gateway's capture transport loads that fixed client
only when requested. Its absence does not prevent ordinary Gateway startup or
source updates. Native client/helper changes use the manual Mac app update path.

The `native_capture` tool and the shared Gateway/iOS viewer use this capture path;
selected targets survive clean visibility suspension without retaining active
streams. The separate `computer` tool uses bundled Cua Driver, directly spawned
and retired by this same permission-bearing host. Pi owns the accepted tool await;
Cua owns native execution, not another planner. No custom event injector is kept. Building source does not update an
installed helper. Actual signed-peer, installed-service and real-window/mobile
qualification remain release gates.

## Wizard installation

`WizardState` admits an explicit Install/Retry synchronously and owns one task
and its stage progress through completion. Duplicate clicks share accepted work;
Back/forward navigation, step remounts and cancelled view waiters neither cancel
nor replay it. `InstallStep` renders that shared progress and owns only disposable
status presentation. Its status ping carries an exact latest-request fence through
cancellation, including late success and failure, so a remounted step cannot
publish an older result. Progress is durably published as a versioned owner-only
record at `internal/mac/wizard-state.json`; malformed/newer records fail closed
at Welcome and remain untouched until an explicit user-directed step override.
Visible write failures never silently reset or mirror progress in `UserDefaults`.
Completion remains authoritative only after `.onboarded` is written. This is not a durable installation queue across wrapper termination. Failures stop later stages; retry remains an
explicit user action against fresh validation and ServiceManagement state.

Entry discovery is asynchronous presentation, not installation authority. It is
retired on cancellation or when an explicit installation supersedes it. Completed
installation does not repeat discovery whose result is hidden by the authoritative
install outcome. `WizardInstallationTests` exercises accepted lifetime, duplicate
admission, first failure, progress continuity and stale observation rejection with
owned fixtures and synthetic service callbacks.

## Pairing

Each profile's gateway creates `<profile home>/gateway/enrollment.json` (Stable
`~/.tron`, Debug `~/.tron-dev`) with mode `0600`, a 10-minute expiry, and a
one-time code. The wrapper accepts the gateway's
RFC3339 expiration timestamp with or without fractional seconds.
`PairingInfoStep` first authenticates a local `system.info` request using
`gateway/local-auth.json`, retains the exact Stable admission, and repeats the
ping/admission immediately before reading the current enrollment file. Any
process, payload, or authenticated runtime transition clears the pairing
presentation. Pairing refreshes carry an exact latest-request fence through all
awaited admission, probe, and QR stages; cancellation or retirement cannot
publish a stale payload, failure, loading state, or cached host. The wrapper
accepts the Gateway's RFC3339 credential timestamp with or without fractional
seconds, then emits:

```text
tron://pair?host=<tailscale>&port=<port>&code=<one-time>&label=<mac>
```

Permanent device tokens never enter QR codes or Swift presentation state. After
an exchange the gateway removes the used invitation and issues a new one.

## Supervision and status

`SMAppService` owns registration and launchd owns the gateway process. Stable's
LaunchAgent uses Boolean `KeepAlive=true`, `RunAtLoad=true`, and a throttle interval;
pause and uninstall therefore unregister the job before intentional stoppage. Managed
LaunchAgents advertise `TRON_GATEWAY_SUPERVISED=1`; planned restart and handled
supervised signals exit 75 so direct foreground restart controls still fail closed.
When supervised, the C launcher resolves the selected Tron home and redirects
stderr to `<Tron home>/logs/gateway-stderr.log` before executing Node. The Gateway
records remain canonical in `gateway.jsonl` and are not mirrored while supervised.
Mac app startup maintenance truncates this stderr file only above 1 MiB: it is
reserved for rare launcher and Node abort text, not the volume-heavy Gateway
record stream.
Quitting `Tron.app` does not stop accepted work. Quit and async command/uninstall
exits request AppKit termination through `ApplicationTermination` on the main
run loop, outside the main dispatch queue. AppKit's `.terminateLater` nested loop
can otherwise starve main-actor cleanup/reply tasks; `DispatchQueue.main.async`
is not a fix because its callback still occupies that queue. The isolated real
AppKit subprocess in `MenuBarTerminationTests` verifies successful termination,
cancel/retry, and watchdog failures for direct-task and dispatch-queue negative
controls without starting Tron services. `ServerStatusPoller` probes the Tron Gateway protocol and combines
health with registration state. Menu controls can pause, resume, restart,
inspect bounded persisted Gateway logs, show a fresh pairing invitation, and
uninstall. Log and feedback capture resolve a validated
Tailscale host from live state or the bounded owner-only Tailscale cache and pass
it explicitly to the Gateway socket; absent host data fails unavailable rather
than falling back to loopback. The cache is an exact-schema version-1 regular
owner-only file and accepts only canonical Tailscale IPv4/IPv6 addresses.

Installed Release owns only Stable registration and lifecycle. It authenticates
to the developer-owned Debug Gateway on 9848 to report status and, when Debug
is Tailscale-bound, show pairing information. It never registers, repairs,
restarts, stops, uninstalls, caches into, or takes over Debug. Stable uninstall
therefore cannot affect `~/.tron-dev` or `~/.tron-dev/agent`. Stable associates
exactly with `com.tron.mac`; Debug has no SMAppService identity or helper in the
Release bundle. Stable ownership requires the exact parent, markers, helper
metadata, exact 9847 listener PID, selected immutable payload (or the validated
bundled fallback), PID command, and authenticated `system.info` version,
channel, revision, fingerprint, and runtime epoch to agree. Relative
BundleProgram metadata alone is never proof. Debug observation reads one bounded
scripts/tron-dev lifecycle snapshot and requires its exact live supervisor
PID/start identity, exact live child PID/start identity, sole 9848 listener,
immutable selected manifest, process command, and authenticated `system.info`
identity to agree. An orphan child is never admitted. Menu refreshes are
cancellation- and generation-gated; a pairing sheet consumes one pinned
immutable admission, so an older host/runtime observation cannot overwrite a
newer restart or loopback/Tailscale transition. Admission identity compares the
exact supervisor/child start identities, transport host, selected payload, and
authenticated runtime provenance; elapsed uptime is display-only and cannot
invalidate an otherwise unchanged admission.

`LaunchAgentRegistrationPlan` chooses keep, refusal or an ordered operation list.
It derives stale-runtime, takeover and refresh policy once from registration and
runtime metadata, application identity, helper presence and wrapper authority;
callers do not override derived decisions or supply a second parent identity.
Refresh/takeover are reasons for real bootout/unregister/register steps, not
separate execution modes or no-op steps. Live load and its focused tests share
one sequential executor: await each accepted step, stop at the first reported
failure, and never retry or re-derive ownership between steps.
`LiveLaunchAgentManagerTests` exercises the real planner with synthetic inputs
and the live executor with controlled callbacks, without changing Login Items. Bearer, enrollment, and network-cache credentials
use one bounded owner-only regular-file/no-symlink descriptor reader, followed
by separate exact-key schema validation. Stable transport never probes loopback
when Tailscale resolution is unavailable; Debug admits only the exact lifecycle
host (`tailscale` or `127.0.0.1`), and loopback Debug is never pairable.
ServerPing, GatewayRestartClient and MenuBarLogReader share the bounded WebSocket
transport handshake and receive deadline while retaining their error taxonomies.
After host resolution, log capture uses one five-second deadline across hello,
send and all receives; cancellation closes the pending socket rather than waiting
for a response. Its 1-MiB frame capacity preserves ordinary 200-record log replies
that exceed the health/restart probes' unchanged 256-KiB admission limit. Matching
log responses require `type=response`, Boolean `ok` and non-conflicting result/error
fields. No request is sent before hello acceptance, and unrelated frames do not
reset the deadline or extend the existing eight-frame limit.

`Subprocess` requires explicit observation or accepted-operation authority. An
observation has a five-second execution/capture budget and retires its owned
client on cancellation, timeout or excess output. Capture retains at most 1 MiB
per stream; incomplete or invalid UTF-8 observation output is never returned as
success. One owner drains both pipes and processes exit/cancellation wakeups;
readiness does not rely on periodic polling. After child exit, inherited writers
have at most one second to close before Tron's read descriptors retire. The
runner does not kill unrelated descendants or the service being queried.
Tailscale candidate selection stops on cancellation but still tries another CLI
for an ordinary not-ready result. Budgets are per command, not five seconds for
whole host resolution; native launch and process retirement also depend on the OS.

Helper signature verification and identity inspection also use this observation
owner, preserving the deep/strict verification flags. Their callers await results
rather than blocking a UI thread on process exit before draining output. Each
query has its own budget; filesystem validation and the whole installation are
not covered by one five-second deadline. Identity diagnostics must contain one
exact bundle identifier and one nonempty team identifier; incomplete/ambiguous
metadata and ad-hoc signing fail closed before registration. `CodeSignatureProbeTests`
uses owned executables with the real selected policy to cover noisy, hung,
cancelled, oversized and failed queries without running signing tools.

Accepted lifecycle commands instead await authoritative child completion despite
UI cancellation. Their captured bytes have the same retention cap, before
replacement text decoding and a bounded note for incomplete capture; clipping
diagnostics does not fabricate command failure. Command execution itself is not timed out or
replayed. An unconfirmed command outcome is reported as unknown, not undone.
Registration refuses failed runtime capture, uncertain port observation, and a
running PID whose command could not be observed before authorizing any repair.
Loaded-state capture failure remains unknown: status shows failure rather than
paused, and menu Restart refuses it before load/repair or a restart request.
Registration and loaded state remain separate protocol requirements.
`SubprocessTests` uses owned helpers and FIFO readiness to check cancellation,
exit, byte limits and descriptor closure without invoking actual lifecycle tools.

The wrapper and gateway share no in-memory state. Their only shared secrets are
owner-only gateway files. Provider credentials remain in the Pi runtime store and
wrapper credentials remain under `gateway/local-auth.json`; neither is shared with
the other.

## Feedback privacy

The menu feedback action exports the same environment/status context and recent
log text through a prefilled GitHub issue, or its existing 7,000-character URL
limit/clipboard fallback. `FeedbackIssueComposer` masks known quoted credential
fields, Bearer runs and local paths in both logs and server failure details
before either export route. `DiagnosticsRedactor` treats escaped quotes and
backslashes as value content, masks short credentials, and stops truncated values
at their own line boundary so the next diagnostic survives. Empty credentials
and non-sensitive fields remain useful. This is a targeted export safeguard,
not a general secret detector or a change to the private log viewer.

`DiagnosticsRedactorTests` protects the string boundaries; `FeedbackComposerTests`
checks the decoded issue body and the exact body used by the clipboard branch.
Neither requires live logs, credentials, a clipboard write or an issue submission.
`MenuBarLogReaderTransportTests` also exercises the actual reader against owned
loopback WebSocket peers: stalled hello/response, cancellation and socket close,
large/oversized responses, hello admission, frame count and sanitized Gateway
error export. Its watchdog only releases broken clients; deadline assertions must
pass before that cleanup. Menu dismissal does not cancel an accepted feedback
action, and the private viewer's layout, refresh and copy behavior are unchanged.

## Gateway payload selection

The installed Release wrapper owns only the stable launcher. Developer tooling
owns the independent dev channel. Each launcher first
checks the selected channel (`TRON_GATEWAY_CHANNEL`, accepting only `stable` or
`dev`, with `stable` as the compatibility default) as a single bounded path component before touching any
channel-derived marker or lock under the selected Tron home:

```
~/.tron/gateway/payloads/<channel>/current.json
~/.tron/gateway/payloads/<channel>/versions/<version>/manifest.json
```

`scripts/tron dev` resolves the repository's pinned Node before mutating state,
uses that absolute runtime and its sibling npm for helper/build/deploy commands,
builds and stages an immutable dev payload, starts or authentically drain-restarts
the developer-owned supervisor on 9848, and preserves all Debug state. `scripts/tron dev handoff` copies only the exact selected payload
whose pre/post authenticated identity remains unchanged into the Stable store as
an inactive candidate. Every mutating Gateway lifecycle/deployment command is
user- or maintainer-initiated; repository agents may prepare and validate a payload
but must not execute these operator-owned commands:

```text
scripts/gateway-payload-deploy.mjs stage --channel stable --source <payload>
scripts/gateway-payload-deploy.mjs promote --channel stable --version <version>
scripts/gateway-payload-deploy.mjs rollback --channel stable --command-id <unique-command-id>
```

`stage` copies into a new immutable version directory, verifies required files
and the complete SHA-256 fingerprint, and never mutates the active version.
Every payload manifest also carries the exact protocol and minimum protocol from
`config/GatewayProtocol.json`. The signed launcher admits only its compiled
lockstep range; after a Mac app replacement, an older selected payload is
therefore rejected and the matching bundled Gateway becomes the one-time
migration bootstrap without deleting `~/.tron` or weakening the wire contract.
Every payload includes a regular fingerprinted `app/PushService.xcconfig`.
Stable staging, promotion, rollback, launcher selection, Swift validation, and
packaging require its one exact non-empty public HTTPS origin; dev may carry one
explicit empty assignment. Stable source builds preserve this validated file
from the active immutable payload and never accept a source-tree or environment
replacement. A source-only rebuild also requires an exact dependency-lock and dependency-manifest match, then reuses the selected payload's already validated dependency tree without launching npm or contacting a registry; dependency changes require a newly signed payload. Installed-app verification compares the selected stable file with the signed bundled product and fails on origin drift, rather than reporting a stale sandbox/production selection as healthy. Notification state remains outside payload versions under the
canonical Tron home.
`promote` records expected identity, atomically publishes `current.json` while
retaining `previous.json`, and invokes authenticated `gateway.restart`. It waits
without a deadline for the exact old PID/start to disappear, then requires a different
PID/start stable across the exact candidate health probe. Normal candidate startup belongs
to launchd; listener absence cannot authorize a kickstart while an unbound startup process
may be live. After the candidate deadline, Stable recovery may use only the fixed
`com.tron.server` kickstart. Failure restores and revalidates the prior selection, accepts
an already-running exact restored payload, or replaces only an absent
or exact captured failed listener. Unknown listeners fail closed. Recovery verifies the
exact identity without RPC to the failed Gateway; explicit rollback uses the same boundary.
Stable and dev have independent locks, selections, and payload directories and
may run concurrently. The pointer has schema `1`, kind
`tron-gateway-selection`, and fields `channel`, `version`, and
`payloadFingerprint`. Each version manifest also carries source revision,
runtime epoch, and the complete fingerprint coverage declaration. Staging,
promotion, and the Swift payload validator verify every regular file and
internal symlink under `app/` and `runtime/`; links must resolve to regular
files inside those same fingerprinted subtrees. Directory links and links into
unfingerprinted root content are rejected so executable bytes cannot sit outside
traversal, while each admitted link's path and exact
target text remain covered by the deterministic fingerprint. Swift validation
computes the same byte-ordered line stream incrementally, retaining full read,
ordering, and fail-closed checks without buffering the complete stream. The
runtime `node` and technical `pi` aliases are stronger required entries:
every validator requires exact relative target text and exact resolution to the
corresponding architecture runtime or payload CLI. The Node deployment
validator also rejects any relative module import in compiled `app/dist` that
does not resolve to a regular file inside `app/`; only `app/` ships, so an
import of repository content (such as `packages/protocol-fixtures`) would pass
source builds and tests yet fail module loading before the Gateway can log.
Runtime code owns its values and tests assert parity with shared fixtures.
Manifest schema 1 retains
its historical `dependencyTreeCoverage` string so the immediately preceding
signed launcher can admit a new payload; the canonical fingerprint algorithm
nevertheless includes internal symlink paths and target text. The small C launcher also recomputes the complete
fingerprint before exporting identity; it bounds manifest reads, rejects
escaping/dangling/special links and writable payload entries, resolves every
executable/resource path with `realpath`, and exports provenance before `exec`. Invalid or absent external
selection falls back to the bundled payload only after validating its
authoritative manifest. The LaunchAgent exports the selected payload's validated
`app/scripts/gateway-payload-deploy.mjs` as the only update helper; verified
artifact promotion is wired, and source builds read only the validated
`gateway/update-config.json` projection. Source mode compiles with the repository's
local TypeScript compiler into a private temporary output directory, never the trusted
repository's `packages/gateway/dist`, and copies only verified output into the candidate.
It shares the source dependency-tree lock with Gateway bundle assembly, requires the
active/source package locks and dependency manifests to match exactly, verifies the
lock root against `package.json`, and reuses the active payload's complete fingerprinted
`node_modules` tree without invoking npm. Preflight load-tests all host native modules
before publishing the selection. A dependency change requires a newly signed Tron build. If
the bundled payload was active before the first external promotion, failed
promotion recovery restores that bundled fallback directly.
The existing trusted Gateway postinstall helper also supplies the exact runtime
and CLI aliases while assembling a source candidate inherited from a predecessor
payload that predates this contract. Workspace installs have no sibling payload
runtime and remain unchanged; new payload admission still requires immutable exact
links.
Before package or extension discovery, the supervised Gateway validates the
selected alias against payload containment, executable identity, and the running
Node file. Stable places that immutable command first on `PATH`; Debug preserves
an already-working developer Node and supplies the payload command as fallback.
This keeps Stable independent of Homebrew/NVM while avoiding a Debug toolchain
regression. Alias failure aborts startup before third-party code loads. No payload
selection code writes canonical sessions or credentials.

Source-resource generation is also a one-writer publication boundary. A bounded
owner lock serializes dependency installation and bundle publication. The bundle
is assembled and fully verified under a private source-local root; only then are
the prior payload, launcher, and icon moved to a rollback root and the replacement
renamed into place. Signal/error cleanup restores the prior projection, so a
cancelled Xcode build cannot leave the source-checkout prepared payload half
written. The verification-only path remains lock-free and read-only.

The same immutable runtime boundary contains the pinned universal XcodeGen
executable and its complete preset tree. Release staging verifies the pinned
archive, executable bytes, preset-tree digest, version, and both Mac
architectures before publication; Xcode signs the executable before the outer
app seals the payload. The launcher and update preflight require the toolchain.
Source-built Gateway candidates inherit it byte-for-byte from the selected
validated payload or, when a newer contract invalidates that predecessor, one
explicit fully validated migration base: configured artifact, launcher-exported
bundle, or prepared source-checkout bundle. The copied snapshot must still match
its admitted manifest before mutation. The detached iOS installer receives its
absolute path through `TRON_XCODEGEN`, so launchd's sanitized `PATH` and
machine-local package managers cannot alter project generation.

The Mac app and iOS app emit the same canonical protocol range into their final
Info plists. Build scripts validate source constants, final app metadata, and
the bundled payload together; the physical-device helper additionally compares
the target Mac app before installation. The Mac menu Restart action
authenticates to the Gateway WebSocket, validates protocol identity, and calls
`gateway.restart` with a bounded command ID. The
Gateway drains accepted work; the wrapper then waits for the launchd-owned
Gateway to become healthy again. It does not use `launchctl kickstart -k` as a
restart shortcut; the fixed kickstart is reserved for payload deployment recovery after
the captured old process has exited.

Changing the bundled LaunchAgent plist requires the manual Release reinstall and
registration refresh in `docs/development.md`; payload promotion cannot update the
plist already registered by macOS.

## Signing order

The Xcode post-build phase copies the tracked `Contents/Library` tree and signs
nested Login Items before resealing the outer app. The shared gateway payload is
in `Contents/Resources/Gateway`; its Node runtimes are signed with
`TronNode.entitlements` so V8 JIT execution remains permitted under the
hardened runtime, while native modules remain minimally entitled. Release
validation must inspect the helper launcher, execute the host-native runtime,
statically validate the foreign-architecture runtime's checksum, signature,
architecture, aliases, and entitlements, and verify the production dependency
tree, outer signature, and notarization ticket. Foreign-runtime execution is not
required because Rosetta may be unavailable.
