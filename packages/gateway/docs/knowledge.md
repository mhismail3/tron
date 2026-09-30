# Knowledge owner

`KnowledgeStore` is the single canonical Knowledge owner for a resolved
`TronWorkspace` on the Gateway. Construction and presentation reads do not
initialize or migrate storage. A first deliberate mutation creates this
owner-only namespace:

```text
state/knowledge/
  initialized.json                     # namespace-local integrity marker
  state.json                           # small storage-version/catalog-ID manifest
  catalog-<id>.sqlite                   # canonical transactional catalog
  records/<record-id>/<revision-id>.json # immutable record revisions
  objects/<sha256>                      # immutable raw content-addressed bytes
```

The workspace-owned `gateway/workspace-state/initialized.json` also records
initialization. Deleting an established namespace, manifest, or active catalog
reports unavailable/lost state rather than creating an empty corpus.

`KnowledgeCatalog` uses Node's built-in SQLite, not a new dependency or a session
mirror. Catalog rows own record heads, exact revision ownership, normalized
lexical search fields, coverage, exclusions, receipts, and
cleanup intentions. Immutable record/object bytes remain in their existing
files. There is no four-MiB whole-corpus document or ten-thousand-record scan
cutoff. Dates are indexed in the catalog rather than inferred from filesystem
paths/mtime: observations sort by their source observation timestamp, with a
stable ID tie-breaker; notes and sources sort by update time.

List queries seek by date/ID and filter kind/scope before loading a bounded page
of bodies. The opaque cursor carries its query scope and position, so deleting
its anchor cannot restart or skip a page. Newer insertions are seen on refresh;
continuations keep moving toward older records. Search/recall retain lexical
substring semantics over all canonical search fields and only load selected
record bodies. These text queries are not semantic/vector search or an O(1)
operation; their work still grows with indexed text volume. Pages reserve both
750,000 encoded bytes and 24,000 JSON nodes for the existing RPC/native bounds.
Coverage uses indexed date/scoped queries; per-turn recovery selects only cuts
whose starts occur in that turn's admitted entries, not all earlier turns.

## Library rows and previews

`knowledge.list` and `knowledge.search` accept `projection: "sourceRow"`
(capability `knowledge-library-rows.v1`) and return bounded rows
(`{rows, nextCursor?, stateRevision}`) instead of full records. A row carries
identity, scope, timestamps, title, canonical URI, the user-facing original URI,
media type, capture disposition, admission, provider save/publication times,
freshness, the age basis/days, current verdict/replacement, and `hasTake`/`tagsStale`,
the preview reference, and the current generated summary text. The saved text and raw
bytes are never part of a page, which is what makes a complete page possible:
fifty 200,000-character sources are a few kilobytes of rows, where the same page
of full records cannot carry five of them. `ids` (1..64) refreshes exact rows in
the requested order for a targeted update; the projection requires
`kind: "source"`, always excludes suppressed records, and applies the same
privacy fence and admission partition as the full-record page (an archived
partition still needs `includeArchived`, and a waiting one `includePending`, as
the existing client policy already sends).

The row's presentation rules have one owner, `sourceRowFields`: age-dependent
`ageDays` and `freshness` are calculated at read time from the stable save-time
anchor, configured decay class and verdict; catalog heads never persist an age
or freshness rank. Search/recall SQL computes the ranking from those same stable
head inputs and snapshots its evaluation time for a scored page. The canonical
`KnowledgeConfig.tagVocabulary` is the sole owner of active IDs, labels and decay
classes; head re-projection after taxonomy edits keeps search and freshness
aligned without reading source bodies. Retired/merged selections remain visible
until re-tagging, but have `unknown` freshness; a completed merge adopts the
active target's decay class. The original URI
is the requested URI recorded for this exact saved-item identity else the
canonical URI (HTTP(S) only); a provider save time recovered or captured from
the provider's own save field is never presented as publication time for the
connector whose legacy field was misfiled; and a
generated summary is present only while its evidence digest still matches the
record's title and readable text, truncated for the row.

`knowledge.previews.read` reads up to 16 exact preview references in one call.
Each item is authorized by its own exact committed revision and rechecked after
its bytes are read, so a concurrent forget or exclusion wins. An item whose
reference does not belong to that revision, whose object is missing, or whose
preview exceeds 512,000 bytes (or the 4 MB batch bound) returns its own
`unavailable` reason instead of failing the page. Preview batches cross the same
exact base64 byte boundary as object reads, not the presentation projection.

`knowledge.search` returns `nextCursor` for either projection. A scored page is
ordered by relevance, source freshness, recency and identity; its cursor binds
the query, filters, projection and exact state revision, because such a page
cannot be resumed across a corpus change without skipping or repeating rows. A cursor from an older state
revision fails with `conflict` so the client reloads the first page.

## Curation and enrichment

`knowledge.source.curate` (capability `knowledge-curation.v1`, agent tool
`curate`) writes **interpretation** onto an exact source revision: `summary`
(text the caller produced, with its declared `full`/`sampled` coverage), `tags`
(a selection of active vocabulary IDs), `verdict` (`evergreen`, `dated`,
`superseded` with the entry that replaces it, or an explicit clear), `placement`
(scope and/or admission) and `relation` (add or remove an edge to another
entry). One batch carries one operation and 1..25 items. The owner derives every
evidence binding itself: a summary's `sourceRevisionId` and `evidenceDigest` are
computed from the committed record, so a caller can never stamp its own
provenance onto stored text, and interpretation never replaces captured
evidence, the original link, or a retained object. Archiving is admission
(`archived`), never a verdict; the legacy `archive` verdict remains decodable but
curation refuses new writes. Clearing a verdict removes it as a new source
revision.

A batch is not a transaction. Each item is its own receipted mutation whose
command ID is derived from the batch command and the entry, so:

- one item's conflict, refusal or unexpected failure is that item's outcome and
  never rolls back or blocks another;
- a batch interrupted by a crash is re-run with the same command ID and its
  applied items replay their committed revision instead of conflicting;
- a changed payload under a reused command ID is refused with
  `command-id-reuse`;
- `stale-revision` is a `conflict` outcome that carries the committed
  `currentRevision`, so a caller re-reads and retries deliberately;
- an excluded entry reports `excluded`, a forgotten one `forgotten`, and neither
  is silently overwritten.

Each outcome reads back what it wrote (`stored`), so a caller can verify the
committed fields without a second round trip. The batch's combined summary text
is bounded (`KNOWLEDGE_CURATION_MAX_BATCH_SUMMARY_CHARS`), which keeps one
response small enough for both the RPC frame and the model-visible tool bound.
`unchanged` means the write was already committed: identical values never create
a new revision.

The **tag vocabulary** belongs to Knowledge configuration and has its own
monotonic vocabulary revision (unrelated Knowledge settings do not invalidate a
tag selection): up to 256 stable lowercase-slug IDs, unique normalized labels,
one-line definitions (512
characters maximum), lowercase-slug categories, `ages`/`stable` decay classes,
`active`/`retired`/`merged` state, and up to 8,000 characters of free-text
guidelines. A merged tag names an active target; cycles and dangling chains are
rejected. Existing configurations gain an empty vocabulary without changing
their other settings. The decay accessor `knowledgeTagDecayClass(config,
id)` reads that same canonical vocabulary. K6 freshness treats only active
selections as policy inputs; a merged/retired selection is explicitly unknown
until the K3 re-tag process replaces it.

