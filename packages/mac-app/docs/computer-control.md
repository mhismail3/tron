# Native computer-control foundations

`native-computer-control` contains unregistered construction, interlock, lifetime,
explicitly started passive-observation, and capture-only window-stream primitives
for the future Tron GUI capability host. `Tron.app` bundles a separate Aqua
permission host for first-time TCC setup, but that host is only a signed
readiness/request consumer; it does not start the observer or window stream, or
expose input/capture tools. The package is not a production executor, focus
manager, AX target resolver, or proof of application effects. It does not post
events or launch a process. The live input backend and trusted host still need
to establish when an inert `ConstructedInputPlan` may be admitted and released.

## Contract

`InputPlan` is caller-owned typed data. Pointer actions require explicit logical
screen `targetBounds`; every point must be finite and inside those bounds. The
constructor does not infer display coordinates, resolve a target, activate an
app, request TCC grants, or use AX/capture/global events.

Physical keys use the closed `PhysicalKey` identity set and macOS hardware
keycode mapping. These are physical key positions, not a promise of layout-aware
character shortcuts. There is no uppercase key identity: use explicit `.shift`
for an uppercase physical chord, or literal text for textual intent. Caps Lock is
a persistent latch, not an operation-owned modifier, and is excluded. Modifier
arrays reject duplicate identities. Each key action emits cumulative
`flagsChanged` transitions, a physical key down/up, and matching modifier
releases. The constructed release metadata names the exact held resource and
its opening event ordinal.

Literal text is separate from physical shortcuts. Each chunk produces exactly
one Unicode-bearing keycode-0 down and one keycode-0 up with an empty Unicode
payload. There is no preceding bare down. Native held identity is `.keyboard(0)`
for both Unicode commitment and physical A, so semantic aliases cannot acquire
the same native resource twice. Only a down acquires a resource; each release
consumes its exact opening ordinal once. Text chunks preserve `Character`
boundaries and therefore never split a UTF-16 surrogate pair; an individual
extended grapheme larger than one event is rejected. The SDK permits frameworks
to ignore overridden Unicode and translate physical keys themselves, so this
construction contract does not prove text acceptance by every app.

Mouse events carry exact logical position, button, event type, and click state.
Only left/right/center buttons are accepted. Clicks are bounded to 1–3 and
expose typed hold/inter-click delays, defaulting to 28/80 milliseconds. Native
multi-click recognition still requires live qualification. Drags carry
an explicit path (2–128 points), button, bounded duration, and deterministic
per-segment delays. Scrolls carry vertical/horizontal deltas and unit. Delays
are typed records rather than sleeps hidden in construction.

Hard ceilings are 64 actions, 64 KiB UTF-8 per plan, 32 Ki UTF-16 units per plan,
20 UTF-16 units per commitment, 512 expanded records, 30 seconds of total planned
delay (including drag/click timing), 2 seconds per click hold/inter-click interval,
and absolute scroll magnitude 100,000. The 20-unit chunk cap is a conservative
Tron policy, not a stated universal platform limit. Callers may tighten limits;
widening any ceiling is rejected. Pointer bounds are half-open at their right
and bottom edges. Pixel and line scroll fields retain Core Graphics' native unit
conversion rather than overwriting pixel values into line fields. Validation completes
before any `CGEvent` is constructed; all native construction is fallible and
results remain inert. Construction provides no native success, grant, recovery,
posting, or lifetime-owner proof; the separate internal file barrier below is
not part of event construction.

`TronComputerControlTests` inspects actual `CGEvent` type, flags, keycode,
Unicode buffer, button, click state, position, scroll fields, timing records,
and matched identities using independently specified expectations. It does not
post an event or call AX/capture APIs. The package also contains focused tests
for the internal file interlock, including real independent-process flock
exclusion, an unarmed no-marker crash control, an armed crash marker, and
fail-closed malformed, oversized, replacement, symlink, hard-link, mode, arm,
close, duplicate-retirement, and root-boundary cases. Those process probes use
only private temporary roots and standard `Process` helpers and are not proof of
native release.

