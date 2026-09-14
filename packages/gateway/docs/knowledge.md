# Knowledge owner

`KnowledgeStore` is the single canonical knowledge owner for a resolved
`TronWorkspace`. Construction and presentation reads are side-effect free. A
first deliberate mutation creates the owner-only namespace:

```text
state/knowledge/
  initialized.json          # durable evidence that this namespace was created
  state.json                 # small atomic control state only
  records/<record-id>/<revision-id>.json
  groups/<coverage-id>-<revision-id>.json
  objects/<sha256>           # immutable raw content-addressed bytes
```

Record bodies and content bytes are immutable files. `state.json` contains
only record heads/revision lists, observation coverage, suppression and scope
exclusion fences, cleanup intents, bounded receipts, configuration, and a
monotonic state revision. Search and recall scan the bounded canonical record
set before applying presentation limits; they do not silently lose matches
past a list page.

## Publication and recovery

Objects are written and synchronized before a record revision can reference
them. A record revision is then written and synchronized. For an observation
group, all record revisions are written first, followed by one group manifest
containing the exact coverage and revision references; only then is the
atomic `state.json` replacement published. A crash before that replacement
leaves orphan immutable files that are ignored. A committed head always points
to already-published revisions. Cleanup is recorded before forgotten object
files are removed, and `reconcile()` retries unreferenced objects without
recreating records.

Missing state in an established namespace is invalid and is never treated as
an empty corpus. Missing or malformed/newer state, unsafe ancestors, and
corrupt record/object files remain visible as failures rather than being
reset. `readObject()` is bounded and hashes the raw bytes; object media type
belongs to the reference and does not change byte identity. Existing-object
reuse and record references perform the same hash and size verification.

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

Mutations serialize per workspace and require stable command IDs with exact
request hashes. Record/config/coverage expected revisions reject stale
writers. Receipt payloads contain references rather than full record bodies.
Forgetting removes all forgotten record revisions, fences the record, purges
receipt payloads while retaining an invalidation marker (so replay cannot
resurrect or disclose it), and scrubs current derivative evidence/relations.
Shared objects remain only while referenced by retained revisions.

Observation eligibility and exclusion are prospective and revision-checked:
configuration carries a monotonic revision and explicit session/project
allowlists and exclusions. Empty allowlists select no scope. `setScopeExclusion()`
fences session, branch, or project publication even if a late worker generated
a new record ID; `scopeExcluded()` is the shared privacy predicate for
presentation/recall owners. Background publication supplies the captured config
revision, so disabled/re-enabled or changed-scope workers cannot publish late.

`reflect()` accepts a non-empty bounded set of observation revision IDs from
one session and one branch, including successive input digests. It replaces a
session/branch-local synthesis derivative by stable identity while preserving
immutable prior revisions, and stores an exact digest of the captured
record/revision set plus `derivedFrom` relations. Excluded source records or
ranges cannot be reflected.

The typed action surface remains the shared Gateway/agent/native DTO. Reads
return state revisions, and recall distinguishes no-match from unavailable
store errors. Observation defaults to disabled and the store never chooses a
provider or model silently. Connector/import DTOs are operation shapes implemented by the installed connector
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
settlement. Connector calls fail as unsupported until their named extension seam is installed;
legacy import is installed only when explicitly named checkout roots are configured.

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
price; approval flags never imply unknown spend.

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