Taxonomy changes use the receipted `knowledge.tags.configure` operation and
require the exact `expectedConfigRevision`. Its typed edits add, rename,
redefine, recategorize, retire or merge one tag, or replace the guidelines.
Stale revisions return `conflict`; the same command/request replays its stored
result and a changed payload under that command ID is rejected. The generic
`knowledge.config` writer cannot change the vocabulary. The agent tool exposes
`configureTags` with the same typed edit. A merge immediately starts one
bounded, receipted re-point batch (up to 25 sources); `knowledge.tags.reconcile`
continues from its opaque cursor. Each changed source gets a new curation
revision with system provenance. Batch commits are atomic; a restart either
replays its committed receipt or safely retries an uncommitted batch. Retiring a
tag leaves existing selections intact but marks them for re-tagging.
`knowledge.tags.retag-needed` (agent tool `tagsNeedingRetag`) pages sources with
no selection, a stale vocabulary edition, retired/merged tag IDs, or a stale
`curationInputsDigest` (including a changed Your take), using catalog heads and
an exact vocabulary revision. K4 owns producing replacement selections.

A selection records the vocabulary revision it was validated against and
`curationInputsDigest` (SHA-256 of the record's title, current summary, readable
text, verdict, and Your take), so edits to any tag input enter the bounded query
without making stored selections unreadable. Tag
labels, category and decay class are projected onto source rows from catalog
heads; both Library row search by label and list/search rendering read no source
bodies. A vocabulary label/category/decay/state edit reprojects the bounded
source-head set inside the same config commit, so labels and search agree with
the new edition without loading source text. Definition and guideline-only
edits leave row projections untouched. The **curation gate** is consulted before each item with
the batch's operation; a refusal stops the batch and reports that item and every
later one as `skipped` with the code, which is how the paid tagging owner stops
dispatching once its budget is spoken for. It refuses only operations that spend
the budget: a spent tagging budget never blocks free edits such as verdicts,
placement or relations.

### Jev tag decisions and paid-work ownership

`knowledge.source.tag` (agent tool `tagSource`) accepts one source's exact
`expectedRevision` and optionally a `knowledge.jev` `connectionId` (omitted, it
uses the single enabled Jev connection with approved paid access and refuses
none or several); it returns an owned
`tags` job instead of waiting for Jev. `knowledge.tags.run` (agent tool
`retagQueue`) owns one bounded queue run of 1..25 entries from the canonical
`knowledge.tags.retag-needed` query. Repeated command IDs observe the existing
job. `knowledge.curation.jobs` reports its state. On every owned job's
`running` → `done` or `failed` transition, the Gateway publishes
`knowledge.curation.job` carrying the whole job, the same shape
`knowledge.curation.jobs` returns (`commandId`, `operation`, `sourceId`,
`status`, `startedAt`, `finishedAt` and the terminal `revisionId` or actionable
`code`/`reason`), so one client decoder serves both. This is an
invalidation/event signal, not a state mirror: clients query `knowledge.curation.jobs`
on open, reconnect, and this event, then read the committed record revision.
Terminal notifications share the Gateway event transport with the coalesced
`knowledge.changed` invalidation emitted by committed writes. Cancellation
preserves already committed entries; an interrupted entry remains in the K3
query. K5 can call
`knowledge.source.tag` after source capture/summary as part of its intake flow.

Tag evidence is limited by UTF-8 byte bounds: title 512, current summary 2,000,
readable text 8,000, take 2,000, verdict 1,000, and guidelines 3,000 bytes. The
summary, evidence, take, verdict, and guidelines are in shared Jev state, while
each candidate question carries its vocabulary ID, label, definition, and
category. The input digest covers title, current summary, readable text,
verdict, and take. K1 computes the stored digest and provenance; the tag write
also fences the vocabulary edition used to make the decision, so a taxonomy
change in-flight cannot publish under a newer edition. A strict noul confidence
threshold of **greater than 0.65** selects a tag; equal-to-threshold results are
omitted. At more than 16 active tags Jev first chooses applicable categories
(one or two category-choice questions for the maximum 256-category vocabulary),
then answers one noul question per remaining candidate, in groups of at most 16.

The paid capability belongs to `knowledge.jev` in ConnectionOwner, not to a
Raindrop account. It uses only the existing Keychain reference
`connector:jev:personal`. A user must create/enable that connection and
explicitly set `paidAccessApproved: true`; default paid approval remains false.
Its generic `paidBudgetCents` is the configurable monthly ceiling (500 cents is
the chosen default). No tagging code creates the connection or approves spend.
Before each Jev POST, the tagger durably reserves the current connection's
published 64,000-input-token maximum ($0.2688 cents); after a valid response it
settles to Jev's actual usage cost. A process restart leaves reserved or
uncertain dispatches visible in `knowledge.tags.budget` and blocks further paid
tagging in that month. `knowledge.tags.budget.reconcile` explicitly reconciles
one unknown result at its full reserved ceiling; it never makes the same Jev
call again. The UTC month rollover resets only that month's settled/reserved
counters and retains prior unresolved attempts. `knowledge.tags.estimate`
(agent tool `estimateTaggingCost`) uses the current retag query and worst-case
question batches to report maximum reservations without making a paid call.
`knowledge.tags.budget` (agent tool `taggingBudget`) reports cap, spend,
reservations, availability, and uncertain attempts. The standalone `jev` tool's
per-call ceiling remains independent.

K1's curation gate checks paid policy only for tag writes; free verdict, scope,
relation, and other edits continue when Jev spend is disabled or exhausted.
Paid reservations occur immediately before the Jev dispatch, not when the
already-computed tag selection is published. Take and summary revisions
invalidate the tag input digest; take edits and summary changes start an
automatic single-source job when one enabled Jev connection exists. Vocabulary
or guideline edition changes run a cost estimate first, then start one bounded
queue page only when its worst-case reservation is affordable. Otherwise all
stale entries stay in the K3 query for an explicit later run. There is no
recurring queue or scheduler.

To configure paid tagging, the user explicitly calls `connections.setup.begin`
with `{commandId, instanceId, definitionId:"knowledge.jev", method:"token"}`;
then `connections.setup.complete` with the returned `operationId`, matching
`instanceId`, `providerAccountId:"personal"`,
`credentialRef:"connector:jev:personal"`, and policy
`{enabled:true, allowWrites:false, paidAccessApproved:false, paidBudgetCents:500, recurringApproved:false}`.
After adding the Jev value to the existing Mac Keychain service, the user
explicitly updates that instance through `connections.policy.update` with its
current `expectedSetupRevision` and the same policy except
`paidAccessApproved:true`. These are ordinary existing connection-owner setup
and policy actions; there is no second tagging approval store.

