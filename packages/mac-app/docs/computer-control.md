# Native computer use

Tron owns the signed Mac permission host, canonical Gateway sessions, and the
read-only iPhone viewer. Cua Driver owns desktop observation and input. There is
no second planner, browser engine, custom event injector, held-input ledger, or
input-recovery mirror. Browser automation remains with `agent_browser`.

## Owners and permissions

One bundled `Tron Native Host.app` is an accessory Aqua application. The wrapper
alone requests permissions and controls helper registration/retirement. The
Native Host needs Accessibility and Screen Recording; Full Disk Access remains
part of the Mac wrapper's core setup. Input Monitoring is not requested for an
unused event-observer implementation. Existing OS grants are never reset by an
update or by removing an unused permission surface.

macOS may additionally ask to allow direct screen capture rather than its private
window picker. The two ordinary TCC booleans do **not** prove that this separate
system dialog has been completed. A window-only screenshot can exclude an alert
covering the window. Before foreground input, the agent must inspect the full
desktop and ask the user to handle blocking permission/security dialogs. Neither
a focused window nor first-in-ordinary-window order proves an unobstructed input
target. Tron never approves OS permission prompts automatically.

`CuaProcessOwner` starts the bundled driver directly from this permission-bearing
process, with `--embedded`, its exact host bundle ID, standard authorization, and
an owned parent-liveness stdin pipe. The Gateway never launches the daemon. Cua's
telemetry is disabled in both daemon and CLI environments. History, PiP, browser,
agent, installer and backend-configuration surfaces are not exposed by `computer`.
The native helper owns a private0700 directory and a fresh UUID-scoped socket for
each child generation. It exposes only a running, same-user UNIX socket. No
endpoint is reused after restart. Startup failure leaves permission/capture
services available. Retirement seals startup, closes the pipe, and shares one
retained wait for actual child exit across every caller; it does not equate a
proxy's exit with native completion.

The shipped driver is pinned to Cua0.28.0, revision
`1b50c02e2d34734f64d2d22f54eb76cc97b4a663`. GitHub marks this release prerelease.
`ensure-cua-driver.sh` checks the archive and executable digests, both supported
architectures, and the upstream signing identity before staging. The vendor
signature is preserved; the outer app seals the executable and its MIT notice.
No installer, daemon, permission request, or production update runs during staging.
Cua is optional to ordinary Gateway startup and source-only updates; missing or
incompatible native assets fail the computer operation, not the whole Gateway.

## Gateway computer tool

The first-party `computer({tool, arguments})` tool is a narrow adapter over Cua's
public CLI. One extension load owns its endpoint binding, session identity, latest
opaque references, and at most one accepted invocation. Pi remains the canonical
session/operation owner. Its awaited `session_shutdown` event closes the bound Cua
session before invalidating the load; no parallel session registry is introduced.

Only explicit observation can establish or refresh an endpoint. Actions cannot
silently reconnect to a successor. Caller-supplied session, endpoint, environment,
private protocol fields, and screenshot paths are refused. The adapter injects
its load identity and bounds argument/output size, AX traversal and image bytes.
Images are returned as actual model image blocks after bounded PNG header/size
admission, not as dead temporary-file references. Temporary image files are
removed after publication preparation; they are not a live-video cache.

Fresh observation is required before another action. Element references must
belong to this load's latest window observation. Coordinate actions require an
image; foreground/desktop actions additionally require full-desktop observation.
These are admission checks, not proof that the desktop cannot change afterward.
The agent still verifies the intended app effect and honors user takeover/Stop.

Cua can exit0 with a refusal or an unverifiable result. The adapter parses these
outcomes: refusal is not success, and `unverifiable`/partial results remain
`outcomeUnknown`. It never retries a mutation. Waiter cancellation does not kill
an already-admitted CLI call; Stop prevents subsequent actions and waits for that
invocation. A command may complete after Stop was requested. Host/transport loss
leaves its effect uncertain, not safe to replay. Crash containment is not a claim
that process death proves physical key/button release in every failure scenario.

## Installed capture wire contract

The separate capture service `com.tron.mac.native-host.capture` remains in the
same Aqua process. Its shared Objective-C protocol is implemented in the inert
`TronNativeCaptureHost` static library; only the executable starts listeners.
The capture listener authenticates actual XPC PID/UID/audit session, public code
requirements, and current Stable job/process/payload provenance. Birth/path and
retained SCK objects are not exec- or WindowServer-incarnation proof. This is not
a sandbox against arbitrary code inside the admitted Gateway or the same OS user.

Each connection has one issued transport session bound by the Gateway to its
canonical session/load. Up to32 explicit capture handles retain initial SCK
window/filter and process bindings. App/title text is bounded display metadata,
never a target re-resolution mechanism. Capture handles are not input grants.
Four authenticated connections and four pending handshakes are bounded separately;
only a started stream reserves the one global native-capture slot.

Control JSON is nonempty UTF-8 and at most65,536 bytes. All requests carry version1,
operation and loadID. Except hello, they carry issued bootID/connectionID/sessionID.
Controls carry exact command IDs and bounded receipts (64, with Stop reserved).
Pulls forbid commandID and use strictly increasing disposable readSequence values.
The service reserves two cleanup replies independently of eight ordinary replies.

