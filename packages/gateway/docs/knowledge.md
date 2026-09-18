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
IDs and digest, and any remaining suffix is admitted as a separate chunk. Connector calls fail as unsupported until their named extension seam is installed;
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
and script/style-free extraction. The URL-shaped `knowledge.source.capture`
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
object hashes are not an object browsing API.

## Connector boundaries

Raindrop reads the official `/rest/v1/raindrops/{collectionId}` endpoint in bounded pages; X reads
`/2/users/{userId}/bookmarks` with the provider pagination token. Discovered provider IDs
and pending metadata are persisted before checkpoint advancement, so pagination shifts do
not silently skip work. Items use shared URL capture/store with explicit partial or
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
connector effect.

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
