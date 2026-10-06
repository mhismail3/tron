# Episodic memory owner

`EpisodicMemory` (`packages/gateway/src/episodic/`) keeps a binary summary tree
over ONE canonical session's history: a "memory" of that session that a request
layer can read at a constant size. The algorithms are the public OptChat
recipe's (its sections are cited as `gist §N` in the code); Tron's departures
are listed below with their reasons.

Nothing calls this module from a live session yet. Wiring it to Home's commits
is a later task, so this document describes the module's own contract and not
any chat behavior.

## The owner and its inputs

- `EpisodicMemory.open` loads (or starts) the memory for one source session:
  the workspace, the source session id and its canonical JSONL path, a token
  budget, limits, and either an injected compactor or the pi-ai model and
  `ModelRuntime` the default compactor runs on. There is **no default model and
  no default budget**: both are the caller's.
- `entriesCommitted(sessionId)` re-reads the canonical file after its cursor,
  ingests what is new, and drains the pump. It awaits the drain, so a caller
  that wants the model calls off its own path simply does not await it. The
  cursor makes an unchanged file a no-op, but the read itself is the whole file
  (bounded per line): the branch is followed from the file's last complete entry
  through `parentId`, which is the correctness-first way to read a file another
  process owns. Reading only the tail would need a persisted parent chain and a
  proof that the file was neither rewritten nor truncated.
- `whenReady(cut)` resolves when every view part covering messages before `cut`
  is a built summary (gist §6). It rejects when the memory is blocked, so a
  waiter never hangs on a stopped memory. The view's budget is soft, so this is
  not a hard window check; that belongs to the request layer.
- `status()` is the bounded status query (below); `resume()` clears a blocked
  state and restarts the pump; `dispose()` aborts in-flight compactor calls and
  releases every waiter.

The owner never subscribes to a session and never opens it with
`SessionManager`. It reads the file itself, which is what makes "never repair or
migrate a canonical file" a property it can hold.

## Storage

Under the Tron internal workspace's capability state, owned the way
`KnowledgeStore` owns `state/knowledge/` (owner-only directories, created
lazily on the first write, owner-only files, secure bounded reads):

```text
state/episodic/<sourceSessionId>/
  initialized.json   # namespace-local version marker
  catalog.jsonl      # append-only projected messages
  nodes.jsonl        # append-only node records and invalidations
  state.json         # cursor, generation, blocked state
```

- Every record is written with one append and fsynced **before** it is used
  (gist §2: the recipe fsyncs every node). A record a caller has observed is
  durable.
- The catalog and node log are append-only. The latest record for a message
  index, and for a node address, wins; `revision` is a store-wide monotonic
  sequence that orders them.
- A **torn trailing line** is a write that never became durable. It is
  discarded and the file is truncated to its last complete record, because
  leaving it would let the next append concatenate onto it. The bytes discarded
  are reported through `episodic.store-recovered`.
- Any other unparsable record, a record that does not match its store's shape, a
  state document with an unknown version, or a live node whose children are
  missing or rebuilt refuses the store visibly (`invalid-store` /
  `unsafe-store`), and `episodic.store-refused` is raised. Nothing is silently
  skipped or migrated.
- The version is `EPISODIC_STORE_VERSION` (1). There is no migration path: a
  store this owner cannot read is refused rather than guessed at.

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
is not a message.

- **No renumbering, ever.** Indices are assigned to entries in branch order and
  never reassigned. An entry the branch no longer holds (a navigation) keeps its
  index and becomes `[omitted]`; so does a projectable entry whose own text
  projects to nothing (an all-thinking reply), and a context edit with a null
  replacement. `[omitted]` is always a free node: it is never sent to a model.
- **Redaction** is the Gateway's one rule set, `redact` in
  `packages/gateway/src/transport/logger.ts`, the same one the diagnostic bundle
  applies before writing text out. A redaction is recorded as an omission.
- Each message records `sourceDigest` (sha256 of the canonical entry's JSON
  line), `projectedDigest` (sha256 of the projected text), and its omissions
  (`thinking`, `attachment`, `capped`, `redacted`, `context-edit`, `off-branch`,
  `empty`, `unsupported-part`).

## The algorithm

The tree, the view, and the pump are the recipe's:

- **Tree** (gist §3): node `(l, i)` covers messages `[i·2^l, (i+1)·2^l)` and is
  addressed `start+n` (`start = i·2^l`, `n = 2^l`). A level-0 node summarizes one
  message; a level-`l` node merges its two children.
- **Free nodes** (gist §3): level 0 is `kind + ": " + text` when that fits
  `NODE` bytes; level > 0 is `childA + "\n" + childB` when that fits. A free node
  makes no model call and records no context dependencies, because it depends
  only on its own source.
- **The compactor** (gist §4): one call per node, no tools. It sees the current
  view's lines up to the node, bare and without ids, wrapped in `<chat>`, then
  the step (`SCALE`, the message whole, or the two lines to merge). The reply is
  trimmed; while it is over `NODE` bytes the size loop sends the line cut at the
  limit back in the same conversation, up to `TRIES` times, and the shortest try
  wins. Cutting never splits a UTF-8 character.
- **The view** (gist §5): `append(part(0, i))` then `fit()`. While the view is
  over `VIEW` bytes, `fit` merges the adjacent built-parent pair with the largest
  `due = (T - start) / 2^(l+2)`. Parents that are not built are passed over, so
  the budget is soft; parts are never split. An unbuilt part renders the recipe's
  placeholder for status only.
