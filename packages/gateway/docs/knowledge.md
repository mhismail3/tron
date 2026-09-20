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
lexical search fields, coverage, exclusions, receipts, import checkpoints, and
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

## Publication, upgrade, and recovery

Objects and immutable revisions are synchronized before a single SQLite
transaction publishes heads, exact revision ownership, coverage, privacy
fences, and the command receipt. SQLite uses `synchronous=EXTRA` with its rollback
journal (including directory synchronization after journal deletion) and secure
row deletion. The workspace mutex owns connections through close, including
async body I/O; no presentation reader can see a partial transaction. Failed
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
coverage, configuration, exclusions, receipts, and checkpoints, and prepares a
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
atomic group rollback, missing/symlinked catalogs,
evidence-heavy byte/node paging, and a 10,005-record fixture larger than four MiB.
It checks exact body-read counts, full-history continuation, deleted anchors,
late-corpus search/recall, scoped recovery, and actual SQLite date-index plans.

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
another input. Terminal `observed`, `empty`, and `excluded` dispositions are
immutable; pending/failed work can recover, while `observed` cannot be
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
defaults to disabled and the store never chooses a provider or model silently. Connector/import DTOs are operation shapes implemented by the installed connector
extension. Connector configuration supplies a selected account/collection scope and
opaque `credentialRef` (`connector:<provider>:<account>`); only the Mac Keychain adapter
resolves it. Tokens never enter knowledge state, receipts, logs, prompts, iOS models, or
process arguments. `allowWrites`, `paidAccessApproved`, and `recurringApproved` remain
independent controls and default to false. The Gateway registers `knowledge.v1` typed RPC
handlers and a bounded first-party `knowledge` retrieval tool. The tool performs explicit
search/recall/read/list plus typed `connectorSweep` and `synthesis` actions for existing
Automations; it does not create a scheduler or run journal. Retrieved text is evidence, not
authorization. A prospective
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
Prospective source retention is bounded by 64 cuts, 100,000 entries, and a
conservative 32 MiB budget including the currently processed cut. A bounded
traversal measures input before retaining it; repeated snapshots merge by exact
canonical entry ID, not repeated whole-payload JSON serialization. Excess new
admissions are rejected and diagnosed, not used to evict prior accepted cuts or
spawn an unbounded secondary gap-write queue. Only committed coverage is recovery
authority: pre-coverage cuts can be lost on shutdown or crash, and rejected input
is not advertised as recoverable coverage. Operational admission/read failures
retain the same accepted cut for backoff retry. Durable pending/failed retries
derive command IDs from the current coverage revision, so each legitimate
transition has its own receipt.

Cancellation bounds model caller waits but does not settle the provider. Work
ownership covers admission reads through publication and all late provider
settlements. Store cancellation is checked at serialized mutation admission;
once record bodies begin writing, their catalog and receipt commit must finish
rather than orphaning private bytes. Cancelled assessments cannot enter a new
derivative transaction after asynchronous revalidation. Connector calls fail as unsupported until their named extension seam is installed;
legacy import is installed only when explicitly named checkout roots are configured.
`knowledge-observation.test.ts` covers global admission, exclusion-before-inference,
and narrowing scope during inference. `runtime-knowledge-observation.integration.test.ts`
drives real canonical runtime turns through the observation owner and checks
persisted, cited recall under both selected and global scope without backfill.

## Sources and maintained notes

`SourceContent` keeps the original immutable object (`object`) separate from its
bounded readable extraction (`text`) and optional generated `assessment`.
Capture quality is explicit (`complete`, `partial`, `metadata-only`,
`inaccessible`, or `failed`) and is never upgraded because assessment worked.
Connector captures may include opaque provider/account/item identity and
multiple `origins`; these fields contain no credentials. Source capture uses
manual redirects, public-DNS destination checks, owner-bounded response bytes,
and script/style-free extraction. The readable extraction limit is applied from the capture request within the global safety ceiling; raw objects remain separately bounded. The URL-shaped `knowledge.source.capture`
operation enters this owner; callers do not publish fetched text directly.
URL diagnostics are redacted.

`knowledge.source.triage` reads persisted current interests and publishes a
separate source derivative only after the retained source is available.

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
discloses the numeric post ID to FxTwitter, with X's public syndication endpoint
as the single fallback. No caller query, cookie, authorization header, paid API,
or browser session is forwarded. The syndication `token` is a deterministic
public embed value derived from the ID, not an account credential; only that exact
host/path/computed value is exempted from URL credential-query rejection.

