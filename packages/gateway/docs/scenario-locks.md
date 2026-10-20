# Scenario locks

A scenario lock records what one deterministic scenario makes the real Gateway
and the pinned Pi SDK emit, persist and send, normalizes it, and compares it
byte for byte with a committed golden
([restructure plan §6.4](../../../docs/restructure/plan.md#64-gateway-behavior-locks-v3)).
Restructure slices must leave every golden unchanged; a golden diff means the
slice changed behavior.

## Framework

- `test-support/scenario-lock.ts` owns all normalization in one place:
  identity keys and UUIDs become `<id>`; ISO and session-file timestamps become
  `<timestamp>`; durations, counters, temp roots, package paths, per-run path
  digests, data URLs and host-derived numbers (`usage`, `cost`, `stats`,
  `tokensBefore`) are normalized. Response *values*, tool names, prompt
  sections and every text the model or a client sees are kept.
- `compareWithGolden` writes the actual trace to
  `test-results/locks/<name>.actual.json`. On a mismatch it throws the
  `git diff --no-index` hunks and keeps the full diff beside the actual trace.
  Each lock also asserts that its own steps happened, so a golden can never
  record a degraded run.
- `test-support/gateway-lock-harness.ts` starts a real Gateway for a lock: the
  production `RuntimeRegistry`, `GatewayService` and `GatewayServer` on a
  loopback WebSocket with a paired device. It also wires the settings model,
  its change path and the real upload store. The faux provider is the only
  scripted party, and owners a scenario must not reach throw if touched. It
  records each request with its normalized response, every event topic with
  the union of its payload structure (in-flight subtrees pruned), each provider
  request (tools, prompt sections, prompt hash, messages), canonical JSONL,
  named store files, notifications enqueued at the relay boundary, and the
  registry's runtime loads and evictions (a lock may cap live runtimes). Its
  `home` option wires Tron Home as `gateway-main` does (standalone Home trust
  directory, the Gateway model runtime, `home.*` RPCs, task recovery after
  listen) with a fixed memory summarizer, so compactor calls never interleave
  with scripted requests.

A lock's golden lives beside its test in `locks/<name>.golden.json`, owned by
the test's module. Goldens are darwin-specific, as for the SDK boundary trace:
the `computer` module registers only on darwin.

## Locks

| Module | Lock | Scenario |
|---|---|---|
| `gateway/run` | `run-prompt-stream` | streamed thinking and text, a `read` round trip |
| `gateway/run` | `run-steer` | steer and follow-up admitted into a live run, in order |
| `gateway/run` | `run-abort` | the client aborts the live operation; the turn settles aborted |
| `gateway/run` | `run-compaction` | manual compaction: summary and split-turn prefix requests |
| `gateway/run` | `run-extension-ui` | an extension tool's `select` waits for `extension.respond` |
| `gateway/run` | `run-cold-load-eviction` | under a one-runtime cap a closed, settled session is evicted for capacity, stays listed with its unread attention, and `session.open` cold-loads it with its JSONL and context |
| `gateway/run` | `run-drain-snapshot` | the administrative drain (`waitUntilIdle`) through `gateway.drain.status`: a live run and its queued follow-up block it, new work is refused, it completes after both |
| `gateway/transport` | `transport-reconnect-snapshot` | a client drops mid-run and reopens to the live run, then the settled one; the prompt runs once |
| `gateway/session-catalog` | `project-root-trust` | a chat in a subdirectory of an untrusted Git project: trust resolves to the root and refuses creation, a client's decision is saved for the root, and the chat keeps its cwd while the root's settings, skill and extension (not the subdirectory's) load |
| `gateway/admin` | `admin-settings-change` | `settings.change` at the Mac layer: resolution, a live chat, history, files, notifications |
| `gateway/notifications` | `notifications-push` | a registered phone gets completed, input-required, failed and stopped pushes for a hidden chat; a presented chat's are suppressed; a Home task worker's end pushes nothing |
| `gateway/automations` | `automation-owned-run` | the phone creates a session-prompt and a workspace-prompt automation and runs each now; both run a tool round trip as owned operations and settle acknowledged |
| `gateway/home` | `home-activation-wake` | designation, the new chapter's first runtime, an activation that delegates, the worker's report, the result wake and both activations' pushes |
| `gateway/delegation` | `delegation-subagent` | a foreground subagent over the real managed pi-subagents install and a real child |
| `gateway/pi-sdk` | SDK boundary trace | [Pi SDK behavior trace](../README.md#pi-sdk-behavior-trace) |

The reconnect lock records the two reopen snapshots in full but no event
shapes: which coalesced snapshot a socket that drops mid-run receives before
it closes is host timing. The subagent lock enters at `RuntimeRegistry`: the delegation kernel's
contract is the canonical record and the process activity, which the
transport only projects. It runs in the nested serial pass. The push lock runs the
production `NotificationService` (harness option `notifications`) with only the relay's
HTTP fetcher replaced, and records each relay request's envelope and every receipt. The
automation lock wires the production store, scheduler, executor and service (harness option
`automations`) and records every command receipt's contents. The Home lock
keeps Home's and the worker's provider requests as two ordered streams (they
interleave by host timing), adds each runtime's loaded extensions, tool schema
digests and stream options, runs the production push owner as the push lock
does, and records event shapes only for topics the outbound queue never drops;
a settled reopen snapshot stands in for the rest.

## Persisted stores (V4)

`test-support/tron-store-specs.ts` lists the stores. `npm run record:tron-corpus`
writes them with the real owners into `test-fixtures/tron-corpus/home`: synthetic,
privacy-clean data. The manifest beside it keeps the directories Git drops.
`TRON_CORPUS_STORES=<lock>,…` re-records only those stores and fails if any other
store's bytes change. Recording runs under a fixed clock and a counted
`randomUUID` (`test-support/fixed-recording.ts`), so a store recorded again writes
the same bytes. A store marked `reproducible` (settings and the derived stores)
was recorded that way, and its lock records it once more into a fresh home and
requires the committed bytes, which pins its write path too. The other committed
stores still hold their original wall-clock recording until a change re-records
them. The search index's SQLite header names the writing library version, so a
Node upgrade that bumps SQLite re-records `store-session-search`. Episodic memory cannot be reproducible: its cursor pins the source session
file's device, inode and ctime, which only the filesystem assigns.
Each store lock (`*.store.lock.integration.test.ts` beside its module):
1. stages a copy with the owner-only modes the Gateway creates;
2. opens it with the current owner and reads it through the owner's public read
   path;
3. compares that projection, with ids and timestamps kept because they are
   committed bytes, against `locks/store-*.golden.json`;
4. asserts reading changed, added or removed no byte anywhere in the home.

A store Git cannot hold (uploads: absolute body paths and hard-linked objects;
display artifacts: hard-linked objects) is
recorded live each run, and its persisted files are pinned in the golden. So is
the learned profile, whose notes are Knowledge records already committed by the
Knowledge lock.

| Store (under the Tron home) | Owner | Lock |
|---|---|---|
| `agent/settings.json`, `gateway/settings/` (change record, `floors.json`, `approvals.json`) | settings model and change path | `gateway/admin` store-settings |
| `gateway/devices.json`, `local-auth.json`, `enrollment.json` | `DeviceStore` | `gateway/security` store-devices |
| `gateway/command-receipts/` | `CommandReceiptStore` | `gateway/transport` store-command-receipts |
| `gateway/session-archive.json`, `session-attention.json` | archive and attention stores | `gateway/session-catalog` |
| `gateway/runtime-markers/` | `RunMarkerStore` | `gateway/run` store-run-markers |
| `gateway/notifications.json` (grants, inbox, policy) | `NotificationGrantStore` | `gateway/notifications` |
| `gateway/model-recents.json` | `RecentModelStore` | `gateway/providers` |
| `gateway/automations/` | `AutomationStore` | `gateway/automations` |
| `gateway/uploads/`, `upload-objects/`, `upload-bodies/` | `UploadStore` | `gateway/machine` (live) |
| `workspace/state/knowledge/` (records, SQLite catalog) | `KnowledgeStore` | `gateway/knowledge` |
| `gateway/home/tasks/`, workspace-state markers | `HomeTaskStore` | `gateway/home` store-home-tasks |
| `gateway/home/home.json`, `home/workspace/` (designation) | `HomeOwner` | `gateway/home` store-home-designation |
| Learned profile (tagged Knowledge notes, their record entries) | profile change path | `gateway/home` store-home-profile (live) |
| `workspace/state/episodic/<session>/` | `EpisodicStore` | `gateway/episodic` |
| `gateway/display-artifacts/` | `DisplayArtifactStore` | `gateway/display` (live) |
| `workspace/state/apps/` (manifest, source, SQLite state) | `SwiftAppStore` | `gateway/apps` |
| `gateway/session-search.sqlite` (contentless postings, reuse stamps) | `SessionSearchIndex` | `gateway/session-search` |
| `gateway/model-queue.json`, `model-queue-sessions/` (children's projection) | `ModelQueueOwner`, read by `projectionSource` | `gateway/providers` store-model-queue |
| `gateway/model-release-dates.json` (models.dev cache) | `ModelReleaseDateCatalog` | `gateway/providers` store-model-release-dates |
| Pi session JSONL, `agent/` auth, MCP and settings | Pi SDK | Pi persisted-state corpus (`gateway/pi-sdk`) |

Mutation-path locks (`test-support/store-path-lock.ts`) drive one store's
writes on a fresh home under a fixed clock and pin each step's result or refusal
and the exact files after it: session attention (`gateway/projection`), session
archive (`gateway/session-catalog`), command receipts (`gateway/transport`), run
markers (`gateway/run`), settings approvals (`gateway/admin`), Home tasks and their
authority (`gateway/home`), and the workspace-state markers (`gateway/workspace`).
Generated ids come from the same counted `randomUUID` as corpus recording. The
run-marker lock holds a queued write in the store's own file-system option to pin
that a later write waits for it.
Command receipts also have `command-receipt-concurrency`: capacity bounds, an
inventory rebuild opened from inside the receipt writer during another command's
pending or completed write, and an early prompt response whose lane a duplicate
must still find. `scripts/tron mutate` measures what they catch.

Not yet locked:
- **Operational:** `gateway.json`, `update-config.json`, `lan-endpoint/`,
  `mac-terminal/`, `ios-device-installs/`, `payloads/`, logs, `exports/`,
  `blobs/`, `stop-completed.json`.

These are follow-ups, not exemptions.

## Wire contract (V7)

`src/protocol/protocol.wire.lock.integration.test.ts` records from real frames:
- the declared lockstep contract (`config/GatewayProtocol.json` and the shared
  `packages/protocol-fixtures` connection values);
- the accepted hello frame's structure;
- the refusal of a client one version too new (close 4006, `protocol_mismatch`);
- for each of 21 methods, the structure of its request and of its response or
  error.

A renamed, removed, added or retyped field fails it; a wire change belongs to
a lockstep slice that updates both ends (plan §4.1 B4).

## Run and update

```bash
cd packages/gateway
npx vitest run .lock.integration                                      # parallel-pass locks
npx vitest run --config vitest.nested.config.ts delegation.lock       # subagent lock
TRON_UPDATE_LOCKS=gateway/run npx vitest run src/sessions/run.lock.integration.test.ts
```

Store and wire locks run in the parallel pass: `npx vitest run .lock.integration`.

`TRON_UPDATE_LOCKS` names the modules (comma-separated, or `all`) whose goldens
a run may rewrite. Only an approved behavior change or migration rewrites a
golden, and the change lists every hunk; a refactor never does.

Event shapes leave out admission-window state (`pendingPrompt`,
`activeToolSegmentId`, a new session's not-yet-persisted context notice), and
`contextUsage` is compared as structure. All of these depend on host timing or
checkout path length (#1465).

## Known-bad evidence

Each lock was checked when it was recorded (#1463): a deliberate production
change on a throwaway branch made it fail, and was then removed. The changes:
uppercased thinking text in the projection; steer admitted as follow-up; abort
not delivered; compaction instructions replaced; the select answer swapped;
the live operation dropped from the reopen snapshot; a settings value off by
one; and child-session attribution dropped. A lock does not pin the default
abort `kind` when the client names the operation. Store and wire locks (#1465):
an archive timestamp truncated on read, a store rewritten on open, an
automation status read broken, and a field added to a response. Derived stores
(#1484): a search derivation-version bump, a shorter projected usage skip, a
projection skip read at its expiry, the release-date alias read skipping fetched
dates, and a shorter settings approval lifetime (caught by re-recording).
Write paths (#1493): an approved change left untold, a run-marker bound of 17,
a session lane dropped while a queued write holds it, Home task spend allowed to
drop its cache split, and a feature marker admitted with extra keys. Home
(#1536): swapped Home tools, one prompt word, a wake that delivers nothing, the
result notice reworded, `operationId` dropped from `delegate`'s details,
`logicalSessionId` dropped from `home.prompt`, Home modules reordered or one
dropped, short cache retention, a reworded `delegate` description, and Home
chapters skipping the terminal push.
