# gateway/home

## Purpose

Tron Home: one opt-in persistent conversation per Gateway installation (`~/.tron` and
`~/.tron-dev` each own one), split into physical chapters, with its own runtime profile,
request seam, episodic memory, learned profile and delegated tasks. Ordinary sessions are
unaffected by every rule here.

## Owns

- **Designation and chapters:** `home-owner.ts` (record, ledger, profile changes, wake
  scheduler), `home-chapter-state.ts`, `home-chapter-contents.ts`, `home-session-*.ts`.
- **Profile and seam:** `home-runtime-policy.ts`, `home-request-policy.ts`,
  `home-module.ts` (request/input/append/settled hooks), `home-input-admission.ts` (inbox budget/diagnostic), `tron-home-extension.ts` (tools/context/cache).
- **Memory, research, profile:** `home-memory*.ts`, `home-research-tools.ts`, `home-profile.ts`.
- **Tasks and wake inbox:** `home-task-*.ts`, `home-wake-inbox.ts`; contract in
  [tasks.md](tasks.md). Also `home-diagnostic.ts`, `host-pressure.ts`,
  `locks/` (goldens).

## Contract

### Designation and chapters

- **Record.** `<tronHome>/gateway/home/home.json` (`0600`, atomic durable publish): `version`
  `2`, `homeId`, ordered `chapters` (`{ sessionId, ordinal, state: active | sealed | reserved
  | materializing, createdAt, activationStarted, … }`), `bindingRevision`, `generation`
  (advances on every profile change, fences in-flight work), `routeGeneration` (advances only
  on missing-session replacement), `policyRevision`, `enabled`, `model`, `memory` (pause state
  only), timestamps. Missing = undesignated. A malformed, unsafe or unknown record is kept
  and reported unavailable (designate and admission refuse); no migration or down-conversion.
- **Workspace.** `<tronHome>/gateway/home/workspace` (`0700`, empty) is recorded **untrusted**.
  Global skills and prompt templates feed the composer only (the model sees one when inserted);
  `home-global-resources.ts` reloads them live as their agent-directory inputs change.
- **Identity.** Every chapter is titled **Home** (no JSONL rewrite) and omitted from
  `session.list` (`scope: "user"`); search and `session.open` are unfiltered.
- **Rollover.** At a quiescent boundary, the soft limit (24 MiB or 50,000 entries) seals the
  active chapter and reserves a successor; before a `home.prompt` receipt binds, the hard limit
  (200 MiB or 100,000 entries) does the same. Every physical prompt rechecks the hard limit in
  its slot lane and refuses without redirecting. A running activation crossing it is stopped
  with reason `chapter-limit`. The next `home.prompt` or result wake materializes a reserved chapter.
- **Sealed chapters** refuse every mutation (`conflict` `sealed-chapter`); `home-append-guard.ts` owns slot-bound guards/Stop fences; bound slots refuse identity replacement (`home-identity-replacement`).
- **Materialization** claims one attempt per reserved chapter, strictly scans candidate JSONL
  and records the exact SDK path first; bad evidence blocks without touching bytes. A ledger
  publication error fences all Home admissions until reload and slot retirement finish.
- **Logical route.** `home.open` creates no runtime. `home.prompt` persists its receipt
  (identity, binding revision, chapter) before materialization and replays completed ones.

### Runtime profile and request seam

- **Profile** is fixed at runtime creation: `home` for an enabled chapter, `ordinary` when
  disabled. Home loads only `tron-context-window`, `tron-compaction-policy`, `tron-settings`,
  `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home`, `tron-home-research`; drops
  agent `SYSTEM.md`/`APPEND_SYSTEM.md`; allows exactly `HOME_TOOL_NAMES`; has no MCP,
  subagent discovery (empty `session.resources` catalog) or compaction (`session.compact`
  refuses); runs a fixed non-virtual model on its own view of the Gateway-wide model runtime;
  and sends zero cache-warming requests (`tron-home` answers `stop`).
- **Profile changes** run in one serialized owner, replacing a live runtime in place after an
  idle check (else `busy`); the enabled Home's model is written back to the record.
- **Activation:** one admitted input and everything it triggers. Every provider request
  carries the activation-start system messages, ONE memory view frozen at the first request,
  and the activation's own messages; prior activations are never re-sent and the view is never
  persisted. `prepareRequest`, `transformContext` and `streamFunction` enforce this fail-closed;
  a refusal sends nothing and shows one fixed, non-retryable sentence
  (`HOME_REFUSAL_SENTENCES`), with detail in `home.context`.