| Operation | Payload / result |
| --- | --- |
| hello | ready + issued identities |
| catalog | bounded opaque sources |
| start | exact handle → fresh stream generation |
| pull | generation/readSequence → latest JPEG or empty |
| suspend | actual stream join; only a clean join allows the retained target to resume |
| stop | terminal scope retirement, joined or retirementFailed, optional diagnostic |
| automationEndpoint | read-only Cua socket/generation bootstrap; no JPEG/input authority |

Native demand expiry requests Stop after15 seconds without demand and joins it.
Timeout itself never releases the stream reservation. Joined retirement with a
diagnostic releases capacity but is not a clean qualification result. Failed
native retirement retains capacity. Last-viewer close suspends capture; explicit
Stop, source loss, failed suspension and load replacement retire the reference.
A new stream is created only for the exact retained target after the previous
stream's clean join, never by PID/title/window lookup or uncertain-start replay.

## Direct Gateway capture client

The Mac-owned `Contents/Library/Native/tron-native-capture.node` uses C Node-API8,
not V8 APIs or a relay. API3 is required for endpoint bootstrap. Import is inert;
explicit open validates the installed outer/helper signatures against the actual
signed Node publisher and pins the helper CDHash on NSXPC. No alternate binary,
endpoint, credential or code requirement is accepted from a model.

JavaScript owns Promises; native code owns disposable callback references. Each
Node environment bounds four connections, with four ordinary request slots, one
independent suspend/Stop slot, and one terminal queue slot per connection. Accepted
requests and explicit close retain actual event-loop liveness; idle clients do not.
One bounded TSFN queue carries callbacks. Native allocation failure seals admission
and uses a NULL terminal sentinel without allocating another payload object.
Rejection sweeps clear each callback exception before notifying later callbacks;
callbacks are consumed once and are not retried. Forced teardown drops references
without calling JavaScript; NULL-env queue disposal never reads finalized context.

Suspension joins the host receipt **and** an already-admitted JS read/start callback
before allowing resume. Terminal close joins a pending suspension before using the
reserved control lane. Interruption invalidates immediately before JS notification;
an already-admitted send may remain uncertain. Native transport loss is never
reported as clean remote retirement.

## Capture and viewer

`NativeWindowCapture` is a single-use stream over a retained selection. Its producer
is bounded to1280×1280,1–5fps, queueDepth3, BGRA8/sRGB/SDR,8MiB raw and2MiB JPEG.
Encoding is synchronous and latest-only, with no task per frame. Signed source
extents and inward scalar cropping are validated before CGRect construction;
contentRect is scaled by scaleFactor, not contentScale. Only the exact canonical
null presenter-overlay sentinel is accepted as absent; malformed/nonempty
presenter metadata terminates capture rather than leaking another surface.

`WindowCaptureStreamLifetime` owns callback admission, start/stop waits and sample/
delegate queue drains. Abandoning a presentation waiter does not abandon native
cleanup. An uncertain native removal cannot be turned into joined retirement by
process death, elapsed time or an empty local cache.

`native_capture` + `display` and the existing shared HTTP/iOS viewer remain separate
from input. Only canonical display references on the active branch authorize
viewing. First visible lease starts capture; last lease closes pixels and suspends
it. Browser/native viewers share budgets and the same native layout/decode/activity
owners. Historical installation and reconnect do no hidden work. Input coordinates
come from Cua's own current observation, not the phone video's crop or scale.
See the Gateway README and iOS `display-artifacts.md` for their owner contracts.

## Qualification and maintenance

Focused checks cover Cua endpoint/session policy, refusal/uncertainty and images;
real subprocess pipe/retirement ordering; host admission/capture/suspend; signed
Node addon queue/exit/allocation paths; and mounted iOS paint/visibility/geometry.
Live vendor-driver checks use a disposable fixture and independent app outcomes.
They do not certify every app, OS version, locked-session use or sudden mid-action
host death. Same-installed-host end-to-end validation remains an explicit gate.

The retained `TronNativeCaptureQualification` creates its own marker window, checks
actual decoded colors and resize geometry, joins Stop, then checks source close
with a second stream on the same selection. It is capture-only and never inputs.
Build without launching or changing permissions:

```sh
packages/mac-app/native-computer-control/qualification/build-capture.sh \
  --output "$HOME/.tron/workspace/files/builds/native-capture/<new-run>"
swift test --package-path packages/mac-app/native-computer-control
python3 -m unittest discover -s packages/mac-app/native-computer-control/qualification -p 'test_*.py'
```

Native app replacement and Gateway transitions are manual maintainer actions.
Use the old authenticated wrapper's **Disable Helper for Update** before replacing
an enabled helper. Uninstall drains/unregisters the helper before Gateway/files.
`.notRegistered` is a no-op; `.notFound`/unknown cannot establish retirement and
must not be silently treated as success. A permission-only installed build without
that control needs an explicit maintainer bootstrap, not a compatibility bypass.
Never delete user data, reset grants or weaken signing pins to make an update pass.
