# Session catalog and inspection

Catalog identity, acquisition, attention, archive and bounded canonical reads.
Owner: `gateway/session-catalog` (`session-catalog.ts`, `catalog-jsonl.ts`,
`catalog-metadata-index.ts`, `session-archive-store.ts`); attention lives in
`gateway/projection`. Live input: [execution](execution.md).

## Canonical identity

- Pi's `sessionDir` (or its per-workspace folders under `agentDir/sessions`) is
  authoritative; Tron never moves or mirrors it. `session.list` lists user sessions;
  `scope: "all"` adds delegated children. A delegated file is exactly
  `<parent-stem>/forks/<fork>.jsonl` or `<parent-stem>/<producer>/run-N/session.jsonl`,
  even if the parent is gone; a header may bind `parentSessionId` only to that derived
  parent (a contradiction fails closed and is omitted). Every other file, including
  top-level forks named `subagent-*`, is a user session. Names, text and timestamps
  never classify. Older top-level subagent files are not migrated.
- Several files with one embedded ID: all are omitted and open/delete by that ID is
  refused until repaired.
- A new session has no JSONL until its first assistant content; meanwhile the live slot
  projects one runtime-only row (slot time, cwd, phase; a fresh fork also its exact
  `parentSessionId`), openable and deletable, gone if Pi never persists it.

## The catalog owner

- `session-catalog.ts` holds the index of every canonical row and is the only
  membership source for `session.list`, cold open, attention, automation admission,
  workspace lookup, delete and storage maintenance; no request walks the folder. It
  updates from Gateway commit points, a recursive watcher on the canonical realpath
  root, and a whole-folder reconcile every `CATALOG_RECONCILE_INTERVAL_MS` (30 min) in
  batches that yield to the background scheduler. The watcher's debounce bounds delay
  after a hint, not OS delivery.
- Bounds: 50,001 directory entries, 25,001 directories / 8 MiB of paths, 25,000
  sessions / 8 MiB metadata; overflow fails retryably. Headers are read 512 bytes
  first, ≤ 64 KiB each within a 64 MiB aggregate, 16 files per batch. Names and
  previews are capped at 1,024 UTF-8 bytes. Raw lines are bounded to 64 MiB before
  decoding; an oversized row stays unproven (`catalog-index.failure step=line-limit`).
- `gateway/catalog-metadata-v2.json` is the owner's debounced acceleration only
  (identity, classification, file identity, size/mtime/EOF, tail hash; never text),
  root-bound, written 0600 with fsync; any mismatch discards it. Index version 3
  rebuilds counts on demand; `messageCount` excludes Pi `system` deltas.
- A file the owner cannot prove keeps its old row and refuses retryably
  (`catalog_not_ready`). User-scoped reads filter by each row's delegated flag and
  duplicates are quarantined, so a child write cannot fail a dashboard list. A read
  that finds no row waits for queued owner changes before `not_found`.
- Each cut carries the realpath root it traversed; incremental hints and writes are
  bound to it, out-of-root hints require a full traversal.

## Acquisition and startup

`RuntimeRegistry` reads membership, classification and duplicates from the owner's
rows with no filesystem read; live-slot admission and the attention commit read the
current duplicate set, so a later duplicate refuses `conflict`. Before SDK open the
selected file must still be the indexed file (path, stat, header); an unfinished
tail fails retryably; only a live slot's own inode may grow. Malformed files under
`subagent-artifacts` are ignored. Same-session cold opens share one startup; distinct
starts reserve capacity atomically and initialize outside the registry mutex.
`SessionManager.open()` still parses the whole JSONL, so a first cold open scales with
history until Pi offers a seekable open seam. Delete re-proves path, inode and
classification before inode-safe quarantine.

Startup binds the listener first, then loads attention and markers (`starting`),
waits for the first reconcile (`catalog-warming`), reconciles attention and markers
from that cut (`attention-recovery`) and loads stores (`storage-warming`) before `ok`.
Home task recovery runs after serving (`home.status.taskRecovery`). Artifact
maintenance uses the reconciled cut plus live slots and refuses on an incomplete cut.
Stage timings carry method, stage, outcome and duration only.

## Summaries and recency