- `home.context` breaks the last request into `instructions`, `profile`, `memory`, `chapter`,
  `results`, `input`. For caching, system prompt and tools are byte-stable, the view only
  grows between rebalances, and Home requests ask for `long` retention.

### Memory

HomeOwner owns one `EpisodicMemory` ([gateway/episodic](../episodic/README.md))
keyed by `homeId`, reading all chapters in ledger order, so rollover, eviction and profile
changes keep its store, cursors and spend.

- **Summarizer** runs on `model.queue[role=background]` (else the subagent queue); with both
  empty, activations refuse. Reply wording is never validated. Spend is reported, not capped.
- **Pause** is durable in the ledger and receipted; a paused activation refuses
  `memory-paused` with zero requests and is never replayed. Started summaries still finish.
- **Recovery.** Every activation re-arms a blocked memory once; still blocked, it refuses with
  the reason (`memory-usage-limit` names the plan limit). `home.resumeMemory` or a different
  background queue also clears a block. Completed summaries are never discarded.
- **Memory tools** (`zoom`, `date`, `memory_search`) answer from the fresh projection, never
  the source, capped at 30,000 characters; typed `unavailable` outside the enabled Home.

### Tools and profile

- **Research tools** (read-only): `web_search`, `web_fetch` (SSRF-checked), `session_search`,
  `session_read` (never Home chapters), read-only `knowledge`, `read_file` (explicitly trusted
  projects). Results are capped and bannered untrusted; delegation is not gated on them.
- **Settings tool:** Home changes settings through the one change path as `home`; fetched
  content raises the tier one step. With `taskId` it reads or changes a worker's session.
- **Learned profile:** personal Knowledge notes labelled `home-profile` plus one `kind-<kind>`
  (`preference`, `standing-decision`, `delegation-default`, `fact`). Written only by the
  `profile` tool (unconfirmed) and `home.profileChange` (confirmed, `expectedRevision`), both
  through `HomeProfileItems` and the undoable settings path. Active items are injected as
  `## Learned profile` (≤ `HOME_PROFILE_BOUND_BYTES`, 8 KiB, else IDs only); unavailable
  Knowledge says so. Home chapters are never observed by Knowledge.

### RPCs and clients

- Capabilities `home.v1`, `home-memory-view.v1`, `home-chapter-list.v1`, `home-profile-list.v1`,
  `home-profile-edit.v1` (profile ones need Knowledge); shapes in `src/protocol/types.ts`.
- Reads: `home.status` (phase, readiness, recovery, chapter, `openSessionId`, `live`,
  `waitingForUser`, `taskRecovery`, memory counters; derived, never stored), `home.context`,
  `home.open`, `home.chapterList` (ledger, metrics and derived `contents`), `home.profileList`,
  `home.taskList`, `home.taskStatus`, `home.taskPermissions`.
- Receipted: `home.prompt`, `home.designate`, `home.disable`, `home.pauseMemory`,
  `home.resumeMemory`, `home.profileChange`, `home.reconfirmPermissions`, task controls.
- **Memory browser.** `home.memory.view` (newest-first lines, `part`, `sessionId` filter,
  revision-bound cursors) and `home.memory.evidence` (canonical text pages ≤ 24,000 chars)
  are disposable reads that never admit compactor calls or prompts. Each read proves the
  frozen cut through cached per-chapter proofs (`HomeSourceProofs`); nothing partial returns.
- **Clients.** iOS and `tron-chat` (`/home`: `HOME_USAGE`) open `openSessionId`, send `home.prompt`.

## Invariants

- The record's chapter ledger is Home's only identity; an unusable record never means no Home.
- One writable chapter; sealed chapters never mutate; nothing redirects to another chapter.
- Accepted input is never replayed; uncertain receipts and deliveries stay fenced.
- Memory text is request-local evidence, never instructions, never persisted in JSONL.

## Entry points

