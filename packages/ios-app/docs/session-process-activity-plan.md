# Session Subagent Activity

Status: Implemented; focused Gateway/iOS validation and physical-device deployment passed.
The Gateway must be rebuilt from the committed source revision before device acceptance.

## Product contract

Tron presents one session-level subagent activity affordance for structured delegated
runs that already exist. It observes:

- synchronous subagents;
- asynchronous subagents; and
- exact child sessions produced by those runs.

It does not observe assistant or user shell commands, Terminal PTYs, ordinary tools,
administrative work, or processes inferred from shell syntax, PIDs, output, or process
enumeration. Bash remains in the normal transcript/tool UI. This feature adds no executor,
detached-command tool, supervisor, event journal, history database, or durable iOS mirror.

## User experience

The composer shows one emerald orb only when the mounted authoritative projection has at
least one admitted current or recently finished subagent:

- **Solving** while any subagent is queued, running, or paused.
- **Thinking** while only terminal subagents remain in the five-minute recent window.
- Hidden when neither partition contains a subagent.

Tapping the orb opens **Subagents**, with **Active** and **Recently finished** sections.
Manage Session owns **Subagent History**, which adds canonical **Earlier** rows. Both sheets
open at the large detent. Their Liquid Glass cards use the solving orb for active work and
the thinking ribbon for terminal work, with canonical mode, duration, tool/path, counts,
and bounded output presented as distinct metadata. A row with a validated child session
presents a standardized large-detent bottom sheet containing the canonical-live, read-only
transcript viewer; it never pushes a second navigation route. Short or empty transcript
content aligns to the top while overflowing newest pages retain tail-opening intent. Rows
without a validated child session remain informative and expose no mutation controls.

Accessibility uses “Subagents” and “Subagent History.” Reduce Motion uses the deterministic
orb frame, and scene/offscreen state pauses animation.

## Authority and lifecycle

The Gateway owns producer admission, ordering, lifecycle, recency, history, and viewer
authorization. iOS validates and presents bounded snapshots/deltas; it does not infer
liveness or extend deadlines.

`process-activity.v1` supplies:

- `SessionProcessOverview` with revision, Gateway `asOf`, counts, visibility, and nearest
  expiry;
- bounded `SessionProcessActivity` rows with stable IDs, exact sync/async mode, lifecycle,
  optional current-tool/output facts, and optional opaque child-session references; and
- removal-aware `session.processActivity` deltas.

Only `kind: subagent` with `executionMode: synchronous|asynchronous` enters the iOS
presentation projection. Legacy command-shaped rows are validated for authoritative
snapshot compatibility but cannot mount, drive the orb, enter sheets, or enter history.

Terminal rows are recent until exactly `terminalAt + 300_000 ms`. The Gateway converts the
wall deadline to a monotonic in-process timer, emits an expiry replacement without another
chat event, and keeps a bounded terminal tombstone so late advisory artifacts cannot
resurrect expired work.

The older extension lifecycle projection remains compatibility infrastructure for producer
admission and interactive extensions. Active extension lifecycle rows use
`visibility: current` with no `remainingMs`; only terminal recent/historical rows carry a
terminal countdown. Ambient extension pills/widgets/services are retired.

## Real pi-subagents producer adapter

The outer `subagent` tool result binds an exact parent session, tool call, workflow run ID,
and admitted async artifact directory. The artifact is enrichment only; it cannot claim a
parent independently. Foreground pi-subagents progress arrives before its terminal root
`runId`; Gateway admits that live shape only for the exact installed `subagent` tool owner
and only when every bounded child has the producer-authored stable index, agent, and known
lifecycle state. Generic extensions keep requiring the explicit run ID convention.

Current pi-subagents status can represent a child step with `sessionFile` but no step
`runId`, and its Pi child header can omit `parentSession`. Tron therefore supports two
fail-closed child schemes:

1. A child header explicitly names the canonical parent and all path/header identities
   agree.
2. For the current producer shape, the exact tool-owned status artifact names a regular
   child file under the canonical parent child root using
   `<child-run>/run-N/session.jsonl`, and the bounded structural session marker ends with
   the same `subagent-…-<child-run>-N` token.