- **The pump** (gist §4.1): a node builds only when it is not built, its
  children are built, and its whole context is summarized (`end <= first(view)`).
  Up to `JOBS` build at once. Rule 3 is what keeps leaves in order.

## Departures from the recipe, with reasons

1. **A node's context is one text block, not two.** The recipe's user message has
   the context and the step as two text blocks. Here they are one block separated
   by a blank line. The prefix is byte-identical across calls either way, which is
   what a provider cache reads.
2. **`fit` runs once when the pump reaches quiescence**, not after every built
   node. The view is then a function of (message count, built node set) at that
   point instead of the order concurrent builds happened to finish in, which is
   what makes it reproducible from the durable record stream.
3. **The view is refolded from message 0 only at load** (gist §5.2 "At load").
   A source revision expands the affected parts and refits the live view
   instead (departure 4). The fold is O(messages × view parts); measured by the
   e2e test on synthetic records it takes about 0.5 s for 10,000 messages and
   about 6.4 s for 100,000 (every node built; the same shape as a real memory).
   That is why there is deliberately **no persisted view checkpoint**: a fold
   that costs seconds must not run per commit, and the live view is maintained
   incrementally instead. A restart therefore refolds the view and may produce a
   slightly coarser one than the process was maintaining; the recipe's own load
   path does the same, and the cost is one cache miss, not correctness.
4. **A revoked merged part is expanded in the view.** Only level-0 parts may be
   unbuilt (gist §6), so a part whose node was invalidated is replaced by the two
   lines under it, recursively down to the leaves, and `fit` merges them again as
   their nodes are rebuilt.
5. **Invalidation carries ancestors.** A node invalidated because its recorded
   context included an invalidated node brings its own ancestors with it: a
   parent stands in for its children, so a revoked child under a live parent
   would be an inconsistent store.
6. **The invalidate record is one durable line** listing every revoked address,
   with the generation. A crash can therefore never leave a partial revocation.
7. **A blocked memory is persisted state**, and the retries are bounded
   (below). The recipe retries forever because its next turn waits on the
   summary; here the blocked state is visible and `resume()` restarts the pump.
8. **Every stored record carries a revision**, so the latest record for an index
   or address is unambiguous after a crash.
9. **A `null` context edit and a navigation are the same `[omitted]` node**, and
   a message that projects to no text becomes `[omitted]` rather than vanishing.
   Dropping the slot would renumber every later message, and indices are
   permanent.

## Known cost of a large backlog

The view's budget is soft and `fit` can only merge pairs whose parent is built,
so a memory that ingests a large backlog in one `entriesCommitted` call holds a
view far over `VIEW` until the pump catches up, and the compactor calls in that
window carry that whole view as context. The 1,000-message measurement below is
run with a large budget for exactly this reason. A live session that commits
continuously stays inside the budget, because each commit adds one message and
the pump keeps up.

## Invalidation semantics and measured cost

`entriesCommitted` compares the new projection with the stored catalog. An entry
whose text or omitted state changed is a changed leaf. The invalidation set is
then the closure of: the changed leaf and its live ancestors; every node whose
recorded context dependencies include an invalidated node; and that node's live
ancestors — until nothing changes. The affected nodes are revoked in one durable
record, `generation` increments, and the pump rebuilds them.

The cost is large by construction, because every summary was written with the
view as its context: an edit invalidates the lines that quoted the edited text
and everything merged above them. Measured by
`src/episodic/episodic-memory.e2e.test.ts`:

| history | edit at | nodes before | nodes invalidated |
| --- | --- | --- | --- |
| 703 messages (view budget 4 KB) | index 6 | 585 | 127 |
| 1,000 messages (view budget 8 KB) | index 1 | 1,994 | 1,993 |

The second row is the honest worst case: an edit at the start of a long history
invalidates essentially the whole tree. The e2e test also proves the invalidated
set is *exactly* the predicted one (computed from the durable records) and that
the rebuilt leaves are exactly the invalidated leaves.

## Retries, budget and blocked states

- **Transient** provider failures (a thrown call, or an error the pinned
  classifier `isRetryableAssistantError` calls retryable) retry after
  `retryMs` (production 10 s, the recipe's `RETRY`) up to `maxRetries`, then the
  node blocks with `retries-exhausted`.
- An **empty reply, a refusal, or any other permanent error** blocks at once
  with `permanent-failure`.
- A **token budget** is injected. Each compactor call reserves an estimate before
  it runs and settles with the actual usage afterwards; a reservation that does
  not fit blocks with `budget-exhausted`.
- A canonical read failure blocks with `source-unavailable`.
- A blocked memory stops its pump, is visible in `status().blocked`, rejects
  `whenReady`, and survives a restart. `resume()` clears it, re-reads the source
  and restarts the pump; the caller must have fixed the cause (a larger budget, a
  reachable source, a recovered provider).

## Status query

`status()` returns the source session id, the generation, the message count, node
counts by level and kind, the view (parts, bytes, `VIEW` budget, built/unbuilt
counts, and the parts themselves up to a bounded list with a `truncatedParts`
count), coverage counters (admitted messages, summarized leaves), the pump's busy
count, the blocked state and its reason, and reserved/used tokens.

## Not wired yet

- No live session calls `entriesCommitted`; Home's commits are a later task.
- No Gateway startup path constructs an `EpisodicMemory`, so nothing supplies the
  model, the budget or the diagnostic sink, and nothing persists this module's
  records yet.
- The compactor's product prompt is fixed here; per-project instructions and the
  agent-facing view/`zoom` tools are the request layer's business.