Summary generation (`knowledge.source.summarize`, agent tool `summarize`) is
owned background work, not a request that waits for a model: the call accepts a
job and returns its state plus the source's current revision, the model runs
outside the store lock, and the commit revalidates the exact source revision,
configuration revision and privacy state before publishing. It uses only
`KnowledgeConfig.knowledgeModel.model`, a separate `provider/model` setting from
`observation.model`; `knowledgeModel.maxInputChars` and `maxOutputChars` bound
Knowledge interpretation independently of observation. Unset model configuration
refuses summary work as `model-not-configured` and never falls back to observation.
The full `knowledgeModel` object round-trips through the whole-config
`knowledge.config` RPC. The model can be changed by the agent tool action
`setKnowledgeModel`. For example, read `knowledge.status.config.revision`, then
call the agent `knowledge` tool with
`{action:"setKnowledgeModel", commandId:"knowledge-model-2026-09-29",
expectedConfigRevision:<current revision>,
knowledgeModel:"opencode-go/deepseek-v4.1-flash"}`. The action retains the
current limits (or initializes them to 48,000 input and 8,000 output characters).
This plan value is not written into the live config by source changes or tests.
The same configured model and limits govern summaries, triage, synthesis,
reflection, and manual-capture assessment. The job survives a
dismissed sheet, a backgrounded app and a reconnect, and
`knowledge.curation.jobs` (agent tool `curationJob`) reports `running`, `done`
or `failed` with a typed code for one command ID or for one entry. A duplicate
command ID observes the run it already started instead of starting — and paying
for — a second one. Job state is process-local by design: the durable outcome is
the committed revision, so a restart loses only `running`, never a write.

## Publication, upgrade, and recovery

Objects and immutable revisions are synchronized before a single SQLite
transaction publishes heads, exact revision ownership, coverage, privacy
fences, and the command receipt. SQLite uses `synchronous=EXTRA` with its rollback
journal (including directory synchronization after journal deletion) and secure
row deletion. The workspace mutex owns connections through close, including
async body I/O; no presentation reader can see a partial transaction. Reads do
not take that mutex: every catalog query sees committed state and the connection
closes when the read settles, so a reader never holds a lock a mutation must wait
for. A page resolves its heads before any body read; privacy checks made after a
body read may observe a newer commit, which can only hide a record excluded or
forgotten meanwhile, never reveal one. Record
revisions are immutable, so a revision a concurrent forget removed reads as
unavailable rather than as a damaged corpus, and object/preview reads recheck
authority against a fresh snapshot after their bytes are read. Work that calls a
model is not held under the mutex either: `knowledge.source.summarize` pre-checks
its receipt, generates outside the lock, and commits inside it with the same
revision/config/privacy revalidation, while an in-flight map keyed by command and
request makes concurrent duplicates share one charge.

Record heads carry the bounded source row projection plus source admission and
owner scope, so a page partitions by kind, scope and admission and renders rows
without loading a body. Heads are derived data with one owner, `headFor`.
`CATALOG_STORAGE_VERSION` 4 admits that projection and its freshness/take fields:
ordinary reads refuse an older manifest with an explicit row-projection upgrade
state instead of presenting an unprojected head, and the explicit startup
`upgradeStorage()` step rebuilds every head from its latest committed revision
in one transaction, fsyncs the catalog and writes the new manifest last. Version
4 rebuilds version-3 row heads from immutable revisions; version-2 catalogs use
the same derivation. The rebuild is idempotent and preserves exact
revision ownership and retained object hashes; a failure leaves the previous
manifest authoritative and is reported as `knowledge.upgrade-failed`. Failed
publication leaves only uncommitted immutable files, which are not readable
through Knowledge. New publications do not create a group-manifest journal.
Cleanup intentions and tombstones commit before physical deletion; `reconcile()`
retries exact pending cleanup without recreating records. Shared/historical
object references remain authoritative until their last retained revision is
forgotten. Historical revisions are not automatically expired.

The storage-v1 upgrade is explicit in Gateway startup, before session/Automation
initialization and observation recovery. It runs only when the user starts the
updated Gateway; source builds and reads do not touch a live store. This one-time
reader admits up to 64 MiB, including legacy state that already outgrew the old
four-MiB ceiling; larger or invalid state is left intact and unavailable, never
silently reset. It validates
every committed legacy revision and captured object, preserves IDs, timestamps,
coverage, configuration, exclusions, and receipts, and prepares a
new durable catalog. Only then does an atomic replacement of the small manifest
publish storage v2. Before that boundary the original v1 manifest remains
canonical. Definite preparation failure removes its own staging catalog; an
uncertain publication leaves a candidate ignored unless the manifest names it.
Existing immutable bytes and legacy group files are not rewritten or pruned.
There is no dual-write/fallback store and no automatic downgrade. A preparation
failure leaves Knowledge visibly unavailable without disabling unrelated chat;
after an uncertain publication, the manifest still decides which catalog is active.

`knowledge-catalog.test.ts` covers preserving a legacy corpus and receipt replay,
missing-revision retry, rescue of a 16,000-cut legacy state above four MiB,
atomic group rollback, missing/symlinked catalogs, evidence-heavy byte/node
paging, and public pagination/search across multiple pages with deleted anchors.
`knowledge-catalog.scale.test.ts` retains the 10,005-record, over-four-MiB
fixture; it checks exact body-read counts, full-history continuation,
late-corpus search/recall, scoped recovery, and actual SQLite date-index plans.
`knowledge-take-freshness.scale.test.ts` exercises source list/search/recall and
row projection over 12,600 catalog heads and 440 sources, with latency budgets
and the same bounded row/body separation. On the focused scale run, measured
latencies were 5 ms row listing, 216 ms row search, 109 ms full-record listing,
173 ms full-record search, and 162 ms recall (one run, host-dependent).
The default Raindrop pagination test crosses the real 50-item provider page
boundary with 51 items; the more expensive all-incomplete-head recovery case is
in `raindrop-intake-multipage.scale.test.ts`. Run both exact scale regressions
at release checkpoints with `npm run test:scale`. Default small fixtures do not
prove the 10,000-record/four-MiB or repeated incomplete-head scale thresholds.

Missing state in an established namespace is invalid and is never treated as
an empty corpus. Missing or malformed/newer state, unsafe ancestors, and
corrupt record/object files remain visible as failures rather than being
reset. `readObject()` requires the exact committed source record ID and
revision that owns the requested object or representation; it rechecks current
privacy/exclusion fences after byte I/O and never authorizes by hash-only corpus
scanning. It remains bounded and hashes the raw bytes; object media type belongs
to the reference and does not change byte identity. Existing-object reuse and
record references perform the same hash and size verification.

## Record and observation contract

The exported types in `src/knowledge/knowledge-contract.ts` define schema v1.
Sources, observations, and notes have stable IDs and immutable revision IDs.
Every observation range includes ordered canonical entry IDs and an entry
 digest supplied by the session owner, plus optional branch/project identity.
Coverage must repeat that exact range and digest and cannot be rebound to
another input; recovery compares exact canonical entry IDs and digest and marks
missing or non-active coverage unavailable rather than replaying it. Terminal
`observed`, `empty`, and `excluded` dispositions are immutable; pending/failed
work can recover, while `observed` cannot be
fabricated without committed observation revisions. Session-entry evidence is represented by a typed
`sessionEntry` citation; record evidence names the exact record revision.

