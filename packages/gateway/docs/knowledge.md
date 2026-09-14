# Knowledge owner

Tron's knowledge capability has one canonical owner: `KnowledgeStore`, scoped to the resolved `TronWorkspace`. Constructing the store performs no filesystem mutation. The first deliberate mutation creates the owner-only `workspace/state/knowledge/` namespace:

```text
state/knowledge/
  state.json       # canonical validated state, immutable record revisions and coverage
  objects/*.json   # immutable base64 content objects addressed by SHA-256
```

`state.json` is atomically replaced with the existing durable JSON primitive. It is not a journal or a search index: every record revision, observation coverage disposition, suppression tombstone, cleanup intent, configuration value, and bounded mutation receipt needed for recovery is canonical there. Lexical search reads canonical latest revisions directly (`indexState: "canonical"`). A future index must remain disposable.

## Record contract

The exported types in `src/knowledge/knowledge-contract.ts` define schema v1. Sources, observations, and notes have stable IDs and immutable revision IDs. Every revision carries Personal or Research scope, actor/session provenance, evidence references, timestamps and typed relations (`supports`, `contradicts`, `corrects`, `supersedes`, `derivedFrom`, `related`). Temporal qualifications distinguish event, validity and review dates. Sources retain capture disposition and may refer to an immutable object; observations carry an exact session/branch entry range and attributed items; notes carry field-level values, qualifications, certainty and evidence.

An observation group is published by `publishObservationGroup`. It validates that all observation ranges equal the coverage range, then publishes the revisions and one `observed`, `empty`, or `excluded` coverage revision in one state replacement. `setCoverage` records `pending`, `failed`, or `unavailable` without claiming that inference completed. Failed or incomplete model work must not advance coverage.

Mutations are serialized, require a stable `commandId`, and use exact operation plus request hashing. Repeating the same command returns the original result; reusing its ID for different input is a conflict. Record and coverage expected revisions reject stale writers. Objects are published and verified before a record can reference them. Unknown, newer, malformed, or unsafe state is reported and preserved; it is never reset.

Exclusion is a durable suppression projection and is omitted from normal list/read/recall results. Forget first durably records a tombstone and cleanup intent while removing the record history; `reconcile()` then removes unreferenced objects crash-safely. A failed cleanup remains pending and is retried without recreating forgotten records. Exported state, backups, provider retention and source-session deletion remain separate owners and limits.

## Typed action surface

`KnowledgeAction` is the shared wire DTO for Gateway, agents and native clients. Operations are:

- `knowledge.status`, `knowledge.config`
- `knowledge.list`, `knowledge.read`, `knowledge.search`, `knowledge.recall`
- `knowledge.source.capture`
- `knowledge.note.create`, `knowledge.note.update`
- `knowledge.reflect`, `knowledge.correction`, `knowledge.exclusion`, `knowledge.forget`
- `knowledge.connector.configure`, `knowledge.connector.status`, `knowledge.connector.run`
- `knowledge.import.dry-run`, `knowledge.import.run`

Every mutating request includes `commandId`; revisioned updates include `expectedRevision` (observation publication additionally has `expectedCoverageRevision`). Reads return `stateRevision`; search reports whether the canonical source was read. `KnowledgeRecallResponse.availability` distinguishes no match from an unavailable store (the latter is a failed action/status, not an empty response). Cancellation may cancel admission to a queued store operation, but an accepted mutation is not cancelled after commit; callers must reread status/revisions after transport loss and must not replay an uncertain command with a different ID.

Configuration is bounded and defaults observation to **off**. Enabling observation without an explicit model leaves `observationConfigured` false; the store never selects a provider or model silently. Connector and importer DTOs establish precise operation shapes only; their network/account implementations belong to later owners.
