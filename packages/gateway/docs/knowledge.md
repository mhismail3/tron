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
Coverage must repeat that exact range and digest. Successful coverage cannot
regress, and `observed` cannot be fabricated without committed observation
revisions. Session-entry evidence is represented by a typed
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
allowlists and exclusions; `setScopeExclusion()` fences session, branch, or
project publication even if a late worker generated a new record ID.

`reflect()` accepts bounded observation revision IDs from one session and one
branch/input digest. It creates a session-local synthesis note with exact
record-and-revision provenance and `derivedFrom` relations; it never uses a
revision ID as a record ID and never changes observation history.

The typed action surface remains the shared Gateway/agent/native DTO. Reads
return state revisions, and recall distinguishes no-match from unavailable
store errors. Observation defaults to disabled and the store never chooses a
provider or model silently. Connector/import DTOs are operation shapes; their
network/account implementations belong to later owners.