`knowledge.observation.dismiss` (capability `knowledge-coverage-dismiss.v1`) is
the explicit Clear action for an exact failed/unavailable cut. The command ID
and expected coverage revision pass the existing serialized mutation/receipt
owner. It retains the range, digest, and original failure reason, marking only
that cut `excluded` with a `dismissed-by-user` reason so recovery cannot recreate
the warning. Active pending work and observed/empty groups cannot be cleared.
Session/project eligibility, conversation history, and observations are not
changed. A stale or late worker loses the coverage revision race. This requires
the updated Gateway; clients never hide failures in local acknowledgment state.

Coverage pages can also be read by disposition (`knowledge-coverage-filter.v1`):
`knowledge.observation.coverage` accepts an optional `dispositions` array that
narrows the page to those rows while keeping the same `recordedAt` cursor. This
exists so a client can list the cuts that need attention (`pending`, `failed`,
`unavailable`) directly instead of paging a ledger whose rows are mostly settled.
An unknown, duplicated, or empty disposition list is rejected as invalid, and an
unfiltered page keeps its previous behavior.

Mutations serialize per workspace and require stable command IDs with exact
request hashes. Record/config/coverage expected revisions reject stale
writers. Receipt payloads contain references rather than full record bodies.
Forgetting removes all forgotten record revisions, fences the record, purges
receipt payloads while retaining an invalidation marker (so replay cannot
resurrect or disclose it), and scrubs current derivative evidence/relations.
Shared objects remain only while referenced by retained revisions.

Observation eligibility and exclusion are prospective and revision-checked:
configuration carries a monotonic revision and either explicit session/project
selection or the positive `eligibility.allSessions: true` grant. The global grant
admits future turns in normal Gateway-owned conversations across workspaces,
including newly created conversations; it does not scan other apps/files,
select runtime-owned delegated transcripts, or backfill historical turns.
Omitting the grant retains selected-scope behavior, and empty allowlists still
select no scope. Global observation is advertised as
`knowledge-global-observation.v1`; clients must require it before sending that
grant so an older Gateway cannot silently ignore the choice. Existing model,
limits, selections, and exclusions remain intact when scope changes.

The same eligibility predicate gates inference admission and serialized
publication. Explicit session/project exclusions always override global scope.
`setScopeExclusion()` also fences session, branch, or project input before model
inference, not merely publication. A rejected pending admission cannot start a
model request. These fences apply even if a late worker generated a new record
ID; `scopeExcluded()` is the shared privacy predicate for presentation/recall
owners. Background publication supplies the captured config revision, so
disabled/re-enabled or changed-scope workers cannot publish late. Scope changes
re-evaluate the complete admitted cut without dropping its suffix; owner
cancellation retains pending coverage for recovery rather than requeueing work.

`reflect()` accepts a non-empty bounded set of observation revision IDs from
one session and one branch, including successive input digests. It replaces a
session/branch-local synthesis derivative by stable identity while preserving
immutable prior revisions, and stores an exact digest of the captured
record/revision set plus `derivedFrom` relations. Excluded source records or
ranges cannot be reflected.

The typed action surface remains the shared Gateway/agent/native DTO. Reads
return state revisions, and recall distinguishes no-match from unavailable
store errors. Registered recall text includes bounded dated, attributed,
qualified evidence and a pinned `knowledge.read` continuation (`id`,
`revisionId`, and `offset`) whenever the evidence section is incomplete; the
complete record is never available only through tool details. Observation
defaults to disabled and the store never chooses a provider or model silently. Connector DTOs are operation shapes implemented by the installed connector
extension. Connection setup owns the selected account, its Raindrop collection-to-scope mapping, and opaque `credentialRef` (`connector:<provider>:<account>`); only the Mac Keychain adapter resolves it. Raindrop collection routes are edited through the connection's revision-fenced setup/policy command, not duplicated in connector progress state.
Once `ConnectionOwner` is active, connector actions require an exact
`connectionId` and Knowledge persists provider progress under that instance
key, without copying the generic account envelope. Tokens never enter
knowledge state, receipts, logs, prompts, iOS models, or process arguments. Status and effect admission read the current ConnectionOwner instance revision, policy, and bounded `credentialAvailability`/`providerIdentity` observations; persisted Knowledge progress or an older observation cannot keep a policy-reset or successor instance ready. Setup intent never reports a provider capability as ready. An explicit connector operation may perform a fresh provider identity admission for the current revision; setup-required is not a permanent deadlock. A successful Raindrop `/user` admission may also retain one bounded email,
username, or `fullName` as `providerDisplayName` for the connection projection, only
when its numeric `_id` matches the configured account and the exact setup
revision is still current. Invalid or unavailable metadata is ignored rather
than blocking admission; mismatch, credential/policy changes, setup revision
changes, and disconnect clear the label. `providerAccountId` remains the
canonical technical identity and is never replaced by display metadata. Ordinary
Raindrop reads reuse their existing `/user` verification to publish this observation;
listing connections does not make a provider request. An observation that repeats
the instance's current projection is not a state transition: the owner writes
nothing, so that read performs no durable I/O and does not move `stateRevision`
or `updatedAt`. Authentication failures during
reads or sweeps, including a credential disappearing between attempts, clear the
observation under the captured setup revision rather than leaving a stale ready label.
`allowWrites`, `paidAccessApproved`, and `recurringApproved` remain
independent controls and default to false. The Gateway registers `knowledge.v1` typed RPC
handlers and a bounded first-party `knowledge` retrieval tool. The tool performs explicit
search/recall/read/list plus typed `connectorSweep` and `synthesis` actions for existing
Automations; it does not create a scheduler or run journal. Search, recall, and list hide
personal-scope sources unless the caller explicitly requests a scope; personal notes and
observations are unaffected. Search/recall age, freshness, verdict, save-time, and take
metadata are projected from the returned source record, including archived or pending hits.
Retrieved text is evidence, not authorization. A prospective
`KnowledgeObservationService` coalesces terminal turns (including no-tool,
failed, and interrupted turns), omits thinking/attachment bodies, uses one
pinned `ModelRuntime` adapter (the configured model is an explicit
`provider/model` value), and keeps model/storage latency outside foreground
settlement. The Observer prompt supplies the exact JSON envelope, item fields,
allowed attribution/certainty values, and empty-result shape required by the
parser; the configured model is never expected to guess that contract. Admission
occurs only after the runtime's terminal receipt and canonical attention barrier;
bounded model chunks name only their exact entry
IDs and digest, and any remaining suffix is admitted as a separate chunk.
Model-bound text removes recognized machine paths and credential shapes without
claiming complete secret scrubbing.
Prospective source retention is bounded by 64 cuts, 100,000 entries, and a
conservative 32 MiB retained-data budget including the currently processed cut.
A bounded traversal measures input before retaining it; repeated snapshots merge by exact
canonical entry ID, not repeated whole-payload JSON serialization. Excess new
admissions are rejected and diagnosed, not used to evict prior accepted cuts or
spawn an unbounded secondary gap-write queue. Only committed coverage is recovery
authority: pre-coverage cuts can be lost on shutdown or crash, and rejected input
is not advertised as recoverable coverage. Operational admission/read failures
retain the same accepted cut for a bounded-backoff retry. Durable pending/failed
retries derive command IDs from the current coverage revision, so each legitimate
transition has its own receipt.

