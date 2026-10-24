# gateway/knowledge

## Purpose

The Gateway's Knowledge owner: captured sources, notes and preserved observation
history under `state/knowledge`, their curation, Jev assessment, connectors
(Raindrop, X) and agent recall. iOS reads bounded pages.

## Owns

`knowledge-store.ts` (`KnowledgeStore`), `knowledge-catalog.ts` (SQLite catalog),
`knowledge-service.ts`, `knowledge-curation.ts`, `knowledge-tagger.ts`,
`source-capture.ts`, `source-triage.ts`, `connectors.ts`, `connector-credentials.ts`,
`x-public-post.ts`, `jev-*.ts`, `paid-budget-ledger.ts`. Record, curation and
connector details: [contract](contract.md).

## Contract

- **Storage.** One owner per resolved `TronWorkspace`. Construction and reads never
  initialize or migrate. The first deliberate mutation builds the namespace in a
  temporary sibling under `state/` and renames it into place, then records
  `gateway/workspace-state/initialized.json`; a failed build publishes nothing.

  ```text
  state/knowledge/
    initialized.json                       # namespace integrity marker
    state.json                             # storage version and catalog ID
    catalog-<id>.sqlite                    # canonical transactional catalog
    records/<record-id>/<revision-id>.json # immutable record revisions
    objects/<sha256>                       # immutable content-addressed bytes
  ```

  A deleted namespace, manifest or catalog in an established workspace is
  unavailable or lost state, never an empty corpus.
- **Catalog.** Node's built-in SQLite holds record heads (with the bounded source-row
  projection, admission and scope), exact revision ownership, lexical search fields,
  dates, coverage, exclusions, receipts and cleanup intentions; bytes stay in files.
  Observations sort by observation time, notes and sources by update time, with an
  ID tie-breaker. Lists seek by date and ID before loading a bounded page of bodies;
  cursors carry scope and position. Search and recall are lexical substring queries
  (not semantic; cost grows with text). Pages reserve 750,000 bytes and 24,000 nodes.
