# Chat ownership correction

Status: implemented. The production interactive chat surface is UIKit-only; SwiftUI owns only
independent navigation, toolbar, and sheet routing.

## Root cause

The reported blank transcripts, disappearing history, streaming jumps, and blocked resume paths
shared one defect: independently advancing presentation and geometry owners could observe different
commits and issue competing viewport commands. SwiftUI layout callbacks, sentinel materialization,
keyboard/composer measurements, and projection installation formed a callback-order protocol rather
than one atomic native transaction.

## Final ownership

### Canonical session authority

The Gateway runtime remains the sole live runtime owner. `SessionPresentationStore` owns the one
normalized mounted iOS session projection. `MountedTranscriptWindow` retains only exact contiguous
history preceding the authoritative tail; invalid range, overlap, lineage, or identity transitions
fail closed without replacing the last valid commit.

### Installed transcript

`ChatTranscriptPresentationStore` is a pure disposable formatter. It serializes and coalesces work
off-main, then installs one complete `InstalledChatTranscript`. The prior complete commit remains
visible until an exact replacement is ready. `installedVersion` advances only when that immutable
payload changes and is the native host’s admission clock.

The installed commit contains transcript, runtime, local lifecycle, queue, prepared Markdown, media,
and detail-routing facts for one exact source tag. UIKit never reinterprets `SessionSnapshot` or owns
a paging cursor.

### Native interactive surface

`ChatUIKitSessionSurfaceController` is the only transcript/composer geometry owner. It contains:

- `ChatUIKitChatViewController`: one compositional collection view, one physical offset writer,
  follow-tail or preserve-semantic-anchor intent, native interaction tracking, bounded restoration,
  legal-offset clamping, and blank recovery.
- `ChatUIKitComposerController`: one TextKit editor/responder, native keyboard observation, fitted
  and capped editor height, attachments/resources, send/stop controls, and accessibility order.

`ChatUIKitSessionSurfaceHost` admits each immutable source once and forwards semantic intents.
SwiftUI performs no transcript measurement, offset write, sentinel materialization, or composer
sizing. The retired SwiftUI transcript/composer, scroll coordinator, layout transaction, and morph
flight have no compatibility path.

### Paging and viewport

History availability comes only from the installed source range. An enabled Load Earlier action
always starts or visibly reports the session-owned operation; geometry cannot gate transport.
Prepend installs the exact canonical page and preserves a surviving semantic anchor, with nearest
ordinal fallback when identity is removed.

Native drag/deceleration updates preserve intent. Streaming growth, shrink, append, prepend,
keyboard movement, and composer fitting cannot create another writer. Catch Up explicitly restores
follow-tail. Same-session replacement retains native intent; a cold presentation starts at the tail.

### Composer admission

`ComposerDraftCoordinator` owns draft, attachments, selected resource, and submission state. It
reserves the exact preflight presentation identity supplied to the native send control and consumes
that same identity during atomic submission admission. Accepted or ambiguous sends remain duplicate
suppressed; only exact rejection or authoritative identity replacement releases the handoff.

Gateway queue/pending truth settles submission authority. Transcript formatting is not a command
receipt channel. Attachment-only submissions retain exact attachment evidence and cannot leave a
stale container blocking a later send.

### Tools, media, and details

Canonical declarations own transcript placement; runtime execution decorates those declarations.
Every native row derives renderer and accessibility facts from one installed physical payload.
Tool, thinking, notification, image, and file taps route from that payload to the existing detail
sheets. Media loading remains generation- and activity-scoped through the shared bounded loader.

## Durable gates

Focused automated coverage protects:

- exact transcript-window admission and continuity;
- monotonic installed/native generation admission;
- maximum bounded opening and legal nonblank offsets;
- detached streaming growth/shrink and prepend preservation;
- generation replacement and stale completion rejection;
- exact send identity, rejection retry, and duplicate suppression;
- native composer fitting, keyboard/activity lifecycle, accessibility, and Dynamic Type;
- canonical Markdown, code, tables, tools, notifications, lifecycle, queue, and media rows.

The hosted gate mounts the production native parent in a real `UIWindowScene` and crosses
`SessionPresentationStore`, `ChatTranscriptPresentationStore`, the physical-row adapter, and the
recording command boundary.

Manual device acceptance remains required before release: send text/photos/files, stream while
following and detached, load earlier history, contract/restore the keyboard, open every detail type,
background/foreground, replace the route, and relaunch active and passive sessions. No Gateway
lifecycle or deployment operation is part of this source validation.