A model timeout bounds the caller wait, not the operation lifetime; cancellation
bounds model caller waits but does not settle the provider. Work
ownership covers admission reads through publication and all late provider
settlements. Store cancellation is checked at serialized mutation admission;
once record bodies begin writing, their catalog and receipt commit must finish
rather than orphaning private bytes. Cancelled assessments cannot enter a new
derivative transaction after asynchronous revalidation. Connector calls fail as unsupported until their named extension seam is installed.

## Sources and maintained notes

`SourceContent` keeps the original immutable object (`object`) separate from its
bounded readable extraction (`text`) and optional generated `assessment`.
Readable text is a projection, not the evidence: the original bytes stay the
record's authority and remain separately readable through their exact revision.
The extractor (`extractReadableText`, owned by the source capture module) chooses
what a saved page contributes to summaries and search using structure only, never
a hostname or class-name allowlist. It tokenizes HTML with quote-, void- and
raw-text-aware scanning (so `i < n` inside a script and a `<div>` inside a string
never open elements), scores each element by the paragraph text in its own
subtrees while ignoring chrome subtrees and link text, and reads the deepest
element that still carries at least half of the page's own paragraph text and at
least 120 characters. Site-level `header`/`footer`, `nav`, `aside`, `form`, and
role/aria chrome are dropped; inside a chosen region an `article`'s own
`header`/`footer` are kept because they carry its title and byline; sibling
blocks that are only links (menus, breadcrumbs, file lists) are dropped once any
sibling with text survives. Non-HTML media types pass through unchanged.

That removal decides capture quality rather than assuming it. Text that is thin
after chrome removal, a page whose text budget was mostly chrome, an app shell,
and a page that only yielded its document title are all reported as partial with
their own `captureReason` instead of being certified complete; a genuinely short
article that the region rule isolated stays complete. A capture that needs
evidence therefore stays pending, and nothing summarizes it as though the page
had been read.
An optional `preview` is an exact canonical image object reference, governed by
normal source admission, suppression, historical-revision authority, and object
cleanup—not a publisher URL fetched by iOS. HTML OpenGraph/Twitter image metadata
and X Article covers use the same pinned, redirect-checked capture transport with
a 512 KB ceiling and JPEG/PNG/WebP signature checks. Optional image failure does
not fail source capture or remove a previously saved preview.

New assessments published by capture or triage include `evidenceDigest`: SHA-256
of UTF-8 `JSON.stringify({title, text})` for their source evidence. Native clients
must match JSON's escaping (not Foundation's default escaped slashes). This binds
summary freshness to content rather than the record's general update timestamp;
older assessments without the field do not assert that content binding.
Capture quality is explicit (`complete`, `partial`, `metadata-only`,
`inaccessible`, or `failed`) and is never upgraded because assessment worked.
Connector captures may include opaque provider/account/item identity and
multiple `origins`; these fields contain no credentials. Source capture uses
manual redirects, public-DNS destination checks, owner-bounded response bytes,
and script/style-free extraction. The readable extraction limit is applied from the capture request within the global safety ceiling; raw objects remain separately bounded. The URL-shaped `knowledge.source.capture`
operation enters this owner; callers do not publish fetched text directly.
URL diagnostics are redacted.

`knowledge.source.preview.refresh` is the explicit thumbnail-only owner path.
It accepts `{commandId, sourceId, expectedRevision}` and refreshes only a
missing preview on that exact admitted source. It may reuse an exact retained
HTML object or perform the same bounded safe fetch; X sources use one bounded
public root lookup to obtain an Article cover. It never captures linked targets,
invokes assessment, changes title/body/object/relations/admission, or creates a
new source. It returns `updated`, `unchanged`, `no-image`, or `unavailable` with
a bounded reason. Hidden, archived, pending, stale, cancelled, unsafe, invalid,
oversized, and non-image results do not delete an existing preview. A repeated
command or source that already has a preview performs no provider fetch; callers
must reconcile uncertain outcomes before retrying.

`knowledge.source.reextract` (agent tool `reextractSource`) is a bounded,
receipted one-source recovery operation for the saved readable-text projection.
It reads only the retained raw object authorized by the exact source revision,
performs no network request, recomputes `extractReadableText`, and commits only
against that expected revision. Replay returns the receipt; stale revisions
conflict. Poor or empty extraction returns `needs-evidence` with a reason and
keeps the source partial; it does not invent readable text. K11 can call it per
item and report each revision/outcome before requesting summaries.

`recoverProviderSaveTime` is the owner-mediated save-time reconciliation: one
source, one command ID, optional expected revision. It reads the provider payload
already retained at that exact revision, with no network request and no
credentials, and returns `recovered`, `present`, `absent`, `unsupported`, or
`conflict` with a bounded reason. Raindrop's item `created` is the original save
time; the payload must belong to that exact saved item, and `lastUpdate`, capture
time, and file mtime are never substitutes for a save or publication time. A
placeholder epoch, malformed instant, or future instant is refused; an existing
save time is never overwritten; a misfiled publication time is never written or
relocated; and a replayed command applies no second revision. A pending source is
fenced from reading its own objects, so a caller that has just retained the
payload may supply those bytes, which are accepted only when they hash to the
representation that revision lists. Callers exposing this to an agent must
translate `conflict` into a typed conflict.

`knowledge.source.triage` reads persisted current interests and publishes a
separate source derivative only after the retained source is available.
Generated `summary` text, the `tags` selection and the `verdict` are
interpretations written through the curation operations above; each carries the
producer that claimed it and the revision it was bound to, and none of them is
evidence.

`NoteContent` supports structured field values with exact evidence revisions,
validity, explicit confirmation, privacy scope, freshness, corrections,
supersession, and preserved contrary evidence. Personal/research scope remains
the sharing authority; `privacyScope` is descriptive metadata, not a second
sharing system. Assessment/triage is an optional derivative against persisted
editable `KnowledgeConfig.currentInterests` and uses an injected adapter owned
by the existing model boundary. The `knowledge.source.triage` action names an
exact source revision; it does not accept an unpersisted interest list. Capture
is durable even when that adapter fails. Exact source-object reads resolve a
source record and revision before reading its object; orphan and suppressed
object hashes are not an object browsing API. Object reads return typed,
512,000-byte base64 chunks directly through the Gateway boundary rather than
the ordinary 100,000-character presentation sanitizer; callers must use the
advertised offsets and verify the final hash. The enclosing frame/native limits
still apply, and invalid chunk metadata fails closed.

## Free public X post access

The read-only agent `knowledge` action `x` accepts one HTTPS X/Twitter post
`url`. It does not require or read connector credentials. Public lookup explicitly
discloses the numeric post ID to FxEmbed's supported v2 conversation endpoint,
with X's public syndication endpoint as an independent root-only fallback. No
caller query, cookie, authorization header, paid API, or browser session is
forwarded. The syndication `token` is a deterministic public embed value derived
from the ID, not an account credential; only that exact host/path/computed value
is exempted from URL credential-query rejection.