The interlock is a deliberately internal, small physical-resource barrier. A
trusted host supplies one explicit owner-only root; package initialization does
not choose or create a native-home path. The root descriptor is retained while
an admission holds the one owner-only lock file via non-blocking exclusive
`flock`. Fixed relative lock and marker names are opened without following
symlinks and checked for regular shape, owner, mode, and link count. Ordinary
admission fails closed for any existing marker, including a partial, malformed,
old, or unattributable marker. Before a future owner’s first mutation, `arm`
flushes a bounded marker containing only schema/version and a random lease
identity. An unarmed close releases the descriptor; an armed drop or process
crash releases the OS lock but deliberately leaves the marker.

Only the later trusted native lifetime/recovery owner may invoke the internal
exact-marker clean-retirement/recovery primitives. Clean retirement keeps the
lease lock while it performs bounded no-follow inspection and exact
identity/content and pathname-inode checks, then removes and flushes only that
marker. The armed lease retains its original marker inode; even a same-identity
replacement cannot be removed by that lease. Crash recovery admits the currently
matching marker under the lock and pins that inspection through removal. Opened
marker attributes are checked before and after the bounded read; special-file
opens are nonblocking. Crash recovery takes the lock before applying its proof. Neither
path starts input, and this file barrier cannot prove physical native
quiescence, user authorization, app/focus/AX state, or a user grant. No executor, event-state registry/flags, PID reaper,
persistent action log, model-callable retirement, posting, capture, or tool
registration belongs here.

Owned descriptors are unguarded POSIX descriptors and are closed once, never
blindly retried after an error. Lock descriptors are explicitly unlocked first.
Setup, admission, arm, marker and recovery failures retain both the primary error
and any cleanup error. Repeated explicit retirement observes the same completion
error without closing a reused descriptor; ordinary abandonment cannot later
report trusted clean retirement. Nonthrowing deinitializers report close failures
through a metadata-only diagnostic. The host must not externally close/guard these
descriptors or use pthread cancellation against their operations; Swift Task
cancellation is not pthread syscall cancellation. The internal close seam tests
late errors by actually closing first, then reporting EIO—not by leaving a fake
live descriptor and inviting retries.

Original-lease clean retirement rejects even a same-identity replacement inode.
Fresh explicit recovery separately admits a currently matching marker under its
own lock; wrong-identity replacements remain quarantined until their actual
identity is explicitly selected by the higher-level trusted recovery owner.
Neither primitive supplies that owner's physical-release or authorization proof.

The host must keep this owner-only directory stable and control all of its
writers. Descriptor-relative operations protect path resolution; cooperating
writers serialize through the lock. This is not a sandbox against hostile code
running as the same UID: macOS provides no atomic compare-inode-and-unlink
operation, so a malicious same-UID replacement after the final check is outside
this trusted-root contract. There is no claim of hostile-filesystem protection.

## Native operation lifetime (internal, not yet a live tool)

`NativeInputLifetimeOwner` is the next internal owner above `InputConstructor` and
`NativeControlInterlockRoot`. It constructs and validates the complete inert plan,
acquires one interlock lease, arms its quarantine marker, and starts one host-owned
completion task. The task is independent of menu/phone presentation; cancelled
waiters request a monotonic stop but never cancel the completion task or abandon a
native backend await. Multiple callers join that exact task. Stop closes admission
to NEW events and leaves owned release work eligible; `requestTakeover` additionally
revokes the shared `NativeInputControlScope`, including a zero-event prefix and
after focus. A newly constructed operation cannot renew that same revoked scope;
only the later trusted host can issue a new grant. It never restores or overwrites
human focus/state.