`HomeOwner` (`home-owner.ts`), `RuntimeRegistry.create(cwd, "home")`, the `home.*` handlers,
`tron-home` and `tron-home-research` extensions, `HomeTaskDispatcher`, `WakeInboxOwner`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `home.<outcome>`; `home.client-control`; `home.route-bound`; `home.resources-reload`; `home-model-record-failed` | info; `unavailable`, `refused`, failed controls and `resources-reload` warn; `home-model-record-failed` is a warning session-persistence code | Designation outcomes (`designated`, `enabled`, `disabled`, `unavailable` or `refused` with a coded `reason`), pause/resume-memory owner outcome (`operation`, `reason`), route binding `category` (`fresh`, `replay`, `open`), a live global-resource reload or watch that failed (`watch-failed` or a coded `reason`), and a failed write of the applied model into the designation. Never IDs, paths, models or memory text |
| `home.chapter-rollover`; `home.chapter-recovery`; `home.chapter-refused`; `home.chapter-limit-stop`; `home-chapter-limit-stop-failed` code on `session.diagnostic` | info; refusals, limit stops and the failure warn; the `session.diagnostic` code is a session event, not a log record | Rollover `reason` (soft or hard byte/entry limit) and `chapterOrdinal`; recovery `reason` (`absent`, `adopt`, `conversation-published`, `settings-from-live`, `settings-from-cold`); refusal `reason` (`hard-bytes`, `sealed-write`, `ownership-changed`, …); a running activation stopped at the hard limit with crossing and settled bytes/entries; a chapter-limit Stop that did not settle keeps its admission fence |
| `home.activation`; `home.activation-refused`; `home.memory-ingest`; `home-memory-revision-changed` / `home-memory-source-unavailable` reason on `rpc.error` | info; refusals and failures warn | An activation's first provider request (`effectiveTokens`, `contextWindow`, view lines/bytes, `excludedMessages`, `durationMs` readiness wait); a request refused before any provider call (`reason`, bounded `detail`; `memory-usage-limit` re-arms once the limit lapses); a memory-ingest failure `reason`; a memory-browser read that lost its revision fence or could not prove its sources (coded `cause`) |
| `home.task.store-refused`; `home.task.authorization`; `home.task.transition`; `home.task.checkin`; `home.task.spend`; `home.task.dispatch-stage`; `home.task.producer-refused`; `home.task.report-reminder` | info; refusals and slow, timed-out or cancelled dispatch stages warn | Keyed by `taskHash`/`operationHash`, never intent, report or path ([tasks.md](tasks.md)): task-store refusal `reason` (fenced until the next start, in `home.status.taskRecovery`); scope, grant and decision transitions; durable `pending`/`active`/`terminal` transitions with `reason`, `failureCause`, `errorCode`; check-in `attention`; deduplicated token spend; a `delegate` admission `stage` slow (≥ 5 s), timed out (60 s) or cancelled; a refused detached-capable producer; the single report-only continuation |
| `home.task.control`; `home.task.runaway-stop`; `home.task.detached-work`; `home.task.subagents`; `home.taskStatus.subagentRuns`; `home.taskStatus.ownerSettlement` | info; runaway stop and detached work warn; `home.taskStatus.*` are read-only status fields | Steer, interrupt and Stop `disposition` (`accepted`, `persisted`, `refused` with a finite `reason`; interrupt `calls`); the deadline cancel-and-join outcome; detached work outliving settlement (outcome unknown); subagent `started`, `stoppedAtEnd`, `noticesUndelivered`; the exact live runs that report and Stop select; the owner-settlement proof (`null` is unproven) |
| `home.task.inbox`; `home.wake`; `home.inbox.admission-slow`; `home-inbox-settlement-failed` code on `session.diagnostic`; `home-worker-attention-failed` | info; refused wakes, slow admission (≥ 2 s) and failures warn | Wake-inbox transitions (`eventHash`, `state`, coded `reason`); each wake decision (`admitted`, `deferred`, `refused` with `reason`); result delivery into an activation (`delivery`, `durationMs`); a durable terminal whose inbox settlement rejected (session event); a failed acknowledgement of a new worker's earlier completion |
| `host.pressure` | info; warning at `critical` | A Home-status read saw the host-pressure level change: `state`, `transition`, CPU busy, loop utilization and load per CPU; it informs and never holds a worker back |

## Verify
`scripts/tron verify --module gateway/home` or `scripts/tron test gateway <file>` covers
`src/home/*.test.ts` and `src/sessions/home-*.test.ts` (nested suites add `--config vitest.nested.config.ts`).
Managed queue persistence allows 60 s for two cold reopens; crash suites cover process abandonment, not power loss.
`input-admission.integration.test.ts` locks unpersisted trigger release; `session-profile.integration.test.ts` locks one-shot creation and live append classification.

## Not here

Episodic memory internals ([gateway/episodic](../episodic/README.md)), settings
keys ([settings-model.md](../../docs/settings-model.md)), Knowledge, RuntimeSlot and the
generic session lifecycle ([Gateway README](../../README.md)).