`x-public-post.ts` owns identity validation, FxEmbed v2 conversation/thread
parsing, bounded cursor selection, and ordered fallback; the source owner
supplies DNS-pinned HTTP, public-destination checks, 2 MB per-page body bounds,
8 pages, 256 items, 8 MB retained raw-page bound, zero provider redirects, a
15-second total deadline, and 5-second attempt deadlines. Each page/provider is
tried once. FxEmbed's conversation endpoint intermittently answers 404 for public
posts that its v2 single-status endpoint still serves, so only a first-page 404
earns one root read from `/2/status/{id}` before syndication; non-root coverage
from that read stays incomplete with an explicit limitation, and 429/5xx answers
never trigger it. The DNS-pinned transport sends only the bounded descriptive
`Tron/0.1 (public-source-capture)` User-Agent (no cookies or authorization); this
is required by the public providers and is not identity impersonation. A 429 is
reported with an honest stop reason, never immediately retried at that provider;
another explicit run must respect its cooldown.
HTTP success alone is not success: expected root ID, JSON shape, and either
nonempty bounded post text or substantive Article body blocks must match. Article
body text is retained with an explicit heading and remains partial because embeds,
media, and universal completeness are not established. Errors are sanitized, cancellation stops fallback, and
an unavailable result is not a claim of deletion or an empty bookmark library.
Tool output over 128 KB fails instead of truncating source fields.

Results contain provider/endpoint, canonical X ID/URL, root-post text, selected
same-author continuations, excluded commentary, explicit numeric parent
provenance, bounded provider-declared outbound URLs, exact bounded raw provider
pages, attempt outcomes, stop reasons, and limitations. `publicPostCoverage` may
request `root`, `conversation`, or `thread`; thread is an ancestor chain and
conversation is provider enumeration. Continuations require numeric author
identity plus an explicit parent chain from the requested post. Same-author
replies to commenters are not publication continuations. Cursor exhaustion is
not proof deleted or hidden posts do not exist. Long posts, Articles, quotes,
and media remain partial until separately verified. Syndication is always
partial. A usable partial v2 response is not discarded in favor of a weaker
preview.

`captureSource` / `knowledge.source.capture` accepts `publicPostLookup: true` to
explicitly opt a single public post into this lookup and the existing canonical
source store. Without it ordinary capture does not contact mirror providers.
The retained object contains original provider bytes; readable text contains the
root post, verified selected continuation/ancestor posts with canonical citations,
and, when present, the ordered Article body under an explicit heading—not author
bios and engagement metadata. Article entity links are retained only when
referenced by Article blocks and are cited to the declaring post. Excluded
commentary is not promoted into readable publication text. Provider-declared outbound
`http` and `https` URLs are bounded and, for explicit capture, are passed through
the same source owner as separate canonical Sources; redirects are validated per
hop without invented HTTPS upgrades. After a validated redirect, the final URI is matched within the requested scope
and the KnowledgeStore mutation atomically rechecks that identity before updating
or returning an existing canonical Source in place; origins are not used as
aliases, so referring-post provenance cannot conflate targets. The owner scans
suppressed, archived, and pending records too, so a hidden final owner is updated
in place rather than silently recreated as visible content. This relies on the
one-live-Gateway owner invariant, not an additional cross-process lock. Each target is related to the referring post and receives
evidence plus the original connector origin; target deduplication preserves
distinct origins. Redirects receive per-hop DNS/SSRF checks, and target failures
remain explicit partial/inaccessible/failed/reference evidence. If linked traversal
hits its redirect or credential-query bound after the root is retained, the root
keeps its text and records the bounded linked-target gap; store conflicts and
cancellation are not swallowed. Linked
GitHub UI pages are downgraded to partial because a page/file view cannot certify
repository or file completeness. Tiny HTML app shells are also downgraded to
partial; a title, loading marker, or JavaScript-only shell is not substantive
article extraction, and the same applies to a linked page whose text was almost
entirely navigation. Canonical URI is
`https://x.com/i/web/status/{id}`, while `captureReason` records provider, attempt
outcomes, and coverage limits. Existing scope/revision/deduplication, retention,
object-reading, and capture bounds remain authoritative. A retry matched by the
X numeric identity or canonical username/i-web alias updates that same source
revision envelope, preserving admission, provenance, relations, provider
representations, retention, and better prior bytes when the new provider attempt
fails. An explicit non-root `publicPostCoverage` refresh follows the same-record
revision path rather than creating a duplicate Source. This is not permission for
paid assessment or a new Raindrop intake policy.

FxEmbed v2 can enumerate bounded replies and unroll the requested endpoint's
ancestors, but neither is universal coverage. The reader never infers thread
membership from adjacency, ranking, arbitrary commenters, or bios. Browser
fallback must verify author identity and every reply/thread relationship before
adding substantive continuations; inaccessible linked content stays
partial/reference-only (and other transport failures remain failed). Each linked
Source keeps exact referring POST/REPLY evidence, and synthesis must cite that
Source separately from X author commentary.

Private bookmark discovery remains separate and supervised through the approved
`agent_browser` profile. The global `tron-x` skill provides bounded enumeration,
top-level bookmark membership, page checkpoints, identity/coverage validation,
and signed-in browser fallback when installed in Tron's user-level skills directory. There is no new
cookie store, background sync, automatic browser login, or remote mutation.
Never send known protected content to a public mirror without approval.
The existing paid `connectorSweep` X path is not selected by this free reader;
its existing explicit spending gates are unchanged.

Focused regressions: `x-public-post.test.ts` covers identity, URL isolation,
malformed/mismatched/truncated responses, fallback, partial content, cancellation,
and safe transport; `source-capture.test.ts` covers final-URI redirect reconciliation
across aliases/scopes and partial targets, conflicting canonical records, repeat and
concurrent publication semantics, and envelope preservation. `x-public-capture.test.ts`
covers raw evidence, opt-in, canonical URL identity deduplication, retry envelope
preservation, linked-source relations and origin bounds, bounded linked-target
failures, GitHub UI partial coverage, command-id bounds, and actual agent routing.
Browser login, private history coverage, Article/thread completeness, and provider
availability are live validation requirements, not conclusions from fixture tests.
New Gateway tool behavior requires a manual maintainer update; agents never
initiate a Gateway rebuild/restart. The skill includes a generic-tool read recipe
for sessions whose running tool schema has not yet been updated.

## Connector boundaries

