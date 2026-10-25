# gateway/episodic

## Purpose

`EpisodicMemory`: a binary summary tree over one canonical source that a request
layer reads at constant size. The algorithms are the public OptChat recipe's (cited
as `gist §N` in the code); Tron's departures are listed below. Home is the only
caller: one memory keyed by `homeId` across chapters
([Home README](../modules/home/README.md)).

## Owns

`episodic-memory.ts`, `episodic-store.ts`, `episodic-tree.ts`, `episodic-compactor.ts`,
`episodic-projection.ts`, `episodic-contract.ts`, `cache-layout.ts`, `home-source.ts`.
Canonical filesystem readers and digests live in [K1](../kernel/session/README.md);
the shared refusal class lives in `errors.ts`. Projection and cursor orchestration
remain here, and source limits derive from K4's actual prompt producer bounds.
State: `state/episodic/<sourceSessionId>/` (`initialized.json`, `catalog.jsonl`,
`nodes.jsonl`, `state.json`, `checkpoint.current.json`, `checkpoint-*/`) and the
workspace record `gateway/workspace-state/episodic-initialized.json`.

## Contract

- **Opening.** `EpisodicMemory.open` takes the workspace, source identity, an
  `EpisodicSessionSource`, limits, an injected compactor (no default model, no
  budget) and `isPaused`/`diagnostic` hooks. One opener per store per process (a
  second gets `already-open`). `dispose()` aborts compactor calls, waits for the
  mutex and the pump, then releases waiters and the opener.