The second scheme derives the persistent child producer ID only after canonical path,
regular-file, non-symlink, inode, containment, status ownership, structural marker, and
ambiguity checks. Before that path exists, a bounded producer-authored foreground index may
identify a disposable live row only inside its canonical parent tool call; labels and array
position never authorize a child session. A conflicting explicit child ID, wrong token,
foreign path, wrong parent, duplicate identity, symlink, replacement, or malformed append
fails closed.

Async artifact observation installs a directory watcher and performs bounded retries when
an atomic status replacement overlaps the initial read. An admitted async directory
Gateway-authors `executionMode: asynchronous` even when the producer reports
`mode: workflow`; a direct synchronous workflow result remains synchronous.

## Canonical history

`process-history.v1` pages only normalized terminal subagent receipts from the selected Pi
branch. Assistant bash declarations/results remain canonical transcript entries but are
not process-history rows. Receipts preserve bounded lifecycle/aggregate facts, exact
producer identity, and an optional opaque child-session reference; they omit paths, tasks,
prompts, commands, and output.

History cursors bind one branch-derived revision and conflict when canonical generation
changes. iOS always requests `kind: subagent`, bounds pages/items/bytes, rejects malformed
or duplicate rows, and keeps history as a disposable presentation store.

## Read-only child sessions

`process-transcript.v1` opens a connection-owned lease through the exact live parent
process/tool/run/producer binding. It never calls `RuntimeRegistry.acquire`, creates a
second runtime, or exposes Stop/Kill/Retry/mutation methods.

Open, page, refresh, and invalidation revalidate:

- parent presentation and process ownership;
- opaque child reference and producer token;
- canonical containment and structural subagent evidence;
- catalog ambiguity and exact indexed path;
- original file device/inode identity;
- complete newline-terminated JSONL;
- a 64 MiB per-session parse budget; and
- stable page anchors/revisions.

The watcher is installed before the initial baseline read and latches changes during lease
publication. Gateway serializes page and refresh reads per lease and rechecks the expected
revision inside that lane, so cancellation cannot leave two requests racing to advance one
lease generation. Same-lease refresh preserves earlier pages, merges append-only overlap
with stable IDs, and closes on replacement, ambiguity, authorization loss, or parent dismissal.

## Privacy and bounds

The wire never carries absolute session/artifact paths, PIDs, environment values, task
text, prompts, or unbounded output. Delegated output previews use UTF-8-safe bounds and
credential masking. Activity count/byte limits and omission facts are Gateway-owned.
Runtime JSONL and bounded terminal receipts remain canonical; iOS state is disposable.

## Focused acceptance

Gateway checks must cover:

- real status shape with a child `sessionFile`, no step ID, and no parent header;
- active synchronous producer-index progress plus stable terminal transition;
- active asynchronous projection, stable terminal transition, and exact five-minute expiry;
- no command process events/history from assistant bash;
- active extension lifecycle serialization without `remainingMs`;
- receipt-backed restart history;
- read-only transcript opening without acquiring a child runtime;
- wrong token/path/run, symlink, ambiguity, append race, replacement, and byte bounds; and
- watcher retry across initial atomic status replacement; and
- same-lease prepend/refresh serialization with stale expected-revision rejection.

iOS checks must cover:

- command rows decode but fail process admission;
- mixed legacy command/subagent input presents only subagents;
- only synchronous/asynchronous subagent rows mount;
- active extension lifecycle with omitted `remainingMs` admits while `current + 0` fails;
- subagent-only composer gating, large-detent bottom sheets, Liquid Glass cards, orb state,
  history filter, and accessibility copy; and
- read-only append merge, top alignment for undersized content, tail-opening intent, and
  route lifecycle.

Device acceptance after rebuilding the Gateway:

1. Launch one 60-second async subagent and verify the solving orb plus Active row.
2. Let it finish and verify the same stable row moves to Recently finished.
3. Open its read-only child transcript.
4. Verify Subagent History retains earlier receipt-backed rows.
5. Verify the orb disappears at the exact five-minute recent deadline.
6. Run assistant bash and verify it remains normal tool UI and never enters Subagents.