Raindrop reads the official `/rest/v1/raindrops/{collectionId}` endpoint in bounded pages; X reads
`/2/users/{userId}/bookmarks` with the provider pagination token. Discovered provider IDs
and pending metadata are persisted before checkpoint advancement, preventing loss of
an already-fetched page. Offset pagination can still shift under concurrent remote edits;
this ingestion helper does not guarantee a complete snapshot or ongoing synchronization. Items use shared URL capture/store with explicit partial or
metadata-only quality, annotations, stable identity, finite retries, and visible auth,
rate-limit, remaining, and last-error health. Remote Raindrop moves are disabled by
default and require a locally verified raw object plus readable extraction, explicit write
approval, a durable pending receipt before PUT, and exact post-effect reconciliation.
X exposes no folder moves, browser fallback, automatic unbookmarking, purchases, or
recharge. A complete label alone is never sufficient for remote acknowledgment. Connector
runs are serialized per provider; pending discovery is advanced only after the complete
bounded page is durably retained, and incomplete/partial captures remain pending for
retry. Successful provider envelopes with a missing or non-array item collection
are shape failures, never empty pages. Credential references are admitted only in
the exact `connector:<provider>:...` namespace; a legacy mismatch requires
explicit reconfiguration and is never read as a different provider token. When the
Keychain item for a connection's credential is missing, the connector failure names
the Mac Keychain service and the exact account to add, never a token.
Paid budgets are rejected until a provider operation has an explicit maintained
price; approval flags never imply unknown spend. X is not contacted unless both explicit paid-access approval and a positive
bounded budget are present. Paid qualification is host-owned and requires
`TRON_X_ACCOUNT_ID`, `TRON_X_COST_CENTS_PER_ATTEMPT`, and
`TRON_X_MAX_ATTEMPTS` (1–3); missing or malformed values leave X unsupported.
Each possible X API attempt, including pagination and safe GET retries, debits
that budget immediately before the request, after resolving the current
credential. A missing or rotated credential therefore cannot debit a request.
A new operation uses a distinct attempt receipt, so replay cannot reuse an old
reservation. Discovery page receipts derive from the top-level command,
connector, scope, cursor, and page, making crash/replay of one page exact while
distinct commands remain distinct. Uncertain remote
PUTs are not retried; the persisted receipt is reconciled before another
connector effect. Connector status derives configured/disabled state from its
current credential, account, scope, and enabled authority; stale health markers
cannot report an enabled complete connector as unconfigured. Raindrop discovery,
intake, remote moves, and receipt reconciliation verify the configured numeric
account fence before relying on provider data or clearing an uncertain effect.
Reconciliation accepts the owning operation signal; cancellation leaves
`pendingRemote` durable and never retries an uncertain PUT. Raindrop, X, and Jev
share a typed fixed-host HTTPS transport for no-redirect requests, deadlines,
and bounded response bodies; endpoint construction, retry policy, credential
admission, paid reservation, and effect receipts remain adapter-owned. Public
source capture stays on its separate arbitrary-URL DNS/SSRF/pinning transport.

## Read-only Raindrop access

The `knowledge.raindrop.read` action and the agent `knowledge` tool action
`raindrop` use the existing enabled Raindrop connector and Mac Keychain
credential store. They verify `/rest/v1/user` against the configured numeric
user `_id` before each read, then expose raw bounded metadata for root and child
collections, collection detail, paged bookmark listing/search/sort/nested
queries, individual items, tags, and highlights. Collection detail accepts the
official `{ result: true, item: { _id, ... } }` envelope and verifies the
requested ID; safe GETs retry transient provider failures with bounded delay,
while malformed success shapes remain redacted errors. `perpage` is limited to
50 and a full page yields an explicit `nextPage`; pages are not an atomic snapshot.
Provider JSON is preserved; HTTP/metadata responses over 2,000,000 bytes and
agent text over 128,000 bytes fail rather than truncating fields. Narrow pages
or fetch individual items; a single item over the agent bound is unsupported. Retries honor `Retry-After` and both common rate-limit
header spellings. Redirects are not followed, and provider failures are
redacted. This is metadata access, not full article capture. `connectorSweep` only
verifies the provider and discovers bookmarks into the connector queue; it does
not capture linked pages, create Knowledge sources, decide admission, or move
Raindrop items. `raindropIntake` is the only connector path that captures and
decides bookmarks. Agent sweeps use the same accepted-work owner as RPC runs, so
disconnecting a presentation waiter does not replay or abandon admitted provider
work. Connector identity reuse
resolves through a canonical Knowledge catalog index keyed by
provider/account/item rather than scanning source pages.

## Bounded Raindrop intake

`knowledge.raindrop.intake` is the explicit manual source-owner operation for a
bounded intake. `dryRun` only discovers and persists pending provider identities;
it does not call Jev or mutate Raindrop. Research admission requires an explicit
pilot ID, maximum item count (at most 10), and budget (at most 100 cents), which
are persisted as a receipt-backed cohort for that collection so another
collection cannot reuse the allowance. The selected numeric collection must be
present in the connection's explicit mapping; an unmapped collection fails
before credential lookup/provider I/O. Discovery retains no more than the
selected limit per collection, so shifted provider pages are revisited rather
than silently skipped. Remote destinations are configured per source collection
and still require the connection's independent `allowWrites` approval.

After each Raindrop item's capture, K2 save-time recovery, and existing inline
assessment/admission/move processing settles (a single step on every exit path
of the item), its latest committed revision enqueues one Gateway-owned summary
job without waiting for the model when it has readable text. Partial captures —
every X post and GitHub page — qualify and are summarized as sampled evidence;
a source with no readable text gets no summary, and nothing is fabricated. A successful
summary job queues its K4 tag job; both are observable through
`knowledge.curation.jobs` / `knowledge.curation.job`. Intake command IDs are
derived from the exact source revision; an existing summary with the same
source-evidence digest and current tag input digest is reused on rerun. Summary
or tag failure is recorded on that job without rewriting a committed admission;
an item left pending by its existing assessment remains pending. Other cohort
items continue. Intake-owned admission state records a connector producer; an
explicit user/agent admission or scope placement remains authoritative on rerun.
Legacy admissions without producer metadata are conservatively treated as prior
decisions. Scope producer metadata is recorded for new explicit placements;
legacy scope changes without it cannot be distinguished from prior intake
placement. Decided bookmarks leave the connector pending queue even when no
remote move is requested, and the invocation `pending` counter excludes retained
or archived bookmarks that simply were not moved. The order differs from the initial K5 draft: K8's existing Jev
admission does not consume summary/tags, and its receipt/budget/move authority
remains independent of queued enrichment.

Each item keeps its bounded complete Raindrop JSON as a `provider-api` source
representation, the fetched linked evidence separately, and the source
collection ID as provenance. X/Twitter post permalinks are read through the
public post reader above under the bookmark's identity, so they retain post and
Article text with the provider's truthful partial disposition; other X/Twitter
pages are reference-only. Generic GitHub UI links are partial unless a later
capture establishes better evidence. Neither is silently assessed as a complete
article, and an incomplete capture leaves the bookmark pending without moving it.
It never revokes an admission already decided (`retained` or `archived`) for the
same canonical source. Knowledge's Jev adapter owns
its rubric, bounded text, relevant source metadata, and persisted interests.
It consumes the shared typed `JevDecisionClient`, also exposed as the first-party
`jev` tool for caller-supplied `choice`, `noul`, and `score` questions. This is not
chat completion. Credentials remain in the Keychain-backed
`connector:jev:personal` reference and are read only on explicit calls; core
Knowledge capture/retrieval does not require Jev. Tagging and Raindrop intake
assessment reserve and settle against the same monthly Knowledge ledger owned by
the `knowledge.jev` connection's `paidBudgetCents`. Paid access disabled there
blocks both workflows before provider dispatch. Raindrop cohort approvals remain
additional per-run item/cent caps and cannot enlarge the monthly budget; the
generic Jev tool cannot inherit that cohort allowance.