`x-public-post.ts` owns identity validation, provider parsing, and ordered
fallback; the source owner supplies DNS-pinned HTTP, public-destination checks,
2 MB body bounds, zero redirects, a 15-second total deadline, and 5-second attempt
deadlines. Each provider is tried once. A 429 is reported, never immediately
retried at that provider; another explicit run must respect its cooldown.
HTTP success alone is not success: expected root ID, JSON shape, and nonempty
bounded text must match. Errors are sanitized, cancellation stops fallback, and
an unavailable result is not a claim of deletion or an empty bookmark library.
Tool output over 128 KB fails instead of truncating source fields.

Results contain provider/endpoint, canonical X ID/URL, root-post text, exact raw
provider JSON, attempt outcomes, and limitations. Ordinary short-post text may
be complete **only for the root text**; threads and linked pages are outside its
coverage. Long posts, Articles, quotes, and media remain partial until separately
verified. Syndication is always partial. A usable partial FxTwitter response is
not discarded in favor of a weaker preview. Article previews are never certified
as bodies, and media URLs are not downloaded content or transcripts.

`captureSource` / `knowledge.source.capture` accepts `publicPostLookup: true` to
explicitly opt a single public post into this lookup and the existing canonical
source store. Without it ordinary capture does not contact mirror providers.
The retained object contains original provider bytes; readable text contains the
root post, not author bios and engagement metadata. Canonical URI is
`https://x.com/i/web/status/{id}`, while `captureReason` records provider, attempt
outcomes, and coverage limits. Existing scope/revision/deduplication, retention,
object-reading, and capture bounds remain authoritative. This is not permission
for paid assessment or a new Raindrop intake policy.

Private bookmark discovery remains separate and supervised through the approved
`agent_browser` profile. The [X skill](../../../.agents/skills/tron-x/SKILL.md)
defines bounded enumeration, top-level bookmark membership, page checkpoints,
identity/coverage validation, and signed-in browser fallback. There is no new
cookie store, background sync, automatic browser login, or remote mutation.
Never send known protected content to a public mirror without approval.
The existing paid `connectorSweep` X path is not selected by this free reader;
its existing explicit spending gates are unchanged.

Focused regressions: `x-public-post.test.ts` covers identity, URL isolation,
malformed/mismatched/truncated responses, fallback, partial content, cancellation,
and safe transport; `x-public-capture.test.ts` covers raw evidence, opt-in,
canonical URL deduplication, retry revisions, bounds, and actual agent routing.
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
retry. Paid budgets are rejected until a provider operation has an explicit maintained
price; approval flags never imply unknown spend. X is not contacted unless both explicit paid-access approval and a positive
bounded budget are present. Paid qualification is host-owned and requires
`TRON_X_ACCOUNT_ID`, `TRON_X_COST_CENTS_PER_ATTEMPT`, and
`TRON_X_MAX_ATTEMPTS` (1–3); missing or malformed values leave X unsupported.
Each possible X API attempt, including pagination and safe GET retries, debits
that budget immediately before the request. A new operation uses a distinct
attempt receipt, so replay cannot reuse an old reservation. Uncertain remote
PUTs are not retried; the persisted receipt is reconciled before another
connector effect. Connector status derives configured/disabled state from its
current credential, account, scope, and enabled authority; stale health markers
cannot report an enabled complete connector as unconfigured.

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
redacted. This is metadata access, not full article capture, and the existing
`connectorSweep` remains a lower-level capture helper rather than an assessed
intake or complete sync. Its connector sources remain pending and inspectable
through `includePending`; it cannot acknowledge or move a Raindrop item without
an explicit retained/archived admission from `raindropIntake`.

## Bounded Raindrop intake

`knowledge.raindrop.intake` is the explicit manual source-owner operation for a
bounded pilot. `dryRun` only discovers and persists pending provider identities;
it does not call Jev or mutate Raindrop. A run requires an explicit pilot ID,
maximum item count (at most 10), and budget (at most 100 cents), which are
persisted in connector state so a new command cannot reset usage. The numeric
source collection must match the connector's configured scope; it cannot bypass
that authority fence. Discovery retains no more than the approved limit per
intake call, so shifted provider pages are revisited rather than silently skipped.
Destination remains the separately configured collection.

Each item keeps its bounded complete Raindrop JSON as a `provider-api` source
representation, the fetched linked evidence separately, and the source
collection ID as provenance. X/Twitter links are reference-only and generic
GitHub UI links are partial unless a later capture establishes better evidence;
neither is silently assessed as a complete article. Knowledge's Jev adapter owns
its rubric, bounded text, relevant source metadata, and persisted interests.
It consumes the shared typed `JevDecisionClient`, also exposed as the first-party
`jev` tool for caller-supplied `choice`, `noul`, and `score` questions. This is not
chat completion. Credentials remain in the Keychain-backed
`connector:jev:personal` reference and are read only on explicit calls; core
Knowledge capture/retrieval does not require Jev. Each workflow separately owns
its disclosure, budget, and admission authority; the generic tool cannot inherit
the Resources pilot allowance.

