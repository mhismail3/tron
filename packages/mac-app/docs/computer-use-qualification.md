# Computer-use native G0 qualification

This standalone development package is **not a computer-use implementation** and
is not linked into `Tron.app` or registered with the Gateway. Its qualification modes
are explicit diagnostic gates, not a production ABI: they create and own a
nonce-bound disposable AppKit fixture process and perform one background AXPress
through Peekaboo's action-only service. The combined mode additionally captures
that exact window before and after through modern ScreenCaptureKit. The explicit
`--background-ax-only` mode deliberately does not request or call capture; it is
not an automatic fallback after a combined-mode refusal. Both modes share the
same fixture lifecycle, receipt identity, effect counter, frontmost/window-order
checks, EOF cleanup and independent controller deadline. The fixture's real
button handler owns the effect counter. G0 remains blocked until native Stop,
GUI-host authority, model fidelity and the remaining gates are qualified.

The combined mode independently preflights Accessibility and Screen Recording
before starting the fixture; AX-only requires only Accessibility for its selected
operation. It carries PID, process-start identity, CGWindowID, nonce and geometry
through AX inspection and action (and, in combined mode, both captures). The action
receipt includes the exact process/window/start/geometry identity. AX-only reports
`capture=not-requested` and has no screenshot receipt. It rejects
application-scoped fallback, stale identity/geometry, non-background delivery,
and `operationStillRunning` (that outcome is uncertainty, not quiescence). The
controller closes its private stdin pipe so the exact fixture reader exits from
an independent thread, even when its AppKit actor is blocked. There is no
PID-directed signal fallback. A 45-second controller deadline emits uncertainty
and exits that entire one-shot process rather than resuming an abandoned native
await; the fixture also has a 60-second self-exit bound. Parent verification of
both exact process retirements is still required. This process containment is
**not** the production native Stop/held-input contract, and cannot recall an AX
action already accepted by the target. Normal failures separately report native
uncertainty and fixture retirement. The fixture renders a
large green-to-red marker; decoded marker samples must change alongside the
independent AX counter before screenshots are accepted. Marker decoding draws
into an explicit RGBA8 sRGB context so Display P3 captures are not misread as
calibrated RGB. Blank, transparent and stale-colour outcomes remain failures. Screenshots are generated
only after the AX and image oracles pass, in a private nonce-derived temporary
folder. They are explicit evidence artifacts, not live viewer history. AX
snapshots use the native in-memory manager, not an ambient disk snapshot store.
Mutation-capable observations allocate a reference through that native owner and
use `detectElements` to publish the AX result under it. The inspection-only API's
unpublished UUID is not accepted as mutation authority; no ID rewriting is used.
The new fixture is ordered behind existing windows; both the frontmost process
and the opaque normal-window order must remain unchanged throughout the run. No global
HID, activation, display capture, arbitrary target/path, permission request or
existing-app mutation is used.

## Pinned build inputs

`qualification/computer-use/dependency-graph.json` records Peekaboo revision
upstream base `46d7586c7f0e08bc24f9c1865d8f58b234a198bf` and downstream candidate
`9cfcf5431655b42d171617239b2a31670966e362`, its submodule gitlinks and license
hashes. The committed `patches/peekaboo-capture-participants.patch` removes generic
third-party app IDs from implicit native-host classification, not actual owner
locks or registered Bridge refusals. The build checks both source bytes and the
exact base-to-candidate diff against the declared patch hash. `Package.resolved` pins the remote Swift packages. Only the native
AutomationKit product is consumed; checking the complete checkout/submodule
inventory does not mean its agent/model/CLI products are linked.

Candidate source stays in an external checkout. For a new checkout, fetch the
exact revision and submodules without selecting newer branch heads. The build verifies
Git objects, modes, clean state, repository origin, exact revision/tree, submodule
revisions, licenses, and the declared base-to-candidate patch; retained bundle hashes
belong in run-owned artifact provenance, not this build-input graph:

```sh
git clone --no-checkout https://github.com/openclaw/Peekaboo.git "$SOURCE"
# BUNDLE is an optional retained local source; record its hash in run-owned provenance.
git -C "$SOURCE" fetch "$BUNDLE" HEAD
git -C "$SOURCE" checkout --detach 9cfcf5431655b42d171617239b2a31670966e362
git -C "$SOURCE" submodule update --init --recursive
```

Set `SOURCE` to an explicit new absolute checkout path before those commands.
The build gate rejects dirty/untracked/ignored input, byte or executable-mode
drift (including Git `assume-unchanged`), wrong repositories/gitlinks, and license
drift. It checks native and resolved package inventories before and after the
build. Do not mutate these inputs concurrently; this development gate is not a
sandbox against a hostile same-user process.

## Build a new signed artifact

With Swift 6.3.3/Xcode 26.6, Python 3 and an existing Apple Development certificate.
The build step below only performs the non-prompting preflight; it never runs the
fixture or any AX/capture action. The parent runs an explicitly selected mode only
after review.

```sh
packages/mac-app/qualification/computer-use/build-qualification.sh \
  --source "$SOURCE" \
  --output "$HOME/.tron/workspace/files/builds/computer-use/g0-13" \
  --preflight
```

Output must not exist. Previous apps, records and installed applications are
never replaced. `--identity` accepts only the SHA-1 of a listed Apple Development
certificate; multiple certificates require explicit selection. The signed app
must match the canonical `project.yml` Team ID, fixed qualification bundle ID,
Apple anchor and hardened runtime before it is launched. Ad-hoc signing and a
caller-supplied alternate Team ID cannot pass admission.

Without `--preflight`, the command only builds/signs/verifies. With it, the exact
new bundle launches through LaunchServices without activation; it does not
request grants, enumerate windows, capture pixels or send input. Preflight reports
`nativeActions=available-but-not-attempted` to distinguish an available gated mode
from an action that was actually run. A preflight is not proof of TCC inheritance,
app effects, or menu-app lifetime. Permission booleans must be independently
recorded for the exact artifact; they are not inferred from an older receipt.

The output contains `receipt.json`, `source-manifest.json`, signature metadata,
build/test logs and optional preflight JSON. The receipt binds every final app
file and executable SHA-256 to the source manifest and exact designated
requirement. Never use an earlier unsigned/stale executable hash as identity.

## Availability and independent capture checks

Permission grants do not imply an unlocked GUI. Preflight reports
`guiSessionLocked`; action/capture modes refuse a locked or unavailable GUI
before creating a fixture. Unlocking is a user action; no lock-screen bypass is
implemented. `--capture-owner-check` tests the real native participant/lease gate
without entering ScreenCaptureKit or taking an image, so it can diagnose the
policy independently of GUI availability. Its lease retires with that exact
one-shot process.

`--capture-coexistence` captures one retained, nonce-bound window owned by the
controller itself before/after an app-owned green-to-red change. It uses the
real modern native capture service and source/order/pixel oracles, but sends no
AX/HID actions. A pass is capture evidence, not computer-control or model-vision
evidence. This separates capture policy from the background AX fixture's IPC
readiness. AppKit owns a synchronous top-level run loop; the fixture's local
delegate is retained for that loop's lifetime. AX readiness waits repeat only
fresh reads with unchanged target identity; mutations are never replayed.

## Real checks and limits

The pinned signed qualification artifact validates exact source closure, capture ownership,
background AX identity, and the fixture's independent effect/capture oracles. Its AX path retains
an explicit limitation: a detached `AXUIElementPerformAction` can outlive a caller grace deadline,
and cancellation is not native quiescence. The pinned package does not claim generic Stop,
foreground/global input, held-key/button cleanup, forced-pixel effects, model fidelity, or live
viewer integration.

The Swift and Python tests are bounded owner/oracle checks; synthetic collaborators and a separate
process lock probe do not prove live app effects or physical input. Scratch dependency experiments
and their counts belong in run-owned artifact provenance and are not part of the pinned build
contract. Accessibility and Screen Recording grants remain explicit user actions on the exact
signed app; no grant or settings change is automated here.