The `NativeInputIO` protocol is deliberately narrow and has no production backend
or success facade. A future signed GUI host must bind its target to the actual
process/window/session generations and its scope to the real grant/source, then
return exact operation/event tickets, dispatch acknowledgements, and post-event
observations. Preparation receives the owner's complete inert packet, including each matching
release and delay, with all non-delay tickets assigned before native work starts.
Ticket sequence is event ordinal +1; delay gaps are intentional and stopping does
not renumber cleanup tickets. The backend must prepare its fallible native copies,
source, tags and matching releases for the whole packet before returning ready or
mutating focus/input. It must not reconstruct a different plan or discover that a
release cannot be constructed after its down was posted. Dispatch uses those exact
preassigned tickets and original inert event references. This internal contract is
not proof that an unimplemented native backend has prepared or released anything.

Preparation and dispatch receive a live owner-admission query. The
backend must check it after its own fallible/awaited preparation immediately
before native mutation, as well as validating actual target and cleanup authority.
Each query is bound to its exact in-flight native call. The owner linearizes its
return against the deadline under the lock, clearing admission before cancelling
the timer; retaining a query cannot authorize work during a later call. The backend
must perform no late work after returning. The query closes input admission; it
is not release evidence. Every event has
one attempted ticket and separate attempted,
accepted, and observed accounting. Resource acquisitions are keyed by the actual
native key/button identity and opening ordinal. A possible acquisition is reserved
before entering backend dispatch, not only after an acknowledgement; a matching
release ordinal is attempted at most once. Definitive no-dispatch and uncertain results are distinct,
and uncertain prefixes are never replayed. Focus preparation has separate
accounting from CGEvent records.

An acknowledgement or observation with a foreign operation, target, scope,
sequence, or resource identity is rejected. Every distinct acknowledgement,
observation and quiescence item must have a strictly newer backend sequence.
Quiescence must match the current request and control revision, not a pre-await
snapshot; focus uncertainty requires positive resolution. An already-up snapshot
cannot retire a queued down.
A failed or stopped prefix performs only attribution-safe, not-yet-attempted
matching releases. Unresolved post/ack/release, target drift, or preparation
uncertainty publishes `needsRecovery` while retaining the owner, lease, marker,
resources and pending completion. Recovery may be initiated only by the trusted
host through the same backend; its authoritative evidence is not a model Boolean
and timeout/PID death never clears state. Quiescence evidence must match every
uncertain ticket, pending opening ordinal, target/scope generation, and takeover
revocation before the internal trusted marker retirement primitive is called.
After native quiescence is actually established and the file operation returns,
a file retirement error is reported once as a terminal failure. It does not enter
an endless recovery loop for an already-removed marker or retry a consumed
descriptor. Any remaining marker still blocks subsequent admission.

Native I/O has a bounded diagnostic deadline (default five seconds). Expiry marks
`needsRecovery` and closes further input admission, but the owner still joins the
actual native call: it does not launch another native call or recovery while that
call survives. Recovery evidence is requested only when the owner is awaiting it.
Waiting for explicit authoritative recovery can remain pending; a timer never
manufactures that evidence. Plan delays are owned cancellable timers, not backend
I/O, so Stop interrupts a long delay while still joining any required release.
`completed` means the native packet and its retirement completed under this I/O
contract; it is not an application-effect confirmation.

`NativeInputLifetimeTests` checks that the complete packet and matching releases
reach preparation before the first dispatch. Its controlled backend refuses any
dispatched ticket/event not present in the initial packet; a leading delay tests
that dispatch does not regenerate dense ticket sequences.

This layer is controlled-I/O infrastructure, not proof of native OS effects. No
CGEvent is posted here, and no AX, app activation, capture, tool registration,
or floating viewer is added. Native backend implementation, signed-host
grant/recovery binding, disposable-window/focus qualification, canonical tool
exposure, and stable floating live-view gates remain open.

## Bounded passive stream observation

The observer defaults to its qualified session route. A separate process-bound
route uses public `CGEvent.tapCreateForPid` and requires the inventory's exact
`processBeingTapped` PID, canonical mask and listen-only/enabled flags. Route
selection is immutable for that observer; failures never switch routes. The
caller still owns live process-generation/target authority: a PID is not a grant.
The signed self-process qualification has exercised creation and joined retirement
on the tested OS. No events have been posted through this route, and another
process's delivery, target lifetime, release or recovery is not yet qualified.
A process tap does not observe physical input routed to other applications; it
cannot replace session-wide takeover detection.

