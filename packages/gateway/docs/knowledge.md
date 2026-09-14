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
provider or model silently. Connector/import DTOs are operation shapes; their
network/account implementations belong to later owners. The Gateway registers
`knowledge.v1` typed RPC handlers and a bounded first-party `knowledge`
retrieval tool. The tool performs explicit search/recall/read/list only;
retrieved text is evidence, not authorization. A prospective
`KnowledgeObservationService` coalesces terminal turns (including no-tool,
failed, and interrupted turns), omits thinking/attachment bodies, uses one
pinned `ModelRuntime` adapter (the configured model is an explicit
`provider/model` value), and keeps model/storage latency outside foreground
settlement. Connector/import calls fail as unsupported until their named
extension seam is installed.

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