`session.summary` is a revisioned per-session projection: aggregate and foreground
phase, `hasActiveSubagents`, `waitingForUser`, name, activity time, message count and
first-message title (skill envelopes and slash tokens stripped). Catalog rows carry
Automation creation identity only from a bound Automation invocation receipt (fork
headers win). Pi's pre-append `message_end` refreshes row facts so a new title shows
mid-response. Recency is the canonical user/assistant message time, overlaid while
active by agent events, detached extension timestamps and a 10 s heartbeat; viewing
never reorders. `activeSince` is fixed per active period. Summaries reach dashboards
without changing `listRevision`.

## Catalog pagination

Each traversal is one disposable materialization: every page shares `listRevision`
and an opaque cursor bound to connection, scope, filter, materialization, offset and
revision; leases expire after 30 s or at disconnect, with per-client and global row
and byte quotas. Additions and removals advance `listRevision`. An uncursored list may
send its retained token (runtime epoch plus page-source generation, covering summaries,
attention and archive); an equal token gets `notModified: true`.

## Read attention

`gateway/session-attention.json` stores only completion and read-through revisions,
manual unread, a recent-completion set and a recovery cursor. Only an accepted prompt
turn's assistant entry ending `stop` or `length` advances completion. A per-session
marker keeps ≤ 16 operations with exact completion stamps (full means newer admission
is refused); restart recovery resolves each stamped `assistantCompletionId` against
JSONL and never infers. Rows and summaries carry `completionRevision`,
`attentionRevision` and `isUnread`. `session.attention.set` is receipt-backed;
mark-read names the rendered revision. A completion seen by an active mobile
presentation is read at once. Home task workers (rows carry `homeTaskId`) complete
read; a failed acknowledgement logs `home-worker-attention-failed`. New, imported and
forked sessions start read; identity replacement moves the record.

## Archive

`session.archive.set` (receipt-backed, `session-archive.v1`) stores a display
projection in `session-archive.json`; it never touches the session file. It needs an
unambiguous idle user session (`busy`/`session_operation_busy` otherwise;
`conflict` for subagents). The idle check and commit share the slot lane; lock order is
registry mutex → session lane → attention/archive lane. Every Gateway-admitted run
clears the record in its admission turn; a Pi-started turn makes the row visible at
once and clears behind it (`sessions.archive.auto-unarchived`). Snapshots carry
`archivedAt`. `session.list` `archived: exclude` (default, `archivedCount` on page one)
or `only` (newest archived first).

## Transcript, context, tree and resources

- `session.open` returns a bounded tail with `transcriptStart`/`transcriptTotal`;
  `session.transcript` pages backward (≤ 512 items and the byte bound; `end - start`
  equals the count) with branch anchor, runtime generation and leaf, failing retryably
  if any moved. Fitted snapshots keep the newest 24 display-bearing entries when they
  fit. Upload envelopes become name/type/size metadata. Fork transcripts carry a
  disposable `forkBoundary` (inherited anchor plus gap ordinal), derived from the
  admitted parent (≤ 64 MiB read, 100,000 entries) or omitted.
- `session.context` adds `instructions` (`agent-instructions.ts`): the exact system
  prompt split into Pi's sections plus the turn context, each attributed to Pi, a Tron
  module, a package, a local file or an MCP connection; between runs, Pi's idle prompt
  (#1312). `session.resources` projects extensions, prompts, skills, context files and
  tools with handler names, counts and load errors in one byte envelope; every row has
  `distribution` (`external`, `module`, `local`). Subagents come from the installed
  `pi-subagents` discovery (≤ 128 rows, uncached, `subagentDiagnostics` ≤ 512 chars;
  `pi-subagents.agent-definition-invalid` once per load).
- `session.tree`: a flat outline of ≤ 1,000 nodes and 700 KiB, every entry validated
  first; summaries preview 240 characters.
- `session.history.list`/`entry` (`session-history-pages.v1`) need a subscription and
  exact `runtimeGeneration`: ≤ 100 previews in reverse append order over all
  branches, cursors anchored by ordinal and entry ID; entry reads ≤ 24,000 UTF-16
  units with offsets, never splitting a surrogate. Context edits, system messages and
  `usage` (Cache warmed) entries appear here but not as chat rows.
