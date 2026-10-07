# Episodic memory owner

`EpisodicMemory` (`packages/gateway/src/episodic/`) keeps a binary summary tree
over ONE canonical session's history: a "memory" of that session that a request
layer can read at a constant size. The algorithms are the public OptChat
recipe's (its sections are cited as `gist §N` in the code); Tron's departures
are listed below with their reasons.

This document owns the module's own contract. Home is its one live caller today:
the Home owner holds one memory over the Home session's canonical entries, feeds
it the commits the runtime reports, and sends each activation the view it renders
([home.md](home.md)).

## The owner and its inputs

- `EpisodicMemory.open` loads (or starts) the memory for one source session:
  the workspace, the source session id and its canonical JSONL path, limits,
  and either an injected compactor or the pi-ai model and `ModelRuntime` the
  default compactor runs on. There is **no default model**: it is the caller's,
  and there is no budget (#493). One store has **one opener per
  process**: a second `open` for the same session refuses with `already-open`,
  because two memories would write the same files without a lock between them.
- `entriesCommitted(sessionId)` re-reads the canonical file after its cursor,
  ingests what is new, and drains the pump. It awaits the drain, so a caller
  that wants the model calls off its own path simply does not await it.
  Ingestion, invalidation and `resume()` are serialized behind one mutex; the
  pump is not, so a build may still be running when the next commit invalidates
  nodes (see **Concurrency** below).
- `dispose()` sets this memory closed, aborts in-flight compactor calls, **waits
  for the mutex** — so an ingest already appending to the store finishes before
  the opener is released — then awaits the pump, releases the waiter list and
  releases this session's opener. The wait is what keeps a reconfiguration from
  handing the store to a second owner while the first is still writing it.
- The canonical read is **incremental**: the reader remembers the file's
  dev/ino, size, complete byte offset and the digest of the last complete line.
  When the file only grew, it reads from the offset and extends the branch it
  already knows; it falls back to a whole-file read when the identity changed,
  the file shrank, the line before the offset no longer matches, or the new
  entries do not chain onto that branch. An unchanged-source shortcut is allowed
  only for a proven incremental no-change read; a whole-file rebuild reconciles
  projected messages before it persists a refreshed cursor and complete-prefix
  digest. Incremental reads do not hash the retained prefix: they verify the
  file identity and the last complete line in an 8 KiB window, then hash only new
  complete lines. Thus a same-length rewrite outside that window can remain
  undetected on an otherwise-valid incremental read. A full rebuild reconciles
  the projection and persists a digest of the bytes it read; it does not reject
  the refresh merely because the old digest differs. A transient cut lookup
  hashes the complete ingested prefix before and after reconstruction and refuses
  a mismatch. The session file remains append-only under its owner; the reader
  neither repairs nor migrates it, and whole-file reads are bounded per line.
- `whenReady(cut)` resolves when every view part covering messages before `cut`
  is a built summary (gist §6). Cut 0 is trivially ready, so it resolves on an
  empty memory; a cut beyond the message count is refused; a blocked memory
  rejects instead of hanging; and an already-aborted signal rejects at once. The
  view's budget is soft, so this is not a hard window check; that belongs to the
  request layer.
- `status()` is the bounded status query (below); `resume()` clears a blocked
  state and restarts the pump; `dispose()` closes the memory, aborts in-flight
  compactor calls, waits for an ingest that is still writing, and only then
  releases every waiter and this session's opener.

The owner never subscribes to a session and never opens it with
`SessionManager`. It reads the file itself, which is what makes "never repair or
migrate a canonical file" a property it can hold. A transient cut lookup streams
and hashes the complete ingested prefix before and after reconstructing the
branch; if any earlier source byte changed in place, the cut is refused.

## Storage

Under the Tron internal workspace's capability state, owned the way
`KnowledgeStore` owns `state/knowledge/` (owner-only directories, created
lazily on the first write, owner-only files, secure bounded reads):

```text
state/episodic/<sourceSessionId>/
  initialized.json   # namespace-local version marker
  catalog.jsonl      # bounded post-checkpoint projected-message tail
  nodes.jsonl        # bounded post-checkpoint node/invalidation tail
  state.json         # authoritative source cursor, generation, blocked state
  checkpoint.current.json # committed watermark and immutable checkpoint directory
  checkpoint-*/      # live catalog/node JSONL plus the captured state
```

- Every record is written with one append and fsynced **before** it is used
  (gist §2: the recipe fsyncs every node). A record a caller has observed is
  durable. A file this store creates also fsyncs its directory, so the entry
  cannot be lost with the records already acknowledged inside it.
- Files are opened `O_NOFOLLOW`, verified to be owner-only regular files, and
  checked against a `lstat` dev/ino so a replaced path cannot be written.
- Catalog and node records are append-only between checkpoints. The latest
  record for a message index, and for a node address, wins; `revision` orders
  records. A checkpoint streams the current live projections to bounded-line
  JSONL in an owner-only staging directory, syncs the files and directory, then
  renames it to an immutable directory and publishes `checkpoint.current.json`.
  The pointer watermark identifies records represented by that checkpoint.
  Reads validate the checkpoint and every log record, then apply only tail
  records above the watermark. Persisted-state status reads validate only the
  authoritative state and do not replay or repair logs; neither they nor
  `read()` reclaim checkpoint artifacts. Abandoned staging/checkpoint cleanup
  runs only in the single-opener path after it reserves the session. `state.json` remains the sole state authority;
  the checkpoint copy records the captured cut and is shape-validated, but is
  not compared with later `state.json` updates. Superseded checkpoint data is
  reclaimed only after pointer publication.
- A **torn trailing line** is a write that never became durable. It is
  discarded and the file is truncated to its last complete record, because
  leaving it would let the next append concatenate onto it. The bytes discarded
  are reported through `episodic.store-recovered`.
- Any other unparsable record, a record that does not match its store's shape, a
  state document with an unknown or malformed version/cursor/blocked shape, or a
  live node whose children are missing or rebuilt refuses the store visibly
  (`invalid-store` / `unsafe-store`), and `episodic.store-refused` is raised.
  Nothing is silently skipped or migrated.
- The workspace feature record at
  `gateway/workspace-state/episodic-initialized.json` records that the shared
  `state/episodic` container was initialized, so a **deleted container is lost
  state**: it refuses instead of restarting and re-spending every compactor call.
  The shared workspace feature record remains version 1; it is distinct from the
  per-session `initialized.json` marker and `state.json`, which use strict version
  2. Version-1 per-session markers and state are preserved and refused; no
  implicit migration resets memory history or compactor spend. The shared marker
  describes the container, never one session. Each session's namespace is created
  lazily inside it, so a session without one, such as a new Home session after another
  session's memory set the marker, starts fresh (#483). Spend is recorded inside
  the namespace, so a surviving session whose own namespace was deleted rebuilds
  from its source and its recorded spend starts again (D5: repair, with no
  budget; #420 owns restore).
- Every open of an existing store folds replayed tails and repairs forward into
  a checkpoint before returning. While running, the owner maintains a serialized
  byte estimate as live records are inserted, replaced, or invalidated; it
  checkpoints when log bytes exceed that estimate by the internal
  superseded-record margin or cross the internal byte trigger. A small log that
  cannot meet the superseded-record margin is rejected before visiting live
  records, so ordinary small appends do not serialize or rewrite the whole store. Large invalidations contribute to the same log threshold. Once the
  pointer is durable, append logs are replaced by empty owner-only files and
  superseded checkpoint directories and recognized interrupted temp files are
  removed. Legacy JSONL logs seed this same checkpoint representation; no schema
  migration or canonical history mutation is performed.
- The version is `EPISODIC_STORE_VERSION` (2). Markers and state documents use
  strict field sets; there is no migration path. A store this owner cannot read
  is refused rather than guessed at.

## Projection (departure 1: source projection before compression)

Each canonical session entry **on the session's current branch** becomes at
most one logged message, in branch order, with a permanent index. The memory
holds only the projection, never canonical text:

| source | kind | projected text |
| --- | --- | --- |
| `message` role `user` | `user` | text parts; an image part becomes `[image: <mimeType>]` |
| `message` role `assistant` | `talk` | text parts, plus `[call <name> <JSON args>]` per tool call; thinking parts are excluded and recorded as an omission |
| `message` role `toolResult` | `echo` | `tool <name>: <content>`, capped at `CAP` characters with head and tail kept |
| `custom_message` with `display: true` | `event` | its text |
| `context_edit` | — | not a message: it replaces its target's content, or makes it `[omitted]` when the replacement is null |

Everything else — a `custom_message` with `display: false`, a system message, a
`model_change`, a `thinking_level_change`, a label, a `custom` bookkeeping entry
(for example a `tron.*` receipt), a compaction or branch summary, session info —
is not a message. A null context edit only omits an entry that held a slot in
its own right; it never invents one for a hidden custom message or a state entry.

- **No renumbering, ever.** Indices are assigned to entries in branch order and
  never reassigned. An entry the branch no longer holds (a navigation) keeps its
  index and becomes `[omitted]`; so does a projectable entry whose own text
  projects to nothing (an all-thinking reply), and a context edit with a null
  replacement. `[omitted]` is always a free node: it is never sent to a model.
- **Redaction** is the shared credential-only rule set,
  `redactCredentials` in `packages/gateway/src/util/credential-redaction.ts`:
  provider keys (`sk-`, `ghp_`, `xox…`), AWS key ids, JWTs, PEM blocks and
  bearer tokens. It is deliberately **not** the process preview's rule set
  (`redactProcessText`), which also masks every `NAME=value` and every long
  high-entropy token: the memory has to keep file paths, digests and ordinary
  identifiers readable, and `redactProcessText` composes the same helper for the
  credential shapes. A redaction is recorded as an omission.
- **Oversized text is capped at the record bound.** The recipe sends user and
  assistant text whole; a memory record must still fit its store's line, so text
  over `recordCapChars` keeps head and tail with a marker and a `capped`
  omission. The compactor then sees the capped text, exactly as it sees a capped
  tool result.
- Each message records `sourceDigest` (sha256 of the canonical entry's JSON
  line), `projectedDigest` (sha256 of the projected text), its omissions
  (`thinking`, `attachment`, `capped`, `credentials`, `context-edit`,
  `off-branch`, `empty`, `unsupported-part`), and `timestamp`: the canonical
  entry's instant. `timestamp` is optional, and absent on a record written before
  it existed: `entryTimestamp` reads the source for that one entry instead (see
  **Navigation**).

## The algorithm

The tree, the view, and the pump are the recipe's:

- **Tree** (gist §3): node `(l, i)` covers messages `[i·2^l, (i+1)·2^l)` and is
  addressed `start+n` (`start = i·2^l`, `n = 2^l`). A level-0 node summarizes one
  message; a level-`l` node merges its two children.
- **Free nodes** (gist §3): level 0 is `kind + ": " + text` when that fits
  `NODE` bytes; level > 0 is `childA + "\n" + childB` when that fits. A free node
  makes no model call and records no context, because it depends only on its own
  source.
- **The compactor** (gist §4): one call per node, no tools. It sees the current
  view's lines up to the node, bare and without ids, wrapped in `<chat>`, then
  the step (`SCALE`, the message whole, or the two lines to merge). The reply is
  trimmed; while it is over `NODE` bytes the size loop sends the line cut at the
  limit back in the same conversation, up to `TRIES` times, and the shortest try
  wins. Cutting never splits a UTF-8 character.
- **The view** (gist §5): `append(part(0, i))` then a rebalance. Departure (#491):
  the recipe fits after every message; this view does nothing while it is within
  `VIEW` bytes, and once it passes them fits down to seven eighths of `VIEW`.
  `fit` merges the adjacent built-parent pair with the largest
  `due = (T - start) / 2^(l+2)`. The oldest eligible pairs come first, near the
  view's head, so fitting after every message rewrote the start of nearly every
  request and voided its prompt cache (measured on #467). Batched, the view only
  grows at its end between two rebalances, and each rebalance leaves an eighth of
  `VIEW` for later messages. What gets merged, and in what order, is unchanged.
  Parents that are not built are passed over, so the budget is soft; parts are
  never split. The fold at load applies the same rule. An unbuilt part renders
  the recipe's placeholder for status only.
- **The pump** (gist §4.1): a node builds only when it is not built, its
  children are built, and its whole context is summarized (`end <= first(view)`).
  Up to `JOBS` build at once, and the pump refills **after each completion**, as
  the recipe does. Every published node fits the view first, so the view is the
  same sequence the durable log replays. Rule 3 is what keeps leaves in order.

## Navigation

The memory answers three navigation reads, which Home's `zoom`, `date` and
`memory_search` tools expose ([home.md](home.md)). They are the memory's own
contract: the recipe's tree addresses, and the projection, not the canonical
text.

- **`zoomLines(id, n)`** (the recipe's `zoom`, gist §7.1) returns line `id+n`
  opened into the two lines of `n/2` under it, rendered exactly as the view
  renders a line; at `n = 1` it returns the message as `id+0|kind: text` from the
  catalog's current projection. `undefined` is the answer for an address that is
  not a line of this memory: `n` not a power of two, `id % n != 0`, or
  `id + n > T`. A child whose node is not built right now renders the
  placeholder, and a revoked node's text is gone from the map, so a stale child
  cannot be served.
- **`entryTimestamp(id)`** returns the catalog record's own instant, or — for a
  record written before the optional field — the instant the canonical source
  proves for that entry id. That read is the bounded canonical reader the owner
  already uses, it is not `SessionManager`, and it covers **every parsed entry of
  the file, not only the branch the last entry follows**: a record that has since
  left the branch is still an entry the source can date. It happens at most once
  per memory and is remembered, because an entry's instant never changes —
  including across a navigation, since the map is keyed by entry id.
  `unavailable` is the source's answer that it holds no such entry, or that it
  cannot read the file at all — the memory never invents a time.
- **`searchMessages(query, from, to)`** is Tron's addition to the recipe's tools:
  one case-insensitive substring pass over the projected catalog, bounded by
  `EPISODIC_SEARCH_HITS` (20) lines whose snippets are bounded by
  `EPISODIC_SEARCH_SNIPPET_CHARS` (300) and carry the message's newlines flattened
  to spaces, exactly as a view line renders text, so one hit is one line. It
  reports the whole range's match count and its `[omitted]` and capped counts, so
  a message that holds no searchable text is named instead of silently absent; an
  `[omitted]` message is counted there and skipped, so its placeholder is never a
  hit. An empty query, or one over `EPISODIC_SEARCH_QUERY_CHARS` (200),
  is refused; omitted bounds default to the whole memory and are clamped to it.

These reads never ingest, open, or start anything: their caller does, and the
caller (`HomeMemory`) ingests the latest commits before every call so a
projection is never stale.

## Concurrency

- Ingestion, invalidation and `resume()` take one per-memory mutex
  (`packages/gateway/src/util/async-mutex.ts`), so two `entriesCommitted` calls
  cannot interleave index assignment or append a message twice. `dispose()` takes
  the same mutex before it releases the opener, so the one opener per store is
  released only once the store has no writer.
- The pump runs outside that mutex. Every build carries the generation and the
  input revisions it started from. Its final stamp check, durable append, and
  in-memory publication share the append queue with invalidation, so an edit
  cannot miss a node being published. A result whose generation changed, whose
  child was revoked or rebuilt, or whose message record was superseded is
  **discarded, never appended**.
- A node whose source is gone (no message, no children) cannot be composed. That
  is a blocked state with a reason, not a busy loop.

## Departures from the recipe, with reasons

1. **The context is sent as its cache pieces, then the step.** The recipe's user
   message has two text blocks, the context and the step. Here the context is cut
   further at the cache marks (see Prompt caching), so a long context's first
   pieces are re-read from the cache even when its end changed. The request keeps
   the whole first turn as one text, which estimates and the size loop use; only
   the default summarizer splits it into blocks.
2. **A node's context is stored as level runs, not as an address list.** The
   context is a prefix of the view, which tiles from message 0, so the parts'
   levels in order reconstruct every address exactly. At production `VIEW` the
   same 320-part context is 2,980 bytes as an address list and 50 bytes as seven
   level runs, and invalidation decodes the runs to find dependents.
3. **The view is refolded from message 0 only at load** (gist §5.2 "At load"),
   in slices that hand the event loop back every 2,000 messages. A source
   revision expands the affected parts and refits the live view instead
   (departure 4). Measured by `episodic-memory.scale.test.ts`: 10,000 messages in
   0.20 s and 100,000 in 2.5 s (every node built; the same shape as a real
   memory), with the worst synchronous slice 6.3 ms. The persisted store
   checkpoint bounds replay of catalog and node history; it does not persist the
   derived presentation view. The live view is maintained incrementally, and a
   restart refolds it from the checkpointed live nodes. The recipe's own load
   path does the same, and the cost is one cache miss, not correctness.
4. **A revoked merged part is expanded in the view.** Only level-0 parts may be
   unbuilt (gist §6), so a part whose node was invalidated is replaced by the two
   lines under it, recursively down to the leaves, and `fit` merges them again as
   their nodes are rebuilt.
5. **Invalidation carries ancestors.** A node invalidated because its recorded
   context included an invalidated node brings its own ancestors with it: a
   parent stands in for its children, so a revoked child under a live parent
   would be an inconsistent store.
6. **An invalidation is written in ancestor-first chunks**, each a compact
   durable record (base-36 node codes, at most 2,048 nodes). A crash between
   chunks can leave live context dependents of a revoked node; `open` scans for
   absent context dependencies and inconsistent child links, invalidates their
   closure durably, and only then serves the memory.
7. **A blocked memory is persisted state**, and the retries are bounded
   (below). The recipe retries forever because its next turn waits on the
   summary; here the blocked state is visible and `resume()` restarts the pump.
8. **Every stored record carries a revision**, so the latest record for an index
   or address is unambiguous after a crash.
9. **A `null` context edit and a navigation are the same `[omitted]` node**, and
   a message that projects to no text becomes `[omitted]` rather than vanishing.
   Dropping the slot would renumber every later message, and indices are
   permanent.
10. **The prompt's vocabulary and tag rule follow Tron's kinds.** The recipe's
    `COMPACT` prompt names `user`, `talk`, `tool`, `echo`, `note` and `work` and
    tags subagent reports `work:`. Tron projects four kinds (`user`, `talk`,
    `echo`, `event`) and has no separate subagent-report kind, so the prompt lists
    those four and tags each item with its source kind; the rest of the prompt is
    the recipe's text with the product renamed.
11. **A context line is flattened to one line.** The recipe's view is one line per
    part, so a summary's own newlines become spaces before the line reaches the
    prompt (the message in a leaf step is still whole, newlines kept).

## Crash window between the catalog and its invalidation

`entriesCommitted` writes the changed catalog revision first and the invalidation
chunks second, and fsyncs each before use. A crash between these steps is repaired
at `open`: live leaves are checked against their catalog record, and any leaf
whose `sourceDigest` no longer matches is invalidated. A crash during chunked
invalidation is repaired separately: before consistency validation or serving,
`open` finds live nodes whose recorded context references an absent node (or
whose child links are incomplete/stale) and invalidates those nodes and their
transitive dependents. This makes the existing node records sufficient; no
intent marker or additional retry/spend path is needed.

## Known cost of a large backlog

The view's budget is soft and `fit` can only merge pairs whose parent is built,
so a memory that ingests a large backlog in one `entriesCommitted` call holds a
view far over `VIEW` until the pump catches up, and the compactor calls in that
window carry that whole view as context, so that catch-up costs more per call.
A live
session that commits continuously stays inside the view budget, because each
commit adds one message and the pump keeps up.

## Invalidation semantics and measured cost

`entriesCommitted` compares the new projection with the stored catalog. An entry
whose text or omitted state changed is a changed leaf. The invalidation set is
then the closure of: the changed leaf and its live ancestors; every node whose
recorded context includes an invalidated node; and that node's live ancestors —
until nothing changes. The affected nodes are revoked in ancestor-first chunks,
`generation` increments, and the pump rebuilds them.

The cost is large by construction, because every summary was written with the
view as its context: an edit invalidates the lines that quoted the edited text
and everything merged above them. Measured at the moment of the edit:

| history at the edit | edit at | nodes before | nodes invalidated |
| --- | --- | --- | --- |
| 201 messages (view budget 4 KB, e2e) | index 6 | 585 | 129 |
| 1,000 messages (view budget 8 KB, scale) | index 1 | 1,994 | 1,993 |

The second row is the honest worst case: an edit at the start of a long history
invalidates essentially the whole tree. The e2e test also proves the invalidated
set is *exactly* the predicted one (computed from the durable records, chunks
unioned) and that the rebuilt leaves are exactly the invalidated leaves. A
recorded one-time control confirmed the comparison is not vacuous: an oracle
whose due weight dropped the level term (`due = T - start`) diverged from the
view at step 8 of a 300-message run. A uniform exponent shift provably cannot
diverge — `(T-s1)/2^(l1+e) > (T-s2)/2^(l2+e)` is independent of `e` — which is
why that control was removed rather than kept as a permanent test.

## Retries, spend and blocked states

- **Transient** provider failures (a thrown call, or an error the pinned
  classifier `isRetryableAssistantError` calls retryable) retry after
  `retryMs` (production 10 s, the recipe's `RETRY`) up to `maxRetries`, then the
  node blocks with `retries-exhausted`. A thrown auth or configuration error is
  classified by that same pinned classifier and blocks at once.
- An **empty reply, a refusal, or any other permanent error** blocks at once
  with `permanent-failure`. A reasoning model can spend its whole output on
  reasoning; that block's detail says so. To make it rare, each call asks a
  reasoning model for reasoning `off`, clamped by pi-ai's `clampThinkingLevel` to
  the least the model supports, so a model that cannot turn reasoning off runs at
  its lowest level. Leaving the level out is pi-ai's off: it sends the model's
  off value wherever the API can express one, but none to GitHub Copilot, where
  the provider default applies. The output ceiling (8,192 tokens) leaves room
  for that reasoning plus the line
  (#480, #485). Prefer a memory model that can turn reasoning off: one that cannot
  (DeepSeek v4.1 Flash on OpenCode Go) reasoned through the whole ceiling on long
  messages (#467). A store record the append cannot write (an oversized
  line) blocks the same way rather than stalling the cursor silently.
- **Spend** (#493) is recorded and reported, never a ceiling: there is no budget
  to inject or manage. Each call is charged the provider's own `usage.totalTokens`
  when it reports one, and otherwise every billed bucket (input, output, cache
  read, cache write). Spend is bounded by construction:
  - a node builds only when it is missing;
  - one build makes at most `TRIES` size-loop calls, each with at most
    `maxRetries + 1` attempts before the memory blocks;
  - a built node is rebuilt only after its source changed;
  - the one block a later activation resumes by itself (`retries-exhausted`)
    resumes once per activation.

  So spend grows only with the conversation and its edits, as in the recipe,
  which has no budget either. A guard on top of that could only catch a defect,
  and could misfire on legitimate edit races, so there is none.
- A canonical read failure blocks with `source-unavailable`.
- A blocked memory stops its pump, is visible in `status().blocked`, rejects
  `whenReady`, and survives a restart. `resume()` clears it, re-reads the source
  and restarts the pump; the caller must have fixed the cause (a reachable
  source, a recovered provider).

## Status query

`status()` returns the source session id, the generation, the message count, node
counts by level and kind, the view (parts, bytes, `VIEW` budget, built/unbuilt
counts, and the parts themselves up to a bounded list with a `truncatedParts`
count), coverage counters (admitted messages, summarized leaves), the pump's busy
count, the blocked state and its reason, and the tokens used. `sinceOpen`
adds the provider-reported input, output, cache-read and cache-write tokens since
the memory opened, so caching can be checked from the provider's own usage
fields (gist §8). It is not persisted.

## Prompt caching

Each compactor call puts its context block first, as the recipe says (gist §4.2,
§8): consecutive calls share that prefix.

- **Pieces:** the default summarizer sends the context cut at the recipe's marks
  (50,000, 80,000 and 100,000 characters; `cache-layout.ts`), then the step as the
  last block. Between two view rebalances, consecutive contexts only grow at
  their end, so each call re-reads every piece before its last.
- **Retention:** calls ask pi-ai for `long` cache retention (#491).
- **Anthropic:** it marks the cut pieces within the four-mark limit. Other
  providers reuse the prefix on their own.
- **Cache key:** every call carries the memory's cache key,
  `tron-episodic:<source session id>`, as pi-ai's `sessionId`. This drives
  OpenAI's `prompt_cache_key`, and the session-affinity header where a provider
  opts in, so one memory's calls reach one cache.

## Test artifacts

- `packages/gateway/test-results/episodic-memory/report.json` — the end-to-end
  run's counts, invalidation sizes, concurrency, usage accounting, oversized-record and
  blocked outcomes (`npx vitest run src/episodic`).
- `packages/gateway/test-results/home-memory-tools/report.json` — the memory
  tools' end-to-end run: the zoom children and refusals, the projected text, the
  placeholder and the rebuilt line, `[omitted]`, the search counts and bounds,
  the stopped-memory answer and the byte-identical request head
  (`npx vitest run src/sessions/home-memory-tools.e2e.test.ts`).
- `packages/gateway/test-results/episodic-memory/scale.json` — the refold
  timings and worst synchronous slice, the context-encoding sizes, and the
  1,000-message invalidation (`npm run test:scale`).
- `packages/gateway/test-results/episodic-reasoning-model/report.json` — the
  reasoning-model end-to-end cases (`npx vitest run
  src/episodic/episodic-reasoning-model.e2e.test.ts`).

## Home's use of this module

- `HomeOwner` holds one memory per Home session and reports canonical commits to
  it (`HomeMemory.noteEntriesCommitted`) from the runtime's message, custom-entry
  and navigation events. Nothing awaits that path, so a commit never blocks a
  session's lane; the memory owns what it reads and how much it spends.
- The request layer computes its cut with `cutAtEntry` (how many of the memory's
  messages are at or before the activation's start entry), starts the pump with
  `entriesIngested` — which does not wait for it — and then waits only for the
  lines it will send with `whenReady(cut)`. A request's latency therefore never
  depends on summarizing its own input.
- `renderView(cut)` is the agent-facing view (`id+n|text`, oldest first); Home
  wraps it in its attribution block. A line that `whenReady` did not cover still
  renders the placeholder, which is display state: no served request can see it.
- Home's three memory tools call `zoomLines`, `entryTimestamp` and
  `searchMessages` through `HomeMemory`, which ingests the latest commits first,
  never awaits the pump, and answers a typed result for a memory that is not
  open, not configured or stopped.
- The model is the Home record's (`home.configureMemory`); what this module
  persists about spend, blocking and its cursor is described above.

Still outside this module: any per-project compactor instructions, and the tool
surface itself — the memory answers `zoomLines`, `entryTimestamp` and
`searchMessages`, and Home owns the names, schemas, texts and bounds its model
sees ([home.md](home.md#the-memory-tools)).