The observation-only qualification executable adds `--observe-self-process`;
it observes only its own PID and never posts input or accepts an arbitrary target.
Its report is version2 and validates scope-specific metadata. Session reports
remain distinct from process reports; the previously signed version1 artifact
and its retained evidence are unchanged.

`NativeEventObserver` is an internal, explicitly started owner for passive
observation only. It uses the supported user-session `kCGSessionEventTap` with
`kCGEventTapOptionListenOnly`; it never uses the root-restricted HID tap, asks
for permission, or starts from an initializer/package load. The platform adapter
preflights `CGPreflightListenEventAccess`, creates a dedicated CFRunLoop on an
owned thread, and verifies the one newly registered same-process tap through a
bounded `CGGetEventTapList` before accepting its exact `eventsOfInterest`,
location, listen-only mode, enabled state, and mask. Missing permission,
ambiguous inventory, missing or extra mask bits, disabled tap, nil callback, or
tap-disabled callback is unavailable. If callback context is missing, the native
loop stops; its owning worker reports stream loss through the retained callback
box before retirement, settling pending reads. It is never silently re-enabled.

Each observer is single-use, with a fresh generation and at most 512 registrations
bound to one operation/target/scope. Unsupported event types are rejected before
registration. The owner registers `NativeStreamRegistration` tickets before
dispatch and allocates random positive `eventSourceUserData` tags, not counters
that repeat across instances. Tags correlate events; they are not authentication.
Exact registrations and supplied literal type, flags, key/button, click state
and position must match. Stamping clones the inert event and its source, then
verifies the tag and expected facts by read-back. A field-only rewrite can leave
cached source data unchanged on macOS 26.4; unsuccessful stamping returns nil.
Original events are unchanged and nothing is posted here. The offline private-source
regression also verifies that stamped down/up copies retain one actual native state
table ID, distinct from another source and the predefined state IDs, without
changing the original events/source. This is construction evidence only; neither
that test nor a currently-up source table proves native delivery or release.

One pending waiter per registration is admitted; a second is rejected rather
than overwriting its continuation. Cancellation affects only that wait and cannot
consume an already-seen result. A seen result is delivered once. Foreign input
raises at most one activity indication per observer, without retaining ambient
text, key history, event objects or screenshots. Disabled/mismatched/duplicate
callbacks close admission; failure never reuses a previous ready result. Health
is checked on demand, without a background poll or silent restart.

Async Stop shares one completion, closes admission immediately and joins even a
port created after the stop request. Startup failure also retires that exact
port. Cancellation requests Stop but never abandons the startup task. A pre-start
native stop is terminal, and native callback/run-loop resources retire before
joiners are resumed. Teardown runs away from the callback thread; callback
failure only requests stop, avoiding a self-join. Late callbacks cannot revive
state or report new activity. Dropping an observer requests cleanup, but only
explicit `stopAndJoin` is a joined-completion API. There is no timeout escape
hatch for active native work. Stream `NativeStreamSeen`
is intentionally distinct from `NativeInputObservation`,
`NativeQuiescenceEvidence`, application effects, target identity, and release
proof. The focused tests use an explicit test-only port seam and inert CGEvents;
they do not create or start a real tap. Signed-host permission, WindowServer
health, event delivery, physical takeover, native release, and application
consumption remain unqualified gates.

## Bounded capture-only window producer

`NativeWindowCapture` is a single-use, unregistered ScreenCaptureKit producer,
not native tool exposure or shared-viewer readiness. Construction is inert;
selection and `start()` are explicit operations. Nothing connects this owner to
the permission host, Gateway, iOS, input commands, or the browser stream.