The tool requires `maxChargeCents`, checked before credential lookup or HTTP
against a conservative per-call ceiling of 0.2688 cents: the supported model's
64k input ceiling at its published $0.042/M input rate (output free). Responses
include actual token usage and fractional-cent estimated cost, not rounded-up
workflow reservations. New Knowledge assessments persist that usage and
published-price estimate on the immutable assessment derivative and attempt
receipt. Intake reports the approved ceiling, conservative reserved allowance,
selected cohort cap, settled count, known estimated usage cost, and unknown
legacy usage separately. Cost totals and unknown/uncertain attempt counts derive
from durable cohort receipts, so they survive moved items, reruns, and restart;
known costs are a subtotal when other attempts remain unknown. Pending identities
outside the selected cohort are reported separately, not labeled as assessed or
necessarily metadata-only. An old assessment without usage remains unknown and is
never backfilled as zero or claimed as provider billing. This is a local estimate guard, not a provider billing
cap or a durable workflow allowance. The client snapshots validated input before
awaits, rejects unsupported models, bounds total input and state plus each
question separately, rechecks cancellation after admission, redacts transport
failures, and never retries a paid POST. The adapter sends the pinned
`jev-1.13.0` typed contract to TypeSafe, validates the real choice/score
probability maps, score legend and expectation, and records fixed local labels
plus interest-bound profile/rubric versions and an exact input digest; it does
not persist Jev prose as source truth. Novelty is intentionally omitted because
this bounded item request has no corpus evidence. The intake supplies its
reservation through the model adapter's `beforeDispatch` seam, after Jev
preflight and credential lookup; validation or missing-key failures therefore
consume no paid attempt. Once admitted, a failed/malformed/timeout POST remains
an uncertain dispatched receipt and is never retried automatically. Complete
source capture remains durable and pending when Jev is unavailable. The first
pilot is frozen; `knowledge.connector.assessment.approve` appends an explicit
new <=10-item/$1 cohort for later work without resetting prior receipts or
binding fields. By default, later cohorts select only identities not already
assigned to a cohort. An explicitly supplied `itemIds` list freezes pending
identities for renewed assessment attempts; previous uncertain charges remain
reserved, and the new cohort has its own additional allowance. This is renewed
paid authority, never an automatic retry or refund. Approvals cannot proceed
while a remote move is unresolved. Intake must match the approved bounds,
account, collection, and interest profile.

Capture quality, source admission, and remote delivery are separate. Incomplete
or failed capture remains `pending`. A completed item receives a durable
`retained` or recoverable `archived` source-admission state; archived sources
are absent from normal retrieval but can be explicitly listed/read/restored
without using privacy suppression. Connector captures awaiting admission are
also absent from normal retrieval; inspection requires the separate
`includePending` audit/intake flag. Generic `connectorSweep` cannot move a
pending source. Only after the local revision commits and the exact source head,
admission, identity, retained object, and provider collection are revalidated
does the existing Raindrop preflight/receipt/PUT/read-back path attempt the
configured Agent Sorted move. Uncertain provider effects remain pending for
reconciliation. Offset pages are not treated as an atomic snapshot: each
bounded run revisits page zero and uses durable IDs, so moved items shrinking
earlier pages cannot silently skip later entries.
The operation is manual only; no recurring approval, scheduler, X integration,
or collection creation is implied.

## Legacy import

`LegacyKnowledgeImporter` is installed through the `KnowledgeExtensionSeam.importer`
registration. Hosts configure the named `personal-os` and `llm-wiki` roots with
`TRON_PERSONAL_OS_ROOT` and `TRON_LLM_WIKI_ROOT`; the iOS surface only offers those
names and never sends arbitrary filesystem paths. It accepts only an explicitly named, configured `personal-os` or
`llm-wiki` checkout and a bounded `KnowledgeImportScope` (record families and/or
exact legacy IDs); it never scans an arbitrary path or invokes legacy wrappers.
Dry-run returns a deterministic plan hash over selected payloads, evidence hashes,
and stable mappings. Run requires that hash and records exact selected batch membership
and completed IDs in the knowledge store, so a crash can resume without creating a
second record. Structured assertion evidence qualifications and list-valued supersession
are preserved as attributed historical material.

Legacy source, entity, and assertion IDs are retained in `importOrigin` together
with the pinned Git revision and import time. Source capture disposition is
independent of evidence availability: Personal OS metadata-only sources remain
metadata-only, while Wiki extracts are read from a regular retained file or a
verified Git blob when available. Git reads disable lazy fetch, prompts, optional
locks, and helpers; no checkout or remote side effect occurs. Original dates,
structured assertion values, field evidence, negation, validity, supersession,
review lineage, sensitivity, and usage constraints remain explicit in typed
source/note payloads. Missing or over-limit evidence is reported and never
reconstructed from a hash.