- **Ingestion.** `entriesCommitted` reads deltas after the cursor through the source
  and drains the pump; `ingestForRead` refreshes only catalog and cursor (no model
  spend; Home's browser uses it with `withBrowserRead`). The memory never opens or
  subscribes to a session file: Home's source streams chapter deltas and a compact
  ID/parent index for exact cuts. A delta continues from the chapter cursor (dev/ino,
  size, complete offset, last line digest, complete-prefix digest), verifying only an
  8 KiB window (a same-length rewrite outside it can go unseen); navigation, context
  edits or a new identity re-read the chapter. A parse failure on a changing file
  leaves the cursor for retry; a stable malformed file blocks `source-unavailable`.
  Partial lines wait for their newline. The Home cursor is strict version 2.
- **Reads.** `whenReady(cut)` resolves when every view part before `cut` is built
  (cut 0 at once; beyond the count refused; blocked or aborted rejects).
  `renderView(cut)` is `id+n|text` oldest first. `zoomLines(id, n)` opens line `id+n`
  into its two halves (`n = 1` gives `id+0|kind: text`; invalid addresses return
  `undefined`; unbuilt children show the placeholder). `entryTimestamp(id)` returns
  the catalog instant only. `searchMessages(query, from, to)` is one case-insensitive
  substring pass: ≤ `EPISODIC_SEARCH_HITS` (20) one-line snippets of
  `EPISODIC_SEARCH_SNIPPET_CHARS` (300), whole-range match, omitted and capped counts;
  queries 1..`EPISODIC_SEARCH_QUERY_CHARS` (200). Reads never ingest; `HomeMemory`
  ingests first. `status()` reports generation, counts by level and kind, the view
  (bounded part list, `truncatedParts`), coverage, pump load, blocked reason, tokens
  and in-memory `sinceOpen` provider usage.
- **Projection.** Each entry on the current branch becomes at most one message with a
  permanent index: user text (images as `[image: <mimeType>]`) → `user`; assistant
  text plus `[call <name> <JSON args>]`, thinking omitted → `talk`; tool results
  `tool <name>: <content>` capped head and tail → `echo`; displayed custom messages →
  `event`; a context edit replaces its target or makes it `[omitted]`. Nothing else
  is a message. Indices are never renumbered: off-branch, empty and null-edited
  entries become `[omitted]` free nodes never sent to a model. Credentials are
  removed by `redactCredentials` (`util/credential-redaction.ts`), deliberately not
  `redactProcessText`. Text over `recordCapChars` keeps head and tail without
  splitting UTF-16 surrogate pairs. Each message
  records `sourceDigest`, `projectedDigest`, omissions (`thinking`, `attachment`,
  `capped`, `credentials`, `context-edit`, `off-branch`, `empty`,
  `unsupported-part`) and a required `timestamp`.
- **Tree and view** (gist §3–5). Node `(l, i)` covers `[i·2^l, (i+1)·2^l)`,
  addressed `start+n`. Free nodes (fit in `NODE` bytes) need no model. The compactor
  makes one call per node with the view's preceding lines in `<chat>` and the step,
  then up to `TRIES` size repairs. Replies are flattened across Unicode whitespace;
  the shortest reply is retained. If it still exceeds `NODE`, whole whitespace-
  delimited tokens fit within the budget with a visible `…` (a `.` for budgets
  below three bytes); an oversized unbroken token leaves only that marker. Repairs
  ask for a complete rewrite, never demonstrate a chopped prefix. The source and
  children remain available by zoom. The view is left alone
  within `VIEW` bytes and, once over, fits down to seven eighths by merging built
  pairs by largest `due` (batched so cached heads stay stable, #491). The pump builds
  a node only when unbuilt, its children built and its context summarized; up to
  `JOBS` at once, refilled per completion; paid merges only while the view exceeds
  `VIEW`. Chapter topics are a newest-first non-overlapping cover of built nodes and
  never start work.
- **Departures.** Context sent as cache pieces then the step; contexts stored as level
  runs; the view refolds from message 0 only at load (yielding every 2,000
  messages); revoked merged parts expand to leaves; invalidation carries ancestors and
  is written ancestor-first in chunks of ≤ 2,048 nodes (`open` repairs crashed
  chunks); blocked is persisted with bounded retries; every record has a revision;
  null edits and navigation are both `[omitted]`; the prompt names Tron's four kinds;
  context lines are flattened to one line.
- **Instructions.** One agent-first summary per node preserves concrete identifiers,
  maintainer decisions/wording, outcomes and uncertainty in plain sentences. A
  delimited stretch is the only subject; context only resolves references. Merges
  keep distinct items and compress tool chatter first. Prompt changes do **not**
  invalidate existing nodes: neither the prompt nor model identity is in their
  source digest. Only missing or source-invalidated nodes use new instructions;
  rebuilding old nodes is a separate maintainer decision, never automatic.
- **Invalidation.** A changed leaf invalidates its ancestors, every node whose context
  includes an invalidated node, and their ancestors, to closure; `generation`
  increments and the pump rebuilds. An early edit in a long history invalidates
  nearly the whole tree. `open` also invalidates leaves whose `sourceDigest` no
  longer matches the catalog (a crash between catalog and invalidation writes).
  Resume performs the same dependency/catalog reconciliation before replay, so
  a failed ingest cannot leave an edited catalog under a stale summary. Failed
  reconciliation rejects resume and retains its durable block.
- **Pause.** Home's ledger owns pause through `isPaused`: ingestion continues, the
  pump admits no new nodes, started nodes finish; outstanding and new `whenReady`
  waits reject `paused`; resume re-reads and drains. Not a zero-spend promise.
- **Blocking and spend.** Summary wording is never refused (#1279). Retryable
  failures (`isRetryableAssistantError`, prompt-safety flags) retry every `retryMs`
  (10 s) up to `maxRetries`, then `retries-exhausted`; plan limits block at once
  `usage-limit`; empty replies, refusals, auth and other permanent errors and
  unwritable records block `permanent-failure`; read failures `source-unavailable`.
  Blocks persist; Home calls `resumeIngested()` once per activation. Calls ask for
  reasoning `off` (clamped) with an 8,192-token output ceiling; prefer background
  models that can disable reasoning. Spend (`usage.totalTokens`, else every billed
  bucket) is recorded, never capped: nodes build only when missing or invalidated.
- **Caching.** Context first, cut at 50,000, 80,000 and 100,000 characters
  (`cache-layout.ts`), `long` retention, Anthropic marks within four, and
  `sessionId` `tron-episodic:<source session id>` as the cache key.

## Invariants

- Every record is appended and fsynced (with its directory for new files) before
  use; files are `O_NOFOLLOW` owner-only regular files checked by dev/ino.
- Catalog and node logs are append-only between checkpoints; the latest record by
  `revision` wins. A checkpoint is staged, synced, renamed and published by
  `checkpoint.current.json`; reads apply only tail records above its watermark;
  cleanup runs only in the single-opener path. `state.json` is the sole state
  authority, written whole within `HOME_MAX_CHAPTERS ×
  EPISODIC_HOME_CURSOR_MAX_BYTES + 64 KiB` (validated before replacement).
- A torn trailing line is truncated (`episodic.store-recovered`); anything else
  malformed refuses the store (`invalid-store`/`unsafe-store`,
  `episodic.store-refused`). `EPISODIC_STORE_VERSION` 2 with strict fields; no
  migration. A deleted shared container is lost state, refused; a missing
  per-session namespace starts fresh.
- Ingestion, invalidation, `resumeIngested()` and `dispose()` share one mutex; the
  pump runs outside it, and a result whose generation, children or message changed
  is discarded, never appended.

## Entry points

`EpisodicMemory.open`, `entriesCommitted`, `whenReady`, `renderView`, `zoomLines`,
`entryTimestamp`, `searchMessages`, `status`, `resumeIngested`, `dispose`. Home's
binding: `cutAtEntry` and `entriesIngested` (does not wait for the pump), so a
request never waits on summarizing its own input.

## Verify

```bash
scripts/tron test gateway src/episodic
```

`episodic-memory.e2e.test.ts` (`test-results/episodic-memory/report.json`),
`episodic-memory-recovery.integration.test.ts`, `episodic-reasoning-model.e2e.test.ts`,
`home-source.e2e.test.ts`, `home-state.e2e.test.ts`, `episodic.store.lock.integration.test.ts`;
the memory tools: `src/sessions/home-memory-tools.e2e.test.ts`.

## Not here

The memory tools' names, schemas and bounds and the typed browser:
[Home README](../modules/home/README.md). Model queues:
[settings model](../../docs/settings-model.md).