`NativeWindowCaptureSelection.select` performs one initial lookup of an explicit
window ID for a retained `NSRunningApplication`. Public `PROC_PIDTBSDINFO` pins
PID plus exact kernel start seconds/microseconds before the SDK await and checks
that identity, the retained application's launch date/termination, and the
existing screen-recording grant after it. The exact `SCWindow` and private
`SCContentFilter(desktopIndependentWindow:)` are retained; no title matching,
PID-only rebinding, filter updates, restart, or window/desktop fallback exists.
Only a single ordinary application window (layer zero) is admitted. Ambient
window inventory is not logged or retained. There is no permission-request API;
preflight checks precede selection/start and frame publication. Preflight and
SCK calls are not an atomic TCC transaction: OS consent UI behavior during a
concurrent revocation still needs signed-host qualification.

**Authority limit:** SCK exposes no WindowServer window-incarnation token. This
selection means the exact initially selected SCK window/filter, not proof of a
caller's historical window generation or of window-ID reuse safety inside SCK.
Kernel launch time is process-lifetime evidence, not exec/code-signing identity.
The producer UUID fences callbacks and consumer work only; it is not a window
incarnation, `NativeControlTargetBinding`, or input grant. Exact input authority
and authenticated target integration remain separate gates. macOS 15.2 or newer
is required for SCK's window-inactive notification; older systems fail closed.

The producer configures at most 1280×1280 pixels, three native queued surfaces,
1–5 frames/second (default 5), BGRA8/sRGB/SDR, no audio, microphone, cursor,
child-window inclusion, or window shadows. Sample admission checks status,
timestamp, finite content rectangle/pixel density, exact canvas dimensions/format,
row stride and an 8 MiB raw-buffer cap. Encoding is synchronous on one serial SCK
callback queue. SCK's `minimumFrameInterval` owns cadence: a second clock/drop
gate could discard a static window's final complete update. The ImageIO byte
consumer refuses writes beyond 2 MiB rather than checking an unbounded allocation
later. These are producer/work bounds, not measured RSS, CPU, energy or latency.

The fixed native canvas avoids reconfiguration on resize. Each complete frame
is cropped using SCK's dictionary `contentRect` (surface points) multiplied by
`scaleFactor` (pixel density, 1–4), not `contentScale`. Scaled bounds must fit the
canvas before rounding; fractional edges keep only fully contained pixels. Signed
metadata sizes and inward extents are checked before constructing a crop: CGRect's
width/height accessors can otherwise hide negative sizes by standardizing them.
Out-of-bounds, empty or malformed geometry fails, never silently intersects or
clamps. JPEG dimensions describe the actual cropped content, including resize,
not a relabeled square canvas or source-window/input coordinates. This follows
[Apple's window-stream guidance](https://developer.apple.com/videos/play/wwdc2022/10155/)
and the public SDK coordinate definitions. Synthetic crop evidence still does
not qualify real-window scale/resize behavior or viewer/input integration.

Only the latest bounded JPEG is retained; `takeLatestFrame(generation:)` consumes
it once, without a waiter list, push callbacks or Task-per-frame backlog. A slow
consumer loses intermediate frames, never queues them. Frames are transient and
not written to disk. Callers must not accumulate returned frames and must carry
the producer generation through asynchronous presentation; retirement cannot
revoke a value already handed to a caller. Process/grant validation is repeated
at startup boundaries, on sample delivery, before publication and on pull.
Source-inactive, blank/suspended/stopped frames, presenter effects, malformed
samples, stream errors and unavailable identity/grants close admission, clear
the frame and initiate teardown; no later active callback revives the source.
Per-sample presenter-overlay metadata rejects small and large composites even
when the effect delegate is late; malformed overlay metadata also fails closed.
SCK's canonical absent-overlay `CGRect.null` attachment (positive infinite origins,
zero signed size) is accepted as empty, as is finite empty geometry. Other infinite,
NaN, negative-size or nonempty overlay values remain rejected. The live metadata
regression protects this sentinel without relaxing captured-content bounds.
The presenter privacy-alert setting alone does not disable composition.
Static-source health also relies on SCK terminal notifications and on-demand
pull validation, not a second background poll.

