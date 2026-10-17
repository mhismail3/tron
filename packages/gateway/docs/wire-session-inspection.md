# Session discovery and inspection wire contract

[Gateway wire index](../README.md#transport)

Catalog identity, acquisition, attention/archive and bounded canonical inspection. Shared [pagination admission](wire-transport.md#paginated-read-admission) covers session and model reads. [Session execution](wire-session-execution.md) owns active input and operations; [Knowledge](knowledge.md) owns observation publication and recovery.

Command and plain-text source paths retain their original repository/Gateway-root context; Markdown links are document-relative.

## Catalog summaries and activity

`session.summary` is a bounded, per-session revisioned global projection
of aggregate phase, narrow foreground phase, active-subagent presence, pending-user-input state, name, activity time, message count, and first-message title. Full catalog rows additionally project immutable Automation creation identity only when the first canonical user entry is bound to a Gateway-boundary Automation invocation receipt; live generated sessions carry the same identity from their exact execution lease until persistence, while cold catalogs rederive it from JSONL without consulting or mirroring the Automation store. Fork headers take precedence and do not inherit this creation marker. Pi's pre-append `message_end` boundary invalidates cached canonical row facts and schedules their post-append publication, so a new session exposes its first-prompt title while the initial response is still running rather than waiting for a Gateway restart. First-message titles strip exact machine-authored skill envelopes and slash invocation tokens, preferring the user's arguments and otherwise a readable resource name; malformed envelopes remain literal rather than risking content loss. Cold catalog and live summary recency share the canonical user/assistant message-time boundary; settings, names, and extension metadata appends do not change that boundary. Live activity time overlays it with foreground agent events, detached extension lifecycle timestamps, and a ten-second heartbeat while either remains active; session open/close, idle lifecycle events, and rereading an old terminal artifact do not advance recency, so merely viewing a settled session cannot reorder history. Administrative receipt persistence does not make a row active. When detached subagents outlive the parent response, aggregate `phase` remains active while `foregroundPhase` is settled and `hasActiveSubagents` remains true, allowing shallow dashboard clients to present delegated work without opening the transcript. `waitingForUser` is orthogonal to those phases and transitions immediately with the first pending semantic interaction and final settlement, so dashboards can identify that only a user response can advance the session. The additive `activeSince` fact is fixed for one continuous Gateway-observed active period, so catalog ordering keeps active rows first and stable while `updatedAt` continues to advance for truthful freshness labels. Settled history remains reverse chronological by parsed instant rather than ISO text precision, and Gateway restart naturally falls back to canonical message time (header time only when there is no qualifying message). Focused `runtime-registry.integration.test.ts` regressions cover cold opens preserving settled recency, user search admission during parallel child appends, isolation of an unfinished child tail, and a list, a cold open and a hot re-acquire resolved from the owner's rows without a walk. Summary updates reach every connected
dashboard immediately without broadcasting full transcripts or changing the structural list revision. User-scoped catalog admission compares only non-delegated index rows, so a concurrent child-session write cannot make an unchanged dashboard fail `session.list`; the index's whole-folder rows still quarantine duplicate IDs, including a user ID claimed by a delegated file. Catalog folder enumeration uses bounded concurrency of 16 while retaining canonical-folder and inode checks and all traversal/materialization budgets. Results are path-ordered so filesystem enumeration order cannot change discovery output. All-scope reads serve the same rows without a second scan. The Gateway-owned catalog index is the request path's membership source: unchanged and append-only rows are kept with the same inode, header, newline, and tail-boundary checks using bounded parallel filesystem work, and a file this process cannot prove refuses retryably rather than weakening authority. Catalog `messageCount` counts visible conversation rows, excluding Pi 0.87 `system` transcript deltas that carry provider context but are not chat rows. Index version 3 invalidates the disposable version-2 catalog cache and rebuilds counts from canonical JSONL on demand; no canonical session migration is needed.

## Fork boundaries and tree identity

Forked transcript projections carry an optional, disposable `forkBoundary` annotation. At runtime bind/rebind and tree navigation, Gateway validates the selected child's contiguous inherited identity/ancestry against the catalog-admitted immediate parent's complete canonical tree. It retains only one inherited-entry anchor, not a transcript mirror; snapshots map that anchor onto the current branch without parent I/O, including after the first child append. Read-only subagent pages derive the anchor from their admitted parent runtime and include the projected annotation in their revision. Regenerated labels are normalized out of ancestry; sanitized/pruned payloads with preserved identities remain inherited. Missing, ambiguous, cyclic, replaced or oversized parents omit the annotation without blocking chat. A header-only relationship or a fork with no retained context cannot establish a marker. Parent reads are inode-fenced and capped at 64 MiB; derived graph scans are linear and capped at 100,000 entries. The annotation carries the stable inherited anchor ID plus its gap ordinal (0...total) in the canonical projected sequence, so inherited-only and hidden-only branches still have a boundary and later child appends cannot move it. It does not change canonical IDs, counts, or paging anchors. iOS owns the gap insertion before visibility folding, including the true canonical tail before streaming, and flushes tool grouping; page ownership is one-sided so adjacent pages cannot duplicate it. focused runtime-registry fork regressions (`runtime-registry.integration.test.ts`) cover ancestry, the actual SDK fork behavior, reopen, wire propagation and paging. Hidden-tail and rendering checks have no remaining journey.

Tree projection validates every
canonical entry discriminant and required payload before selecting its bounded newest candidates;
content and blob registration are performed only for admitted candidates.

## Canonical catalog identity, acquisition and recovery

Pi's configured `sessionDir`, or its
canonical per-workspace directories under `agentDir/sessions`, remain authoritative; Tron does
not move or mirror those files. `session.list` defaults to user sessions, while `scope: "all"`
additively includes delegated children through one positive pi-subagents topology contract. The
only delegated identities are canonical JSONL files at exactly
`<canonical-parent-stem>/forks/<fork-session>.jsonl` or
`<canonical-parent-stem>/<producer>/run-N/session.jsonl` inside the canonical catalog. Extra path
components and alternate basenames are not delegated topology. This reservation is authoritative even when the parent file was deleted or its embedded ID
is ambiguous. An optional header may bind `parentSessionId` only when it names the exact parent path
derived from topology. A contradictory header remains mutation-protected but fails closed and is
omitted rather than becoming a user row. The same classifier owns list, acquisition/open, and delete
decisions. Ordinary top-level forks—including parented, unnamed snapshots and names beginning with
`subagent-`—remain user sessions, as do arbitrary deep files outside the two reserved producer shapes.
No session name/title, `session_info`, transcript text, timestamp ordering, generic directory depth,
or transcript-tail read participates in classification or structural evidence. Existing top-level
files created by older subagent producers have no runtime compatibility inference and require
explicit pre-deployment disposition. They are not silently migrated or deleted. The Gateway does not
rename, delete, or otherwise mutate `~/.pi` as part of that disposition. If more than
one canonical file claims the same embedded session ID, the Gateway omits every ambiguous copy
and rejects open/delete by that ID until the duplicate is repaired; traversal order never chooses
canonical ownership. A newly created session has no canonical Pi JSONL until Pi records its first
assistant content; a retained user-only fork is deferred by the same pinned persistence policy. While the
Gateway owns that bounded live runtime slot, `session.list` projects one runtime-only empty user row with
its stable slot-creation time, cwd, phase, and revisioned summary fields. A fresh fork whose retained branch
has not produced an assistant entry additionally projects the exact pre-fork
session ID as `parentSessionId`, so dashboards classify it immediately without inferring from paths or
fabricating a row. If the new JSONL joins a warmed structural cut before its normalized parent alias, that
same mutation-owned ID bridges only the live transition; cold catalogs derive the relationship from canonical
header/path evidence. That row is visible to every connected dashboard and remains directly openable/deletable,
but it is not a second session store: idle slot retirement or Gateway restart removes it if Pi never persisted
content. Once Pi creates JSONL, the canonical row replaces the runtime-only projection under the same ID
without duplication.
Before materialization, recursive discovery streams at most 50,001 directory entries,
retains at most 25,001 canonical directories/8 MiB of traversal paths, and admits at most 25,000 session
records/8 MiB of retained metadata; overflow fails retryably without publishing a partial catalog. Cold scans, live summaries, and appended metadata cap session names and first-message previews at 1,024 UTF-8 bytes, including the truncation marker, without splitting code points or modifying canonical JSONL. Oversized cached preview/name rows are discarded and rebuilt from canonical metadata; they cannot bypass the bound after restart. The pinned
Gateway performs its own bounded direct-directory JSONL metadata scan for catalog rows, so catalog discovery does not construct the SDK's unused transcript-wide picker search text. Cold scans and cached metadata appends share `catalog-jsonl.ts`: raw lines are bounded to 64 MiB before UTF-8 decoding, above the default maximum admitted prompt including uploads and below V8's string ceiling. An oversized row leaves its metadata unproven, emits `catalog-index.failure` with `step=line-limit`, and never enters an unbounded readline callback. Canonical JSONL is untouched; repairing the file permits the next scan to recover. `catalog-jsonl.integration.test.ts` exercises both filesystem readers, UTF-8/chunk/CRLF boundaries and repair. One owner, `session-catalog.ts`, holds the index of every canonical row and is every reader's membership source: `session.list`, a cold open, attention resolution, automation admission, workspace lookup and storage maintenance read its rows, so no request walks the session folder. The owner keeps the index current from the Gateway's own commit points, the recursive folder watcher, and a whole-folder reconcile every `CATALOG_RECONCILE_INTERVAL_MS` (30 minutes) that is the backstop for a dropped event or a stopped watcher; its passes run in bounded batches that yield to the background-work scheduler between them. A user-scoped read filters those same rows by each row's own delegated flag, and duplicate identities are quarantined from the whole index, so a concurrent child write cannot make an unchanged dashboard fail `session.list` and an ambiguous user ID never resolves to one of its files. The durable `gateway/catalog-metadata-v2.json` document is the owner's acceleration only — bounded identity/classification metadata, file identity, size/mtime/EOF and a tail-boundary hash, never transcript text — and only the owner writes it, debounced. JSONL remains authoritative: a missing, corrupt or foreign-root document leaves the index to rebuild every row from canonical files, and a pass that cannot prove a file keeps the row it already had and refuses retryably (`catalog_not_ready`) instead of answering membership from a cut that might be wrong. Live-only slots and revisioned summaries are overlaid on the rows per projection generation, so heartbeats never rebuild catalog metadata. Canonical path normalization runs with at most 16 concurrent filesystem operations.

Each complete discovery cut carries the canonical realpath root it actually traversed;
the owner classifies every row against that root, and a later cut resolves the configured
alias again. Startup binds durable-index load and classification to one resolved root.
The published root also binds incremental row refreshes and durable writes; an out-of-root
hint requires a complete traversal rather than mixing roots. Alias-form file hints pin
their physical path through absence checks and metadata rebuilds, so a later retarget
cannot redirect either read. Acquisition reuses the owner's published delegated role
and joins parent IDs only against current unambiguous rows, rather than reclassifying a
canonical path under a different alias.

The folder watcher attaches to the canonical realpath root, including when the configured
root traverses a filesystem alias (such as macOS `/var` and `/private/var`). File hints
within the published root advance only the named row without a catalog walk;
directory hints re-read the folder's
transcripts, and unnamed hints request a debounced reconciliation. The event debounce
ceiling bounds delay **after a hint arrives**, not operating-system delivery latency or
reliability. Focused catalog and registry regressions inject `SessionCatalogWatchRequest`
hints and advance the owned debounce deterministically. Real-backend coverage checks
canonical-root attachment and canonical row repair, with reconciliation as the backstop;
it does not impose an FSEvents delivery deadline.

`RuntimeRegistry` derives membership from the index rows, not a second catalog: `catalogAcquisition` projects canonical ID/path/cwd, the structural user-versus-subagent classification and the ambiguous-ID set from the owner's rows, with no filesystem read of its own. The index is authoritative for cold open, attention resolution, automation admission, workspace lookup and delete. A Gateway-owned change reaches a row at its commit point but asynchronously, so a read that finds no row for a named session waits for the owner's queued changes and re-resolves before it may answer `not_found`; an ID the owner read a header for but could not prove refuses retryably. Ordinary message/tool appends do not change membership. Additions, removals, aliases, duplicate identities, or same-path header identity replacement do. Live-slot admission (`acquire`, `retainLiveSession`, and the attention fast path), the attention commit, and a cold start that finds a slot published during its own admission gap all read the owner's current duplicate set; the registry keeps no projection of it, so a duplicate indexed after a slot started refuses `conflict` without waiting for a catalog read. A malformed file under the reserved `subagent-artifacts` diagnostic subtree is ignored as a non-session artifact and cannot poison the cut. Malformed files in canonical session locations still fail closed. An unfinished delegated append therefore cannot force unrelated cold opens into discovery or prevent a user dashboard from serving its rows. The selected cold file is checked before SDK open, which can repair incomplete tails; an unfinished selected file fails retryably without being rewritten. Changing, replaced, symlinked, duplicate, or header-rewritten files remain strict; append-only tail growth of the exact inode currently owned by a live RuntimeSlot remains permitted. Directories named `*.jsonl` are not file candidates.

The exact opened manager must still reproduce the admitted ID and canonical cwd, and the fence reads only the target: the index must still claim this exact file, and that file's own stat and header must still be the ones the index admitted, so no request walks the tree. Changes reject retryably, while the unavoidable cross-process race after that final validation point is not presented as eliminated. The owner's whole-folder scan reads canonical session headers with 512-byte first reads, runs in deterministic batches of at most 16 files, permits at most 64 KiB per candidate with a strict shared 64 MiB aggregate budget apportioned across the candidate set, and inserts at most 25,000 identities/4 MiB into the index. It reads only the canonical session header; later `session_info` and transcript appends do not change the structural identity. Gateway-owned mutations are generation-checked across an admission, so a catalog change that lands during one refuses retryably instead of committing stale membership. Mutable summary/attention overlays are captured per projection generation after the rows, so heartbeats cannot starve a list projection. Delete resolves membership from the index and re-proves the exact path, inode and user classification immediately before inode-safe quarantine, so a new parent file, duplicate ID, or topology change cannot commit stale deletion. A cut that cannot prove a file refuses retryably instead of publishing stale evidence. Same-session cold opens share one startup, while distinct session starts reserve capacity atomically and perform manager/runtime initialization outside the registry-global publication mutex. Creation uses the same short reservation boundary, so one slow project resource loader cannot serialize unrelated starts. Administrative drain and shutdown wait for already-admitted starts before snapshotting runtime ownership. Thus idle resume normally avoids a transcript-wide catalog parse while JSONL and the pinned manager remain canonical. Startup binds the HTTP listener before RuntimeRegistry recovery begins. RuntimeRegistry loads the bounded durable attention/marker inputs while health remains `starting`, waits for the catalog owner's first reconcile pass (`catalog-warming`), then reconciles attention and interrupted markers from that same cut (`attention-recovery`); blob storage follows as `storage-warming`. Home task recovery runs after the listener is serving, following attention recovery; until it settles `home.status.taskRecovery` reports `not-started` and task work is refused, and it does not gate `ok`. Storage warming loads durable stores without materializing the presentation catalog or treating an unavailable catalog as an empty membership set. Periodic attachment/display-artifact maintenance derives retention membership from the owner's reconciled cut plus live runtime slots, and never materializes transcript summaries. Ambiguous IDs still retain their artifacts; an unreconciled or incomplete cut refuses retryably instead of collecting orphans. Pending Knowledge observation recovery resolves membership from the owner's reconciled cut, rejects duplicate IDs, and re-reads and re-proves the row's exact file identity and manager header; incomplete or changed evidence leaves durable cuts pending instead of inventing a missing session. It does not start an agent runtime. Large previews or catalog presentation failures therefore cannot block storage initialization; canonical acquisition, catalog bounds, and artifact authorization remain enforced. Focused regressions in `runtime-registry.integration.test.ts` cover cold scans, UTF-8 boundaries, cached/append metadata, storage readiness, and retained artifacts. Only after all startup phases succeed does GatewayServer publish `ok`. Catalog validation, SDK materialization, target manager open, runtime creation, attention resolution/persistence, and startup attention reconciliation are separately timed with privacy-safe stage records; they report only method/stage, outcome, and duration and never log IDs, paths, prompts, or parameters. Runtime snapshots reuse exact statistics/context and latest-cache derivation for an unchanged runtime revision, then invalidate naturally at canonical event, branch, compaction, or rebind revisions.

## Cold opening and catalog pagination

Interactive cold opening has one remaining dependency boundary: pinned `@earendil-works/pi-coding-agent` `SessionManager.open()` synchronously parses and retains the complete JSONL before runtime construction. Gateway deliberately does not bypass that owner with a transcript mirror, private-field hydration, or a `node_modules` patch. History-length-independent opening requires an upstream public SDK seam that opens asynchronously through one validated descriptor, restores the current leaf and active context from a compaction checkpoint plus indexed suffix, exposes seekable canonical transcript/tree reads, and invalidates disposable offsets on inode/size/mtime/boundary disagreement while preserving the existing canonical append/migration semantics. Until that seam ships in a pinned dependency, listener/catalog readiness is bounded as documented above, but a first cold open can still scale with the selected file's complete history.

Every session-list traversal is one
immutable, disposable catalog materialization: every page carries the same structural `listRevision`, and its authenticated opaque cursor
is bound to the connection, scope, materialization, offset, and revision. RuntimeRegistry supplies a disposable page-source generation for indexed catalog cuts; the pagination store leases that source and hydrates requested pages, while preserving the older full `catalog()` API for internal snapshot owners. Single-page results are not retained as generations. A Gateway-owned `gateway/catalog-metadata-v2.json` acceleration file may persist only bounded identity/summary metadata (including receipt-derived Automation creation identity), canonical file identity, size/mtime/EOF, and a fixed tail-boundary hash. It is versioned and root-bound, written through a 0600 temp-file/fsync/rename/directory-fsync transaction, and is discarded on any schema/root/inode/size/mtime/boundary mismatch. The catalog owner is its only writer: it persists its own cut, debounced, and a catalog read never writes it, so a row a read projected cannot reach the document with a count or a size its file no longer has. Disposal settles the admitted write and refuses later ones: no temp file or rename may land in the Gateway state directory after its owner reports shutdown. JSONL remains authoritative and persistence failure degrades to the canonical in-memory projection. The current query builds one bounded compact seed source, sorts it once, and hydrates only the requested offset page; canonical JSONL remains authoritative and true keyset indexing remains a later phase. Traversal
leases expire after 30 seconds, are released on disconnect, and are bounded by
per-client lease quotas plus per-lease/global row and encoded-byte limits with LRU eviction. Runtime `session.summary` revisions remain independent, so activity heartbeats
and ordinary row updates neither rescan nor tear catalog pagination; a later traversal
observes newer canonical truth. Both full scans and reconciled durable-index cuts
publish membership through the same structural revision owner, including the first
cut after restart. Additions and removals advance `listRevision`; unchanged cuts
reuse it, and already-leased traversals keep their original rows and revision.
An uncursored `session.list` may name the client's retained projection token:
an equal token is answered with `notModified: true` and no rows. The token is the
Gateway runtime epoch plus the page-source generation, so it covers structural
identity, archive membership, the visible archived count and every mutable row
overlay — a live summary, a cold row's attention projection and archive state
each move it. A first-party client may therefore revalidate a retained token on
any connection, including a replacement one, and still holds that exact
projection. The epoch is per Gateway process, so a restarted Gateway whose
revisions begin again at zero can never confirm a pre-restart token rows do not
match. Any other token, a cursored page that received one, or an absent
parameter receives ordinary rows; a cursor traversal already belongs to the
projection its first page admitted.
Clients still fail closed and restart from a nil cursor
when interoperating with an older Gateway that changes revisions between pages.

## Cross-client read attention

Cross-client read attention is narrow Gateway-owned metadata, not transcript or
catalog mirroring. Membership is resolved from the catalog owner's rows outside the serialized attention lane. The commit boundary rechecks deletion and generation and re-proves the index's exact row for the selected file — its path, inode and header — so a request reads only that target file and no transcript metadata materialization occurs beneath the lane. A bounded atomic `gateway/session-attention.json` document
stores only completion/read-through revisions, a manual-unread flag, a bounded
recent-completion deduplication set, and a restart-reconciliation cursor. The listener
becomes ready before canonical attention recovery opens session transcripts; run markers
remain authoritative during this post-listener recovery window. Only an accepted prompt
turn's canonical assistant entry ending with Pi `stop` or `length`
at truthful agent settlement advances completion; generic idle, compaction,
abort/error/deferred output, runtime close, and intermediate tool-use messages do
not. A private per-session marker document retains at most 16 accepted operation
records and their exact canonical completion stamps using synced file-and-directory
replacement; a full document rejects newer admission rather than dropping evidence.
Legacy v1 single-operation markers migrate on mutation without inferring an unstamped
completion. Marker creation and exact stamping run independently of serialized
attention admission, so a failing older projection cannot hide a completed extension
continuation. Assistant `message_end` captures its operation owner in the
callback turn before Pi's synchronous canonical append; an extension continuation
that starts inside the append/microtask gap therefore rotates to a distinct owner
instead of inheriting the completed turn. Terminal stamping atomically reasserts
that exact owner with completion evidence in one per-session marker transaction,
so overlapping turn cleanup cannot erase newer work. A conflicting completion
claim for an already-stamped operation is permanent and fails immediately while
ordinary storage failures retain durable retry, preventing that impossible claim from indefinitely
blocking later prompts, `session.open`, or administrative drain. Cleanup remains
scoped to that operation ID. Open/drain
joins live settlement; after restart, bounded recovery resolves each exact
`assistantCompletionId` from ordered durable marker stamps against its canonical
JSONL entry. It never substitutes another completion or infers unstamped or
temporal completion before advancing its cursor. Catalog rows and
revisioned `session.summary` events project
`completionRevision`, `attentionRevision`, and `isUnread` without changing
structural `listRevision`. `session.attention.set` uses ordinary command receipts and returns the complete
monotonic attention projection; when a cold row has no retained live summary,
Gateway emits a list invalidation rather than fabricating a summary event.
Mark-read carries the exact rendered completion revision so a racing newer
completion stays unread. A live completion whose shared disposition observes an
active mobile presentation advances completion and read-through together in one
durable attention replacement, clears manual unread, and publishes no transient
unread summary. A Home task worker ends through its `report` tool call, never a
successful final reply, so a settled task records one completion (`task:<taskId>`)
for its worker session, admitted read: its result reports back to Home, so only
sessions the maintainer starts himself join the Unread queue on completion (#1003).
Every completion of a recorded worker (a resumed task reuses its session, and any
later assistant reply in it) is admitted read the same way, while an explicit
mark-unread still holds. Recording a worker in the index also acknowledges its
earlier completions, so the startup seeding pass clears unread left by builds
before this rule and completions recovered at startup before the index existed;
a failed acknowledgement logs `home-worker-attention-failed` and is retried by
the next startup. Catalog rows of a Home task's worker carry `homeTaskId`: RuntimeRegistry
holds a worker-session index the task dispatcher seeds from its startup recovery
pass over the ledger and extends on each bind, each change invalidating catalogs
once, so clients learn which sessions are Home workers from the list they already
sync rather than by reading `home.taskList`. Successful `session.open` returns its current completion revision,
and first-party clients acknowledge it only after installing the snapshot and
retry transient acknowledgement failure against that same absolute revision.
Protocol-v7 clients require the complete attention and presentation contract;
they do not attach to an earlier Gateway that lacks the method or revisioned
response.
Delete removes attention metadata, true identity replacement moves it without
overwriting a target, switches preserve both identities, and new/imported/forked
sessions begin read.

## Archive visibility

`session.archive.set` archives or unarchives one canonical session under an
ordinary command receipt and returns `{ archived, archivedAt? }`. Archiving is a
Gateway-owned display projection in a separate durable store
(`session-archive.json` under the Gateway home): it never rewrites the session
file, changes that file's `updatedAt`, or starts a runtime for an inactive
session. Admission reuses delete's hardened structural identity check, so an
unambiguous canonical session is required, a runtime-owned subagent session is
rejected with `conflict`, a session whose deletion has begun is retryable
`busy`, and archiving requires an idle session: running, compacting, retrying,
waiting-for-input, detached-subagent, queued-prompt, automation-reserved and
leased states all reject with `busy` (`session_operation_busy`); a session whose
only blocker is another request's work entry or an in-flight export rejects as
retryable `busy` instead, because that clears by itself. For a live runtime the
idle check and the durable commit are one slot-lane critical section, so a run
and its archive decision are serialized: whichever reaches the lane first
decides, a run already inside the lane rejects the archive, and a committed
archive clears itself before any run can start. A long lane holder that the
published projection cannot see (a branch summary, Bash before its phase lands,
a reload) is rejected under the registry mutex before that wait, so archive
admission never holds the Gateway-wide mutex for another operation's duration.
That lane cannot cover a turn Pi starts on its own, so after the commit the
registry rechecks the live projection and restores visibility if such a run is
already working. The session lane
nests the display-projection lane inside the registry mutex
(registry mutex -> session lane -> attention/archive lane), and no path holds a
display-projecting lane while waiting for a session lane or a registry mutex.
A replay returns the original receipt, and archiving an
already-archived session keeps its original timestamp; a session whose earlier
clear is still retrying gets a fresh timestamp, because that stale record is
retired first rather than resurrected. Archive state advances the list revision
and emits `session.listChanged`; it moves with a true identity replacement,
leaves a new or forked identity unarchived, is removed with a discarded identity
and with session deletion, and is pruned at startup only from complete
structural evidence plus live ownership, so a session that was created or opened
before recovery finished keeps its record.

An archived session is always idle, and every new run clears the record before
the run can do any work. Gateway-admitted work (`session.prompt`, including
automation and scheduled prompts, `session.bash`, `session.compact`, and a
branch summary from `session.navigate`) clears it on the same session-lane turn
that admits the run, after every synchronous rejection; a store failure rejects
the run retryably so no work can start hidden. A turn Pi starts on its own (an
extension's `triggerTurn`, a scheduled wake) never passes that boundary: when a
slot publishes an active projection for an archived session, the row becomes
visible immediately — that membership change reaches clients then, not when the
durable clear lands — and the durable record is cleared behind it, retrying on
the next published summary for that session if that write fails. Gateway
disposal settles that in-flight clear before the state directory is released,
so a late write can never land after shutdown. Both paths log
`sessions.archive.auto-unarchived` with the boundary that cleared the record.
Opening, reading, renaming, marking read or unread, exporting, or searching an
archived session leaves it archived. A live session's snapshot carries the same
projection: `archivedAt` is present while the session is archived and absent
while it is visible, and a committed archive change republishes the owning
slot's snapshot, so an already-open client sees the transition without
reopening the session.

`session.list` accepts an optional `archived` filter. `exclude`, the default,
drops archived rows from every page of that traversal and returns
`archivedCount` on its first page only; `only` lists the archived rows,
newest-archived first. Archived rows carry `archivedAt` and are otherwise
unchanged, and a list cursor is bound to the filter that created it. The
`session-archive.v1` capability advertises the method and the filter; the
additive field and parameter required no protocol version change.

## Transcript, context, tree and resources

`session.open` carries a
byte-bounded authoritative transcript tail with `transcriptStart` and
`transcriptTotal`; `session.transcript` pages backward through the same canonical
Pi branch without enlarging the WebSocket frame limit. Snapshot tails and pages are
bounded by both encoded bytes and 512 items. Page responses carry exact `start`, `end`,
and `total` bounds; `end - start` always equals the returned item count, so generic JSON
projection cannot silently truncate a tiny-item page. Paging is a bounded read for an
already-open presentation and never creates or revives event-subscription ownership.
Live tool arguments,
structured current results, and readable output are independently projected to
bounded previews; current output updates the existing chip/detail view in place
rather than creating transcript rows. Exact timing is retained for the current
owning runtime using a monotonic start-to-end measurement and projected onto settled
results; older Pi JSONL entries, which do not persist execution timing, use the
canonical call-to-result interval as an observed fallback. Completed results leave the live overlay as soon as their
canonical transcript entry exists. A final snapshot fitter removes duplicate terminal
detail and compacts running payloads before canonical rows. Every legal fitted snapshot
retains at least the newest 24 display-bearing canonical transcript entries when that continuity floor can
fit; an individually oversized item is compacted before rows are removed. iOS preserves a
compatible recent continuity suffix—and any explicitly loaded earlier pages—while installing
an overlapping authoritative tail. Phase, operation,
tool identity/order, and canonical paging cursors remain authoritative. Arbitrarily
large active runs therefore remain openable; no canonical Pi content is modified or
discarded. Canonical non-image upload
envelopes retain their runtime-owned readable paths, but the mobile transcript
projection replaces those tags with bounded name/type/size metadata on an
ordinary text part and never sends the Mac path to clients. Protocol-v7 clients therefore receive the safe filename instead of the
Mac path for a new content discriminant. A page carries and echoes the next projected entry as its branch anchor plus the current runtime
generation and leaf identity. Raw canonical parent links may pass through filtered session-info,
hidden custom, or extension-receipt entries and therefore never define projected-row adjacency.
Requests may supply all three expected identities; the
Gateway fails retryably if runtime replacement or tree navigation changed any boundary
while the request was in flight. Oversized responses return
a correlated protocol error instead of disconnecting the device. `session.context`
and `session.resources` return runtime-native resource projections. `session.context`
also carries `instructions` (`src/sessions/agent-instructions.ts`): the exact system
prompt the model receives for a turn, split into Pi's sections plus the per-turn
Tron operating context, with each section, tool line, rule, skill, and instruction file
attributed to Pi, a Tron module, a package, a local file, or an MCP connection. Pi does
not expose its section map, so the Gateway splits the rendered text; file-backed
bodies are matched exactly, every byte stays in one section, and a prompt without Pi's
structure is returned verbatim as one `prompt` section. The additive field
required no protocol version change; `systemPrompt` remains Pi's base prompt. The resource
projection includes display-safe extension, prompt, skill, context-file, and tool
metadata while canonical resource files and runtime loaders remain authoritative.
Extension entries also expose the public loader handler event names and bounded
registration counts, plus scope/source/origin and separate load errors; callback
functions are never serialized. One aggregate encoded-byte envelope reserves
extension identity rows before optional tools, commands, handlers, and load errors.
An impossible identity is omitted without hiding later rows. Incremental exact
item-byte accounting avoids repeatedly serializing the growing envelope; retained
and omitted row/handler/error counts describe the returned projection. The hook inventory reports retained/omitted
extension, handler-event, load-error, and long-metadata counts that exactly
describe the returned rows rather than a separately budgeted addition.
This is a current runtime registration view, not execution history or health.
Every tool, skill, prompt and command row also carries a `distribution` tag
(`external`, `module` or `local`, absent for Pi built-ins) derived from Pi's
`sourceInfo` by one Gateway rule: a `package` origin is external, an `inline`
source is a Tron module, and a `top-level` `local`/`auto`/`cli` source is local.
It is a separate key from Pi's `origin`, which keeps its `package`/`top-level`
meaning. The same response lists available subagents (`name`, `description`,
`model`, `thinking`, `source`, `distribution`) using the installed `pi-subagents`
Tron-reserved package's own discovery, loaded through its bundled `jiti` dependency from the same receipt-verified root as extension admission. Subagent
discovery spawns nothing, is capped at 128 rows, is never cached across calls,
and fails soft to an empty list plus one bounded `subagentDiagnostics` string
when the package is absent, cannot load, or exposes an unexpected shape.
The provider's own `agentDiagnostics` report is also projected into that existing
string (at most 512 characters, count plus the first error), without discarding
healthy catalog rows or revalidating definitions in Tron. Settings already
presents it in the Subagents Diagnostics row. A count-only
`pi-subagents.agent-definition-invalid` warning is emitted once per successful
runtime load/reload or session-free extension load, never on resources reads.
Repairing a definition clears the next discovery result; validity is not cached.
`session.tree` returns the existing newest-first-selected, chronologically restored
flat outline of at most 1,000 nodes and 700 KiB with depth, child-count, role, and
current-path metadata; it never recursively serializes an unbounded canonical tree.
Every source node, parent link, timestamp, label, child list, and canonical entry ID is
validated before selection. Content and image blobs are projected only for admitted newest
candidates, so omitted images do not consume BlobStore capacity. The projection rejects
duplicate or malformed canonical entries and oversized retained metadata strings. Producer-authored
compaction and branch summaries may exceed one tree field because Pi owns their canonical context;
`session.tree` validates their shape and emits only the existing 240-character bounded preview.
Omitted older parents are valid because the bounded outline is not a canonical mirror.

## Canonical history pages

The mobile Session History feed instead uses `session.history.list` and `session.history.entry`
(capability `session-history-pages.v1`). Both require a subscribed canonical session and exact
`runtimeGeneration`; replacement rejects the read rather than silently changing its authority.
List pages contain at most 100 previews in reverse canonical append order, including all branches and
log/bookmark entries. Timestamps are metadata, not ordering keys. Older/newer cursors anchor an exclusive
ordinal **and** canonical entry ID; appends preserve their position, while changed anchors fail retryably.
There is no recent-entry completeness cap, pagination store, alternate journal, or eager body projection.
The SDK still owns the full loaded entry set; each page scans its metadata for child/current-path facts,
so Gateway CPU remains history-length dependent. Retained node metadata must fit 600,000 encoded bytes
and pathological identifier/label fields fail explicitly rather than receiving ambiguous truncated IDs.

Entry reads take `entryId` and a UTF-16 `offset`, return at most 24,000 UTF-16 units plus total length and
previous/next offsets, and never split a surrogate pair. Only the selected entry is inspected. Text blocks
are sampled without allocating another joined full message; structured tool/custom payloads are serialized
only on explicit detail reads (their temporary serialization still scales with the selected payload).
The separate metadata object contains bounded scalar identity/role/model/tool/branch facts and finite
usage counters, not arbitrary tool arguments, extension payloads, or image bytes. Oversized scalar metadata
is explicitly marked with `<field>Truncated`; content paging does not discard authored text. Images are
identified without turning base64 into message text. Pi 0.87 context-edit entries are retained as
`contextEdit` history evidence (target and replacement) but do not fabricate a chat row; system-message
entries are retained as `systemMessage` history evidence and likewise stay out of the chat transcript.
Pi's model-attributed `usage` entries (cache warming) stay canonical JSONL without a chat row or an outline
node, and the history feed publishes them under their own declared `usage` kind with a `Cache warmed`
preview: the feed is a contiguous canonical window, so every entry in an ordinal span keeps a row and the
older/newer cursors still name its boundary nodes. The iOS tree-kind field is an open string so these additive kinds decode without protocol-version changes.
Complete raw producer metadata/media remain in the canonical JSONL export. The focused runtime registry
integration case protects beyond-cap traversal, ordering, text/wire bounds, Unicode, subscription admission
and runtime fencing. Using these APIs requires a user-initiated Mac Gateway update; source validation never
transitions a running Gateway.
