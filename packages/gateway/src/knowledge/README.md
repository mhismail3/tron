# gateway/knowledge

## Purpose

The Gateway's Knowledge owner: captured sources, notes and preserved observation
history under `state/knowledge`, their curation, Jev assessment, connectors
(Raindrop, X) and agent recall. iOS reads bounded pages.

## Owns

`knowledge-store.ts` (`KnowledgeStore`), `knowledge-catalog.ts` (SQLite catalog),
`knowledge-service.ts`, `knowledge-curation.ts`, `knowledge-tagger.ts`,
`source-capture.ts`, `source-triage.ts`, `connectors.ts`, `connector-credentials.ts`,
`x-public-post.ts`, `jev-*.ts`, `paid-budget-ledger.ts`. The full storage, record,
curation and connector contract is [knowledge.md](../../docs/knowledge.md).

## Contract

- A transactional SQLite catalog indexes dates, record heads, coverage and lexical
  fields; immutable revisions and objects stay in their owned files. The
  user-initiated start of an updated Gateway performs the one-time catalog upgrade;
  reads never migrate or reset state
  ([publication and upgrade](../../docs/knowledge.md#publication-upgrade-and-recovery)).
- Chronicle generation is retired: settled turns create no observation records;
  existing observation revisions and coverage stay readable history.
- Registered synthesis accepts exact SOURCE, NOTE and OBSERVATION revisions and
  publishes only an unconfirmed agent-derived note after its cancellation,
  configuration and source fences. Recall text carries bounded dated, attributed
  evidence and a pinned record/revision continuation.
- `knowledge.changed` is a coalesced invalidation hint after committed mutations
  ([change invalidations](../../docs/knowledge.md#change-invalidations)); clients re-read
  authoritative pages. The library reads `sourceRow` projections and batched
  `knowledge.previews.read`.
- Curation (`knowledge.source.curate`, `knowledge-curation.v1`) is one receipted
  mutation per item; summary and re-tag jobs are owned background work observed
  through `knowledge.curation.jobs`
  ([curation](../../docs/knowledge.md#curation-and-enrichment)).
- `knowledge.object.read` needs the exact owning record ID and committed revision and
  rechecks privacy and exclusion fences after byte I/O; it never scans by hash.
- `knowledge.status` returns typed coverage counts (`observedCount`, `emptyCount`,
  `excludedCount`, `pendingCount`, `failedCount`, `unavailableCount`,
  `remainingCount` = pending + failed + unavailable). `knowledge.observation.coverage`
  pages with `nextCursor` and an optional `dispositions` filter
  (`knowledge-coverage-filter.v1`), anchored to the `recordedAt` index.
- Connectors: the account envelope is `ConnectionOwner`'s
  ([connections](../../docs/connections.md)); the resolver gets the Knowledge workspace
  from `TronWorkspace` and connection authority from `ConnectionOwner`, never one from
  the other, and startup never upgrades a legacy provider-keyed catalog. X API runs
  need a host-qualified price, explicit paid access and a one-attempt allowance
  reservation; unknown pricing never permits a call. `knowledge.raindrop.read` is
  read-only ([Raindrop access](../../docs/knowledge.md#read-only-raindrop-access)); a
  Raindrop move re-reads the exact source revision and write policy before applying.

## Invariants

- Native note and correction mutations carry an explicit confirmation bit;
  agent-tool notes stay agent-authored and unconfirmed.
- Excluded or forgotten records never authorize object reads.
- Recovery keeps an admitted terminal outcome only with an unambiguous canonical
  invocation receipt; otherwise the cut is unavailable with a reason.

## Entry points

`KnowledgeStore` (mutations, reads), `KnowledgeService` (RPCs and agent tools),
`jev-extension.ts` (the `jev` tool).

## Signals

Knowledge records are catalogued in [observability](../../docs/observability.md).

## Verify

```bash
scripts/tron verify --module gateway/knowledge
```

Behavior lock: `knowledge.store.lock.integration.test.ts`; journeys are listed per
section of [knowledge.md](../../docs/knowledge.md).

## Not here

Home's chapter memory: [episodic memory](../../docs/episodic-memory.md). The internal
workspace root: [internal-workspace.md](../../docs/internal-workspace.md).