Stop shares one cancellation-independent task: it fences publication immediately,
waits for actual startup (including a stream handed over after Stop), awaits
SCK stop, removes the output, drains its sample queue and joins admitted delegate
work. The native callback gate atomically seals terminal-receipt admission when
the last admitted callback leaves, before publishing joined completion; a late
terminal callback cannot reopen bookkeeping after that seal.
Startup cancellation/failure also waits for that cleanup. Callback failure
requests teardown off the callback thread; it never self-joins. `stopAndJoin()`
stays pending after an uncertain native stop error until the native delegate
reports terminal evidence. `retirementFailure` exposes that error independently;
the pending cleanup task keeps the exact stream alive without retries, a global
registry or a self-retention cycle. Output-removal failure returns
`.failed(.stopFailed)`, not joined, and retains the failed resource. Normal owner
abandonment transfers its stream to the same actual native join path once, rather
than just closing callbacks; deinitialization itself is not quiescence evidence.
There is no timeout escape that pretends uncompleted native work ended. An OS
failure to provide terminal evidence can leave cleanup pending indefinitely.

`NativeWindowCaptureTests` uses only the internal fake platform/stream seam to
hold creation, startup and callback join independently; it covers cancellation,
late/foreign callbacks, failure, source/grant/process loss, abandonment, delayed
terminal evidence, stale-pull rejection before platform probes, bounded latest
frames and failed removal. `WindowCaptureJPEGEncoderTests` uses synthetic color
markers, real ImageIO encoding/decoding and inert SCK configuration to cover
format, scaled/non-origin/fractional crops, resize, final static updates and byte
admission. `WindowCaptureStreamLifetimeTests` exercises the actual adapter's
retirement control with only SDK stop/removal completions substituted. It covers
terminal-before/after-waiter, uncertain Stop after an attempted start, admitted
delegate and queued sample drains, final terminal admission sealing and failed
removal. These tests do not query grants, enumerate/capture real windows or prove
native SCK teardown. The package's existing SwiftPM test target discovers all
three suites. Parent-owned offline tests
and later explicitly authorized signed real-stream/Stop qualification are
required; no native capture has been qualified by construction or compilation.

## Standalone self-window capture qualification host

`TronNativeCaptureQualification` is a separate, unregistered qualification
executable in this Swift package. It is not a second installed product, permission
host, viewer, input backend, or Gateway integration. Its closed invocations are:

- No arguments, `--help`, `-h`, and invalid arguments perform only parsing and
  bounded text output, before even creating `NSApplication`.
- `--preflight` checks macOS 15.2 availability and only
  `CGPreflightScreenCaptureAccess`. It does not create a window, enumerate SCK
  sources, start capture, or request permission. Preflight success is not capture
  qualification or proof that another signing/launch context inherits a grant.
- `--capture-self-window [--write-images]` creates one main-actor AppKit borderless,
  nonactivating, non-key/main, normal-level panel containing only color markers.
  It ignores mouse events, never activates an application, and never manipulates
  another window. The only selection is its own window number with the retained
  `NSRunningApplication.current`; missing launch identity fails closed. There are
  no arbitrary PID/window/path/action/text selectors, permission requests, event
  observers, or native input events.

Capture uses the production `NativeWindowCaptureSelection.select`,
`NativeWindowCapture.start`, `takeLatestFrame(generation:)`, and `stopAndJoin`
APIs. The first lifetime must yield independently decoded JPEG marker patches
for 320×200-point initial content, changed content at that same size, and a
200×320-point resize with a third marker layout. The oracle validates the actual
JPEG type/dimensions before allocating a bounded decode, samples four 5×5 patches,
checks their independently specified RGB values (35/channel JPEG tolerance),
requires the expected aspect within two pixels, unchanged dimensions across the
content change, and transposed dimensions within two pixels across resize. It
rejects square-canvas relabeling, stale content and inverted markers. It does not
assume a particular display density or claim source/input coordinate authority.