The tool requires `maxChargeCents`, checked before credential lookup or HTTP
against a conservative per-call ceiling of 0.2688 cents: the supported model's
64k input ceiling at its published $0.042/M input rate (output free). Responses
include actual token usage and fractional-cent estimated cost, not rounded-up
workflow reservations. New Knowledge assessments persist that usage and
published-price estimate on the immutable assessment derivative and attempt
receipt. Intake reports its per-run approved ceiling and conservative allowance,
selected cohort cap, settled count, known estimated usage cost, and unknown
usage separately. These are cohort totals; `captured`, `retained`, `archived`,
`pending`, and `moved` describe this invocation, while `budget` describes the
entire frozen cohort. Cost totals and unknown/uncertain attempt counts derive
from durable cohort receipts, so they survive moved items, reruns, and restart;
known costs are a subtotal when other attempts remain unknown. Pending identities
outside the selected cohort are reported separately, not labeled as assessed or
necessarily metadata-only. An old assessment without usage remains unknown and is
never backfilled as zero or claimed as provider billing. This is a local estimate guard, not a provider billing
cap. Successful calls without usage remain charged at the reserved ceiling, and
uncertain dispatches keep their shared monthly reservation until reconciled; no
workflow can refund or bypass that ledger. The client snapshots validated input before
awaits, rejects unsupported models, bounds total input and state plus each
question separately, rechecks cancellation after admission, redacts transport
failures, and never retries a paid POST. The adapter sends the pinned
`jev-1.13.0` typed contract to TypeSafe, validates the real choice/score
probability maps, score legend and expectation, and records fixed local labels
plus interest-bound profile/rubric versions, a digest of the complete captured
input, a digest of the exact bounded model state, and `full` versus `sampled`
coverage. Complete readable evidence is sent when it fits. Oversized evidence is
represented by a UTF-8/code-point-safe, explicitly labelled bounded excerpt while
canonical raw bytes remain untouched; sampled assessments can classify but can
never archive. This is bounded sampling, not a hidden multi-call summary or
provider fallback. It does not persist Jev prose as source truth. Novelty is intentionally omitted because
this bounded item request has no corpus evidence. The intake supplies its
reservation through the model adapter's `beforeDispatch` seam, after Jev
preflight and credential lookup; validation or missing-key failures therefore
consume no paid attempt. Fixed-host connector requests keep their own bounded,
no-redirect transport contract; the arbitrary-URL DNS-pinned source fetcher and
provider-specific disclosure/cost policy remain separate. Once admitted, a failed/malformed/timeout POST remains
an uncertain dispatched receipt and is never retried automatically. Complete
source capture remains durable and pending when Jev is unavailable. The first
pilot is frozen; `knowledge.connector.assessment.approve` appends an explicit
new <=10-item/$1 cohort for later work without resetting prior receipts or
binding fields. A valid historical paid assessment remains reusable when its
source/profile digest is unchanged; changing code or the current rubric does
not silently trigger a new paid assessment. Explicit reassessment
requires a fresh approval and receipt. By default, later cohorts select only identities not already
assigned to a cohort. An explicitly supplied `itemIds` list freezes pending
identities for renewed assessment attempts; previous uncertain charges remain
reserved, and the new cohort has its own additional allowance. This is renewed
paid authority, never an automatic retry or refund. Approvals cannot proceed
while a remote move is unresolved. Intake must match the approved bounds,
account, collection, and interest profile.

Capture quality, source admission, and remote delivery are separate. A bounded
per-item outcome accompanies each intake result with canonical source identity
and revision when available, capture/admission reason, assessment phase, and
move result. Outcomes retain cohort order and the canonical source revision
reached by each item; reused assessments are distinguished from new dispatches.
Summary counts and outcomes describe the same cohort but different scopes:
invocation counters count work performed, while outcomes also cover previously
processed identities and unattempted items blocked by an earlier remote effect;
missing pending identities are reported as recoverable reconciliation work rather
than silently omitted. Incomplete or failed capture remains `pending`. A

destination safety check failure is also durable as a `reference-only` source
with a sanitized capture-phase reason and provider identity; no forbidden hop is
fetched, and per-hop SSRF checks remain active. An initial blocked URL records
that no linked request was attempted; a blocked redirect records that an earlier
request was attempted while no request was sent to the forbidden target. The
reason records that the safety guard rejected the destination at capture time,
without asserting that
the original bookmark URL itself was private or malformed. A completed item
receives a durable
`retained` or recoverable `archived` source-admission state; archived sources
are absent from normal retrieval but can be explicitly listed/read/restored
without using privacy suppression. Connector captures awaiting admission are
also absent from normal retrieval; inspection requires the separate
`includePending` audit/intake flag. Generic `connectorSweep` only discovers and
queues provider identities; it cannot capture or move a source. Only intake,
after the local revision commits and the exact source head, admission, identity,
retained object, and provider collection are revalidated, can use the existing
Raindrop preflight/receipt/PUT/read-back path to attempt the configured Agent
Sorted move. Uncertain provider effects remain pending for reconciliation. Offset pages are not treated as an atomic snapshot: each
bounded run revisits page zero and uses durable IDs, so moved items shrinking
earlier pages cannot silently skip later entries. Malformed read envelopes are
rejected locally before credential lookup or provider HTTP; provider failures
remain sanitized.
For Raindrop, `ConnectionInstance.raindropCollections` is the sole routing configuration: 1..64 unique numeric collection IDs map to `research` or `personal`, with an optional destination per source collection. Setup completion installs the mappings; `connections.policy.update` can replace them only against the exact `setupRevision`. Raindrop no longer needs a single selected collection in the generic connector scope. Intake requires a mapped collection, and when several are configured the caller must select one; an unmapped ID is rejected before discovery. Dry-run and pending results filter to that collection. Provider page receipts include the collection ID; offset discovery restarts at page zero because moving bookmarks shifts Raindrop's pages, while durable pending/captured identities are tracked by their last collection. The returned item's collection, when present, must match the requested collection; if absent, the exact collection endpoint is the provenance.

Research retains the existing complete-capture → Jev assessment → admission path, with its pilot/receipt budget isolated by collection. Personal uses the original link, title, best-effort preview, and saved Raindrop note; failed or partial page fetches do not block `retained` admission and do not call Jev. A provider/account/item identity has one canonical source across scopes. When discovery sees it in a different mapped collection, the existing source's collection provenance is refreshed and K1's receipted `placement` operation changes its scope only when there is no authoritative user/agent admission or placement; it does not create a second record. If setup revision changes during a run, it stops before admission or a remote effect; any evidence already captured remains pending under the mapping that admitted that run and is inspectable for retry.

A remote move is authorized only by the existing connection `allowWrites` policy and the selected source collection's optional mapped destination, revalidated against the current setup revision at preflight and effect admission. No destination on a mapping means no move; another collection's destination cannot authorize it. The operation is manual only; no recurring approval, scheduler, X integration, or collection creation is implied.