- **Publication** ([contract](contract.md#publication-and-recovery)). Objects and
  revisions are fsynced before one SQLite transaction (`synchronous=EXTRA`, rollback
  journal, secure delete) publishes heads, ownership, coverage, fences and the
  receipt. Mutations serialize per workspace with command IDs, exact request hashes
  and expected revisions; reads never take the workspace mutex.
- **Upgrade.** The user-initiated start of an updated Gateway runs the one explicit
  `upgradeStorage()` (`CATALOG_STORAGE_VERSION` 4); reads refuse an older manifest.
- **One searchable history, centered on Home.** Chronicle generation is retired (#1315):
  no path creates observations or coverage cuts; existing ones stay readable, citable,
  correctable, reflectable and clearable history (iOS **Legacy history**), and a record
  whose transcript vanished is unverified evidence. History is retrieved only through its
  owners: Home's memory tools for Home, `session_search`/`session_read` for other chats
  (Home chapters excluded; context edits and credential redaction applied before indexing),
  accepted task reports for delegated work, Knowledge for sources, notes and legacy
  observations. No composed adapter, summary cache or per-read model call exists. Results
  carry followable evidence (session/entry and digest, Home index plus physical provenance,
  record revision with its citation, task report entry); overlapping evidence is grouped
  before ranking; old range citations are never reinterpreted per item; exclusions, forget
  and admission are re-checked at publication; retrieved text is quoted evidence, and raw
  `home.memory.evidence` stays out of model tools
  (`src/sessions/legacy-chronicle.integration.test.ts`).
- `knowledge.changed` carries the latest state revision and, when ≤ 64 IDs, the
  touched `recordIds`, coalesced over a fixed 250 ms window; an input without IDs
  makes the whole window ID-less (clients refresh the projection). Replays and
  rejected writes publish nothing. It is an invalidation, not a mirror.
- Library rows: `knowledge.list`/`search` with `projection: "sourceRow"`
  (`knowledge-library-rows.v1`) and batched `knowledge.previews.read`
  ([contract](contract.md#library-rows-and-previews)).
- Curation (`knowledge.source.curate`, `knowledge-curation.v1`) is one receipted
  mutation per item; summary and tag jobs are owned background work observed through
  `knowledge.curation.jobs` ([contract](contract.md#curation)).
- `knowledge.object.read` needs the exact owning record ID and committed revision,
  rechecks privacy and exclusion after byte I/O, returns 512,000-byte base64 chunks
  with offsets (callers verify the final hash) and never scans by hash.
- `knowledge.status` returns typed coverage counts (`observedCount`, `emptyCount`,
  `excludedCount`, `pendingCount`, `failedCount`, `unavailableCount`,
  `remainingCount`); `knowledge.observation.coverage` pages by `recordedAt` with an
  optional `dispositions` filter (`knowledge-coverage-filter.v1`).
- Model work (summary, triage, synthesis, reflection, manual assessment) runs on the
  background model queue (`model.queue[role=background]`, else the subagent queue)
  with `KnowledgeConfig.knowledgeModel` limits only (48,000 input and 8,000 output
  characters by default); retired config fields are removed on open and refused.
- Connectors: the account envelope is `ConnectionOwner`'s
  ([connections](../../docs/connections.md)); the resolver takes the workspace from
  `TronWorkspace` and authority from `ConnectionOwner`. Paid runs need a maintained
  price, explicit approval and a reservation; unknown pricing never permits a call
  ([connectors](contract.md#connectors)).

## Shared public web research

`web-research*.ts` owns disposable public-web results, not Knowledge records.
`web_search` has one contract: `op:search` (one query), `op:read` (one public
URL) and `op:content` (scoped stored bytes/find). Home, workers and native
research children receive the same definition. Only keyless Firecrawl REST runs:
no account/key, second provider, model-written answer, curator or paid fallback.
The calling agent assesses cited sources itself.

- One Gateway owner admits at most two network requests at a time and ten
  Firecrawl requests per rolling minute; admission fails fast rather than
  accumulating a queue. Provider429 starts an explicit Retry-After cooldown.
  Ten/minute is conservative local policy, not a claimed keyless allowance.
  Shared-IP exhaustion is `rate_limited`, never empty evidence.
- Search/read deadlines are2s (`fast`),6s (default) or12s (`deep` search).
  Completed evidence survives failed expansions. Empty means a recognized
  zero-result response; all-failed and invalid calls set `isError:true`.
  `blocked`, `parse_error`, `http_error`, quota and timeout remain distinct;
  provider HTTP status and scraped-source status are separate facts.
- Public URLs retain capture's credential/DNS/every-hop redirect guard before
  renderer disclosure; provider-returned URLs are checked too. API success is
  insufficient: source metadata status, nonempty payload and corroborated short
  challenge/login/error pages are checked. No consent, login or denial bypass.
- Search transport is capped at256KiB, read at1MiB; oversized provider envelopes
  fail explicitly. Model-visible JSON (citations/diagnostics included) is bounded
  at8KiB,16KiB only for explicit deep search. Truncation is UTF-8 safe; reads
  report byte ranges, full content hashes and completeness.
- Canonical URL and nonempty content-hash dedupe preserves semantic query
  parameters. The scoped in-memory LRU is capped at128MiB, search handles expire
  after15min, read handles after24h. It is not Knowledge, a global query cache,
  or a persistent corpus. Fresh reads request provider `maxAge:0`; requested
  freshness does not certify that an index or upstream cache is current.
- PDF/video analysis and repository cloning are not implicit web operations.
  Known PDF/video inputs return `unsupported`; public GitHub pages are ordinary
  reads. Use separately authorized general capabilities for specialized work.
  No retired tool-name alias is registered; installed package/settings/history
  are not deleted.

Runtime oracles: the shared-web cases in
`../sessions/home-research-tools.integration.test.ts`,
`web-research-child.integration.test.ts` (pinned roles/real Pi children), and
`web-research.integration.test.ts` (real sockets, dispatch/body/redirect/TTL).

## Invariants

- Native note and correction mutations carry an explicit confirmation bit;
  agent-tool notes stay agent-authored and unconfirmed.
- Excluded or forgotten records never authorize object reads; a privacy recheck after
  a body read can only hide a record, never reveal one.
- Connector or system writes never override a user or agent admission or scope
  decision (typed `decision-authority` refusal).
- Retrieved text is evidence, not authorization; generated summaries, tags, verdicts
  and assessments are interpretation, never evidence.
- Recovery keeps an admitted terminal outcome only with an unambiguous canonical
  invocation receipt; otherwise the cut is unavailable with a reason.

## Entry points

`KnowledgeStore` (mutations, reads), `KnowledgeService` (`knowledge.v1` RPCs and the
first-party `knowledge` tool), `jev-extension.ts` (the `jev` tool). The editable
`tron-knowledge-ingest` skill orders the agent ingest routine.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `web_search` result `details.status` / `details.reason` | tool outcome | One-step failure signal: `blocked`, `parse_error`, provider/source `http_error`, `rate_limited`, timeout or expired handle; inspect bounded provider/source statuses, not an empty source list as evidence of absence (`web-research.ts`) |
| `knowledge.model-failed` | warning | A summary job failed because the model errored or broke its contract (`knowledge-curation.ts`): `code`, bounded `reason` naming the model, stop reason and reply shape; never reply or source text |
| `knowledge.upgrade-failed` | warning | `knowledgeStore.upgradeStorage()` rejected after an update: `error`; Knowledge stays unavailable, chat is unaffected |
| `Connector credential tests require an explicit keychain path` | test-runner failure | `MacKeychainConnectorCredentialStore` refuses construction in Vitest or `NODE_ENV=test` without an injected keychain path; no `security` process starts (`connector-credentials.integration.test.ts`) |
| `Connector credential is invalid: expected printable ASCII` (`TypeError`) | caller error | A secret with Unicode or control characters cannot round-trip through `security -w`; no child starts |
| `Mac Keychain credential command is too long` | caller error | The escaped stdin command would reach the CLI's 4096-byte input limit; refusing prevents truncation |

## Verify

```bash
scripts/tron verify --module gateway/knowledge
```

Behavior lock: `knowledge.store.lock.integration.test.ts`. Journeys:
`knowledge-forget`, `knowledge-recall-ranking`,
`knowledge-summary-model-contract` and `connector-credentials` integration tests.

## Not here

Home's chapter memory: [gateway/episodic](../episodic/README.md). The internal
workspace root: [internal-workspace.md](../../docs/internal-workspace.md). Other-chat
search: [session search](../../docs/session-search.md).