Explicit Stop must join without a native retirement diagnostic, and a subsequent
same-generation read must throw exactly `stopped`, not return an empty frame or
hide an earlier source/stream failure. A second sequential producer on the same retained own-window
selection must first yield the resized marker image; only then does the fixture
close. Source-unavailable or stream-failed read rejection after that close is
recorded with its exact category, followed by joined Stop and a late read rejecting
with that same category. Both lifetimes inspect `retirementFailure` even when
`stopAndJoin` returns `joined`: a native Stop error followed by terminal evidence
is retained in the report and cannot pass as a clean qualification. Failure-path
cleanup also records that diagnostic. This proves the observed terminal behavior after controlled closure, not
that a generic SCK stream error uniquely identifies the cause. It is not OS input
release evidence. No capture path is duplicated or added to the production owner.

The report is at most 16 KiB, with at most four measured frame records and no raw
inventory, window titles, unrelated pixels, event payloads or underlying OS error
logs. At most 100 candidate frames are decoded. A fixed 20-second diagnostic
deadline or SIGINT/SIGTERM closes admission and requests Stop, but all native
selection/start/stop awaits remain joined; neither expiry nor process death is
success. The 50ms pull interval is only polling, never evidence of rendered content
or retirement. Native Stop can remain pending indefinitely. If joined removal
fails, the emitted report has `containmentRequired=true`; the app retains the exact
failed producers and remains alive for parent-directed containment, without retry,
restart or a timeout escape. A pending native join may produce no final report.

Without `--write-images`, no frames are written. With it, only accepted marker
JPEGs go to a fresh 0700 `/private/tmp/tron-capture-qualification.XXXXXX` directory
created by `mkdtemp`, whose path appears in the report. Four fixed filenames use
exclusive/no-follow 0600 opens relative to a pinned directory descriptor, at most
2 MiB each / 8 MiB total. Existing files and directory replacement are rejected.
Evidence is not recursively removed; the parent owns later inspection/retention.
This is a run-owned output boundary, not a sandbox against hostile same-UID writers.

Preparation reuses the observer builder's frozen-input, external-output and
Apple-Development-signature mechanisms through a **closed** `--product capture`
selection; `--product observer` remains the default and never starts capture.
Preparation only (does not launch, register, install or grant anything):

```sh
packages/mac-app/native-computer-control/qualification/build-observer.sh \
  --product capture --output <fresh-absolute-external-build-directory> \
  --identity <APPLE_DEVELOPMENT_CERTIFICATE_SHA1>
```

**Parent/maintainer gate:** review exact source hashes, frozen manifest, toolchain,
app files, selected capture bundle identifier, leaf certificate and hardened-runtime
requirement first. Ordinary offline tests must not run either live mode. After
separate explicit containment approval, launch the exact signed app in the
background via Launch Services (`open -g -n -W`) with `--preflight` only, inspect
its JSON `passed` result (not `open`'s
status), and stop if the existing grant is ineffective. Do not grant/regrant,
change TCC, substitute the installed app identity, or treat direct-binary/interpreter
preflight as this app's authorization. Only a separately authorized capture launch
may use `--capture-self-window`, also with background launch (`-g`). Require
`passed=true`, all four marker records,
both joins and late-read rejections, no deadline/cancellation/failure/containment,
and the source-close reason. If cleanup stalls, preserve the exact owner and
escalate; an external hard-kill/watchdog is not native retirement evidence.

`CaptureQualificationTests` is automatically discovered by the existing SwiftPM
CI command. It tests the actual entry router with native closures that must remain
uncalled for help/invalid input, synthetic real JPEG positive/negative controls,
report refusal for incomplete/expired/cancelled lifetimes, and fresh image-output
bounds/replacement refusal. The actual qualifier Stop inspection is also exercised
against controlled producers reporting joined-with-diagnostic and prior source
failure; first-lifetime acceptance cannot borrow second-lifetime error categories. It never constructs the AppKit fixture, queries a
grant, selects a window or starts SCK. These offline tests and compilation do not
qualify live rendering, display density, permissions, resize, source-close, signal
cleanup, WindowServer behavior or native retirement; the parent owns those gates.

