# gateway/knowledge

## Purpose

Active Profile notes under `state/knowledge`, including their exact revisions,
provenance, sorting, partition recovery and forget protections. Home's episodic
memory and other-chat search have separate owners. Research sources are ordinary
Markdown, original JSON and attachment files, not runtime records.

## Owns

`knowledge-{store,catalog,contract,service,notes,change}.ts`,
`knowledge-profile-placement.ts`, `jev-{client,extension}.ts`,
`fixed-host-transport.ts` and `public-web-fetch.ts`.
The Jev adapter and public web primitives also serve non-corpus callers.

## Contract

- Construction and reads never initialize, upgrade or migrate. A deliberate first
  note mutation publishes an owner-only namespace; a missing established namespace
  is lost state, not an empty Profile.
- The existing storage-4 SQLite catalog owns note heads, exact revision ownership,
  controls, exclusions, receipts and cleanup intents. Immutable revisions and
  referenced bytes remain in files. No source/observation decoder, search, recall,
  tagger, curation queue or connector executes here.
- Bodies are fsynced before a single SQLite transaction publishes heads and the
  command receipt. Mutations serialize by workspace, command ID, exact request
  hash and expected revision. Reads see committed state.
- Profile partition changes organization metadata, preserving content, status,
  provenance and history. An owner-only backup precedes staged bodies; one commit
  publishes every head. Explicit recovery reuses prepared identities; reads never
  migrate. Changes/Undo stays with [Profile](../modules/home/profile.md).
- The `knowledge` tool exposes only bounded `read` and `list` of active notes.
  It cannot search chat memory or research files. Note text is evidence, not
  instructions. Home memory belongs to its existing memory tools.
- Retained exclusions and forget tombstones still fence note reads and receipt
  replay. Forget removes immutable revisions and redacts dependent Profile backup
  envelopes; cleanup intentions survive interruption.
- Committed note mutations emit revision invalidations via `knowledge.changed`;
  they are not a corpus mirror. The native Knowledge library has no route.

## Offline retirement

The standalone [converter](../../../../scripts/retire-knowledge.py) archives the
complete store and verifies exported source bytes before its first destructive
catalog commit. It is never called from Gateway startup. Profile notes and their
controls stay in their active store; this is not an old-format runtime fallback.

See the [development runbook](../../../../docs/development.md#offline-knowledge-retirement)
for copy rehearsal, exclusive offline requirements, verification and recovery.
Prior compatible builds and archives are recovery artifacts only.

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
`web-research-child.integration.test.ts` (pinned roles/real Pi children),
`web-research-resume.integration.test.ts` (live-child reload refusal, idle parent
reload and actual retained-role resume with scoped content and a fresh read), and
`web-research.integration.test.ts` (real sockets, dispatch/body/redirect/TTL).

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `web_search` result `details.status` / `details.reason` | tool outcome | Inspect bounded provider/source statuses for blocked, parse, HTTP, quota, timeout or expired-handle failures; never treat unavailable as an empty source list |
| converter `Refused:` | process failure | No success claim: inspect count drift, archive/current-byte mismatch, privacy disposition, unsafe paths or incomplete cleanup; retain the first failure |

## Verify

```bash
scripts/tron test tooling scripts/test-retire-knowledge.py
scripts/tron verify --module gateway/knowledge
```

The converter subprocess tests prove export hashes, exact revision preservation,
privacy refusal, stale-backup refusal, crash/resume and exact cleanup. Real Home
file-tool retrieval is in `../sessions/home-research-tools.integration.test.ts`.
Profile partition/forget protection remains in `knowledge-profile.integration.test.ts`.

## Not here

Home memory: [gateway/episodic](../episodic/README.md).
Other-chat search: [session search](../../docs/session-search.md).
Internal workspace ownership: [internal-workspace.md](../../docs/internal-workspace.md).
