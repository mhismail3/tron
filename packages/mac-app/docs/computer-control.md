# Native computer-control foundations

`native-computer-control` contains unregistered construction, interlock, lifetime
and explicitly started passive-observation primitives for the future Tron GUI
capability host. It is not a production tool, executor, focus manager, AX target
resolver, capture service, or proof of application effects. It does not post
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
observations. Preparation and dispatch receive a live owner-admission query. The
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

This layer is controlled-I/O infrastructure, not proof of native OS effects. No
CGEvent is posted here, and no AX, app activation, capture, tool registration,
or floating viewer is added. Native backend implementation, signed-host
grant/recovery binding, disposable-window/focus qualification, canonical tool
exposure, and stable floating live-view gates remain open.

## Bounded passive stream observation

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
Original events are unchanged and nothing is posted here.

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

Parent validation uses the small package (do not substitute a real native home):

```sh
swift test --package-path packages/mac-app/native-computer-control \
  --scratch-path /tmp/tron-computer-control-build
```

The existing Mac CI job runs this same offline package with a three-minute step
timeout. Interactive agent test execution is parent-owned and must use a hard
process watchdog; continuation bugs must not stall an unattended run. Timeout is
a failed test run, never native release evidence. Child workers do not run the
process/crash tests.
Each subprocess uses a uniquely named private temporary root and bounded readiness,
output and termination waits. Early failure and missing readiness are failure
cases, not success from a watchdog. Construction, interlock, and controlled-I/O
lifetime evidence do not cover the future native backend, trusted host, model
grounding, tool registration, or floating-view gates.