## Standalone native observer qualification host

`native-computer-control/qualification/build-observer.sh` prepares a separate,
Apple-Development-signed GUI `.app` containing the `TronNativeObserverQualification`
executable. It is a preparation artifact only: it never launches, installs,
registers, restarts, or mutates Tron.app, the Gateway, or another application.
The generated source and signature manifests bind the app to this package's
first-party bytes, hardened runtime, bundle identifier, certificate SHA-1 and
Apple team requirement. The host is not a menu app, Gateway service, native input
backend, production registration, or completed qualification claim.

Help, no arguments, and invalid arguments only parse and print usage/errors. The
single explicit `--observe` mode starts the existing `NativeEventObserver` using
its listen-only session tap, records bounded metadata for taps owned by its own
PID (never event payloads, text, keys, screenshots or target effects), requests
Stop, joins the actual startup/tap/callback lifetime, and checks that the tap
created by this run is absent after the join. A deadline or cancellation requests
Stop but cannot make the report claim native work retired before the join. There
is no tap restart or permission prompt. SIGINT/SIGTERM cancel the owning task,
which still joins Stop before reporting. Unavailable permission, deadline,
cancellation, incomplete inventory or mismatched tap metadata produce a nonzero
exit, never an empty-set success. This is observer-retirement evidence only, not
OS input release, application semantic effect, target identity, or Gateway health.

Explicit qualification gate (after parent/maintainer artifact and containment
review; never during ordinary package tests):

```sh
packages/mac-app/native-computer-control/qualification/build-observer.sh \
  --output "$HOME/.tron/workspace/files/builds/native-observer/<run>" \
  --identity <APPLE_DEVELOPMENT_CERTIFICATE_SHA1>
RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/tron-observer.XXXXXX")"
open -g -n -W --stdout "$RESULTS/report.json" --stderr "$RESULTS/stderr.log" \
  "$HOME/.tron/workspace/files/builds/native-observer/<run>/TronNativeObserverQualification.app" \
  --args --observe --deadline-ms 5000
```

The preparation script defaults to the observer product; its only other selection
is the separate capture qualification artifact described above. It freezes package
inputs before compiling with a fresh,
external scratch directory. Its `artifact-manifest.json` binds those exact bytes,
the canonical Mac project and reused signing-policy source, toolchain, build
command, signed app files and verified leaf certificate. Frozen source changes
are rejected. It refuses existing outputs and installation/system/source trees;
it never launches the artifact or changes a running Gateway.

Use an application launch through Launch Services: direct execution of the helper
binary can inherit different TCC responsibility and ignore the app's grant. The
`open` exit status only covers launching/waiting, not qualification success.
Inspect the JSON report and require `availability.available=true`,
exactly one newly observed own-PID tap with the canonical mask/session/listen-only
metadata, `stopJoined=true`, no deadline/cancellation/inventory error, and a final
inventory equal to baseline. This gate requires the user to have already granted listen-event access
to this exact signed artifact; the host does not request it. Ordinary `swift test`
uses only the explicit fake port seam and is incapable of starting a real tap.

Parent validation uses the small package (do not substitute a real native home):

```sh
swift test --package-path packages/mac-app/native-computer-control \
  --scratch-path /tmp/tron-computer-control-build
```

The existing Mac CI job runs the offline build-input Python tests and this same
Swift package with a three-minute step
timeout. Interactive agent test execution is parent-owned and must use a hard
process watchdog; continuation bugs must not stall an unattended run. Timeout is
a failed test run, never native release evidence. Child workers do not run the
process/crash tests.
Each subprocess uses a uniquely named private temporary root and bounded readiness,
output and termination waits. Early failure and missing readiness are failure
cases, not success from a watchdog. Construction, interlock, and controlled-I/O
lifetime evidence do not cover the future native backend, trusted host, model
grounding, tool registration, or floating-view gates.
