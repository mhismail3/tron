# gateway/home

## Purpose

Tron Home: one opt-in persistent conversation per Gateway installation (`~/.tron` and
`~/.tron-dev` each own one), split into physical chapters, with its own runtime profile,
request seam, episodic memory, learned profile and delegated tasks. Ordinary sessions are
unaffected by every rule here.

## Owns

Home composes K5's `TaskWorkerControl`, `TaskControlRefusalReason` and
`TaskWorkerDiagnostic` contracts. Its broader diagnostic union retains authorization,
store, transition, inbox and pressure policy records; native frames use only K5 records.
HomeTaskDispatcher uses the actual registry-owned DelegationOperations shared with
automations for worker creation/resume and cross-session steer/stop/interrupt. K5
owns acquisition/control orchestration; Home retains authorization, ledger and wake
policy, not native tool-interruption wiring or a second delegation instance.
Root's late composition supplies its actual settings model/change owner directly,
including outcome wake subscription. Home acknowledges outcomes only after the
canonical reader completes its durable file-and-directory proof; the approvals
store remains the sole outbox through refused wakes and process recovery. Home selects
outcomes for its chapter requester IDs through the same bounded, cancellable envelope
for user turns and autonomous wakes; native before-agent-start selection is ordinary-only.
A failed current canonical proof defers acknowledgement and chapter sealing, retaining
the outbox without scanning sealed chapter files.

- **Designation and chapters:** `home-owner.ts` (record, ledger, profile changes, wake
  scheduler), `home-chapter-state.ts`, `home-chapter-contents.ts`, `home-session-*.ts`.
- **Profile and seam:** `home-session-profile.ts` (recipe), `home-runtime-policy.ts`, `home-request-policy.ts`,
  `home-module.ts` (request/input/append/settled hooks), `home-input-admission.ts` (inbox budget/diagnostic), `tron-home-extension.ts` (tools/context/cache).
- **Memory, research, profile:** `home-memory*.ts`, `home-research-tools.ts`, `home-profile.ts`.
- **Task policy:** `home-task-worker-choice.ts` owns late task budgets, Home queue
  roles and authenticated model/thinking admission over canonical native reads.
- **Tasks and wake inbox:** `home-task-*.ts`, `home-wake-inbox.ts`; contract in
  [tasks.md](tasks.md). Generic subagent receipt/artifact proof belongs to
  [kernel delegation](../../kernel/delegation/delegated-activity.md), not Home policy.
  Also `home-diagnostic.ts`, `host-pressure.ts`,
  `locks/` (goldens).

## Contract

### Designation and chapters

Home receives the canonical native `SessionOperations` implementation, not a
Registry-produced Home adapter. Home assembles its domain session recipe; native
operations retain maps, mutation/construction mutexes, catalog cuts and retirement.
One actual native input supplies canonical file reads, mutation ordering, runtime
projections and worker I/O; Home keeps no forwarding callbacks or duplicate worker input.
The same registry-owned K5 service owns worker orchestration and cold artifact proof;
Home computes its subagent projection from the selected native cut through K5's reader.
Composition supplies the same late K6 settings, Knowledge and raw model owners.

- **Record.** `<tronHome>/gateway/home/home.json` (`0600`, atomic durable publish): `version`
  `2`, `homeId`, ordered `chapters` (`{ sessionId, ordinal, state: active | sealed | reserved
  | materializing, createdAt, activationStarted, … }`), `bindingRevision`, `generation`
  (advances on every profile change, fences in-flight work), `routeGeneration` (advances only
  on missing-session replacement), `policyRevision`, `enabled`, `memory` (pause), timestamps;
  Home's model lives only in its saved settings. Missing = undesignated. A malformed or unknown
  record is kept and reported unavailable; only the startup settings migration rewrites it.
- **Profile creation and catalog.** Home chooses its isolated profile when creating a
  chapter over native session creation. Its tool catalog keeps the curated names and
  describes them from the first non-disposed lineage member in native map order;
  the unloaded view never starts a runtime or enumerates every chapter's tools.
- **Identity refusal.** Home constructs its exact lineage identity error; native
  frames retain membership/profile selection, mutation ordering and physical guards.
- **Model choice.** Home's owner factory reads its saved model recipe and owns
  explicit chapter choices, including their K6 scope, actor and chapter fence.
  Composition supplies the late settings owner; native operations supply the current runtime. A host with
  no settings owner retains its existing SDK-only choice behavior.
- **Uncertain publication.** Home selects its native runtime projections and owns
  ordered settle/retire eligibility and refusal policy. Native retirement retains the
  canonical map, identity, busy, lease and disposal checks; recovery reads that authority.
- **Chapter evidence.** Home owns live/cold size and entry measurements and
  durable-conversation checks. Native ports provide only current runtime and
  canonical path reads; cold measurement fences the finite file cut by size,
  time and identity, and publication requires an untorn conversation branch.
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
  The neutral kernel lineage port owns runtime construction/publication; Home alone
  interprets the write-authority fields. Slots retain a frozen defensive copy.
- **Cold opens.** Home owns chapter/path/evidence checks and returns a read-only
  `sessionLineage.openRefusal` fact. Core throws that exact refusal before SDK open
  at each existing read/recovery cut; sealed chapters remain readable. No Home
  construction or publication workflow runs through this fact.
- **Logical route.** `home.open` creates no runtime. `home.prompt` persists its receipt
  (identity, binding revision, chapter) before materialization and replays completed ones.

### Runtime profile and request seam

- **Profile** (`home-session-profile.ts`) is fixed per runtime. An unrecorded new Home uses
  its creation recipe once; later runtimes read the record (enabled Home, otherwise ordinary).
  Only `tron-context-window`, `tron-compaction-policy`, `tron-settings`, `tron-projects`,
  `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home`, `tron-home-research` and
  `tron-web-research` load. [Projects](../projects/README.md) owns the `projects` tool
  for creation and tap-gated lifecycle actions; project work remains delegate-only.
  Agent `SYSTEM.md`/
  `APPEND_SYSTEM.md` are dropped; only `HOME_TOOL_NAMES`; no MCP or subagent discovery
  (empty `session.resources` catalog), no compaction (`session.compact` refuses). Fixed physical
  model on its Gateway-runtime view; the profile owns explicit model admission and physical
  selection metadata. Composition supplies lazy runtime acquisition, proxy isolation and Home
  cache retention, not Registry. No cache warming (`tron-home` answers `stop`). Append guards read the live record.
- **Profile changes** run in one serialized owner, replacing a live runtime in place after an
  idle check (else `busy`); the rebuilt runtime adopts Home's saved settings.
- **Activation:** one admitted input and everything it triggers. Every provider request
  carries the activation-start system messages, ONE memory view frozen at the first request,
  and the activation's own messages; prior activations are never re-sent and the view is never
  persisted. `prepareRequest`, `transformContext` and `streamFunction` enforce this fail-closed;
  a refusal sends nothing and shows one fixed, non-retryable sentence
  (`HOME_REFUSAL_SENTENCES`), with detail in `home.context`.
- **Delivery headroom** reserves the replacement request head, including the learned
  profile at its bound, over the same frozen memory cut. Framing, admission and final
  overflow checks share one head constructor: recorded text/sections are replaced,
  declared tools are preserved and charged with `instructions`, and profile is counted
  separately. Historical system deltas are not additional heads. Output reserve remains.
- `home.context` breaks the last request into `instructions`, `profile`, `memory`, `chapter`,
  `results`, `input`. For caching, system prompt and tools are byte-stable, the view only
  grows between rebalances, and Home requests ask for `long` retention.

### Typed trigger inputs

`kernel/host/input-admission.ts` defines the source attribution, route and inbox ports.
Each producer owns its durable outbox; Home owns eligibility, bounded input admission
and one single-flight wake, sharing busy, disabled, paused and blocked gates with task
results. Explicit memory resume reconsiders waiting sources. A maintainer activation
may also consume pending context without granting it maintainer authority.

Automations bind Home identity and route generation, snapshot each firing and supply
`tron.home-trigger.v1` custom messages. Producer identity and event identity are separate;
canonical context attribution identifies the automation, while each firing keeps its
own event ID. The visible label is **Automation · name**, never a user-message row.
The Run owner writes canonical binding and context attribution before the automation
request gate proceeds; only a durable canonical proof retires its source outbox.
A recovered partial input remains in that batch. For a singleton, a hidden native resume
input starts the existing SDK lifecycle; `deliveryMessage` binds the original producer
message before acknowledgement, never duplicating its visible message or claiming user authority.
Automations enforce their own per-definition cooldown; task-result timing is unchanged.
See [Automations](../../automations/README.md) for queue, cancellation and settlement.

### Memory

HomeOwner owns one `EpisodicMemory` ([gateway/episodic](../../episodic/README.md))
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

- **Research tools** (read-only): the shared `web_search` search/read/content contract
  ([public-web owner](../../knowledge/README.md#shared-public-web-research)), `session_search`,
  `session_read` (never Home chapters), note-only `knowledge` (read/list of active Profile notes), `read_file` (explicitly trusted
  projects). Web schema, backend and quota owner are identical to ordinary workers and native
  research children. Results are capped untrusted data; delegation is not gated on them.
- **Settings tool:** Home changes settings through the one change path as `home`; fetched
  content raises the tier one step. With `taskId` it reads or changes a worker's session.
- **Learned profile:** personal Knowledge notes labelled `home-profile` plus one `kind-<kind>`
  (`preference`, `standing-decision`, `delegation-default`, `fact`, `correction`). The `profile` tool's
  inferred content writes and maintainer `home.profileChange` (confirmed, `expectedRevision`)
  share `HomeProfileItems`, which owns operation validation, rollback, undo fencing and
  typed result projection. Content changes use `SettingsChangePath.auditSubject`, retaining
  the Home stripe through effects, grouped audit, awaited observer and projection; partial
  failures restore before ungrouped failure audit and rethrow the original value.
  Explicit placement-only migration/reorganization freezes the original audit in Knowledge's
  backup before effects, then uses the kernel's atomic subject publisher after proving
  committed identities. Retry repairs only a committed audit or explicitly resumes its
  precommit intent; existing Changes Undo restores exact labels without rewriting content.
  `## Learned profile` carries bounded seven-area/count/revision metadata and diagnostic
  references, never note text. Home explicitly reads v2 paths or Prior organization and
  chooses relevance and worker-brief content; unavailable Knowledge says so. Placement
  never weaken confirmed standing authority. See [profile contract](profile.md).
  Home chapters are never observed by Knowledge.

### RPCs and clients

- Capabilities `home.v1`, `home-memory-view.v1`, `home-chapter-list.v1`, `home-profile-list.v1`,
  `home-profile-edit.v1` (profile ones need Knowledge); shapes in `src/protocol/types.ts`.
- Reads: `home.status` (phase, readiness, recovery, chapter, `openSessionId`, `live`,
  `waitingForUser`, `taskRecovery`, memory counters; derived, never stored), `home.context`,
  `home.open`, `home.chapterList` (ledger, metrics and derived `contents`), `home.profileList`,
  `home.taskList`, `home.taskStatus`, `home.taskHistory`, `home.taskPermissions`.
- Receipted: `home.prompt`, `home.designate`, `home.disable`, `home.pauseMemory`,
  `home.resumeMemory`, `home.profileChange`, `home.reconfirmPermissions`, task controls.
- **Memory browser.** `home.memory.view` (newest-first lines, `part`, `sessionId` filter,
  revision-bound cursors) and `home.memory.evidence` (canonical text pages ≤ 24,000 chars)
  are disposable reads that never admit compactor calls or prompts. Each read proves the
  frozen cut through cached per-chapter proofs (`HomeSourceProofs`); nothing partial returns.
  Browser items carry optional canonical-derived display facts (tool name, short target, call count,
  status); these are disposable client labels, never a persisted or model-facing memory schema.
  Page admission reserves their bounded byte budget before canonical enrichment.
- **Clients.** iOS and `tron-chat` (`/home`: `HOME_USAGE`) open `openSessionId`, send `home.prompt`.

## Invariants

- The record's chapter ledger is Home's only identity; an unusable record never means no Home.
- One writable chapter; sealed chapters never mutate; nothing redirects to another chapter.
- Accepted input is never replayed; uncertain receipts and deliveries stay fenced.
- Memory text is request-local evidence, never instructions, never persisted in JSONL.
- Typed role queues and worker thinking are the machine-routing authority; learned
  delegation notes are never parsed as queue configuration. Explicit task choices
  remain overrides. `home-task-worker-model.e2e.test.ts` exercises a contradictory
  active v2-placed Knowledge note while the actual worker follows the typed settings.

## Entry points

`HomeOwner` (`home-owner.ts`), `RuntimeRegistry.create(cwd, "home")`, the `home.*` handlers,
`tron-home` and `tron-home-research` extensions, `HomeTaskDispatcher`, `WakeInboxOwner`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `home.<outcome>`; `home.client-control`; `home.route-bound`; `home.resources-reload` | info; `unavailable`, `refused`, failed controls and `resources-reload` warn | Designation outcomes (`designated`, `enabled`, `disabled`, `unavailable` or `refused` with a coded `reason`), pause/resume-memory owner outcome (`operation`, `reason`), route binding `category` (`fresh`, `replay`, `open`), a live global-resource reload or watch that failed (`watch-failed` or a coded `reason`). Never IDs, paths, models or memory text |
| `home.chapter-rollover`; `home.chapter-recovery`; `home.chapter-refused`; `home.chapter-limit-stop`; `home-chapter-limit-stop-failed` code on `session.diagnostic` | info; refusals, limit stops and the failure warn; the `session.diagnostic` code is a session event, not a log record | Rollover `reason` (soft or hard byte/entry limit) and `chapterOrdinal`; recovery `reason` (`absent`, `adopt`, `conversation-published`, `settings-from-live`, `settings-from-cold`); refusal `reason` (`hard-bytes`, `sealed-write`, `ownership-changed`, …); a running activation stopped at the hard limit with crossing and settled bytes/entries; a chapter-limit Stop that did not settle keeps its admission fence |
| `home.activation`; `home.activation-refused`; `home.memory-ingest`; `home-memory-revision-changed` / `home-memory-source-unavailable` reason on `rpc.error` | info; refusals and failures warn | An activation's first provider request (`effectiveTokens`, `contextWindow`, view lines/bytes, `excludedMessages`, `durationMs` readiness wait); a request refused before any provider call (`reason`, bounded `detail`; `memory-usage-limit` re-arms once the limit lapses); a memory-ingest failure `reason`; a memory-browser read that lost its revision fence or could not prove its sources (coded `cause`) |
| `home.task.store-refused`; `home.task.authorization`; `home.task.transition`; `home.task.checkin`; `home.task.spend`; `home.task.dispatch-stage`; `home.task.producer-refused`; `home.task.report-reminder` | info; refusals and slow, timed-out, cancelled or abandoned-cleanup-failed dispatch stages warn | Keyed by `taskHash`/`operationHash`, never intent, report or path ([tasks.md](tasks.md)): task-store refusal `reason` (fenced until the next start, in `home.status.taskRecovery`); scope, grant and decision transitions; durable `pending`/`active`/`terminal` transitions with `reason`, `failureCause`, `errorCode`; check-in `attention`; deduplicated token spend; a `delegate` admission `stage` slow (≥ 5 s), timed out (60 s), cancelled or `abandon-failed` (the late resource cleanup rejected); a refused detached-capable producer (`reason: unverified-provider` diagnoses a reviewed-version/pin mismatch before launch); the single report-only continuation |
| `home.task.control`; `home.task.runaway-stop`; `home.task.detached-work`; `home.task.subagents`; `home.taskStatus.subagentRuns`; `home.taskStatus.ownerSettlement` | info; runaway stop and detached work warn; `home.taskStatus.*` are read-only status fields | Steer, interrupt and Stop `disposition` (`accepted`, `persisted`, `refused` with a finite `reason`; interrupt `calls`); the deadline cancel-and-join outcome; detached work outliving settlement (outcome unknown); subagent `started`, `stoppedAtEnd`, `noticesUndelivered`; the exact live runs that report and Stop select; the owner-settlement proof (`null` is unproven) |
| `home.task.inbox`; `home.wake`; `home.inbox.admission-slow`; `home-inbox-settlement-failed` code on `session.diagnostic`; `home-worker-attention-failed` | info; refused wakes, slow admission (≥ 2 s) and failures warn | Wake-inbox transitions (`eventHash`, `state`, coded `reason`); each wake decision (`admitted`, `deferred`, `refused` with `reason`); result delivery into an activation (`delivery`, `durationMs`); a durable terminal whose inbox settlement rejected (session event); a failed acknowledgement of a new worker's earlier completion |
| `TRON_SETTINGS_OUTCOME_PROOF_DEFERRED` | warning | A settings delivery's canonical proof failed; its outbox remains retained for later proof, without exposing request IDs or paths |
| `host.pressure` | info; warning at `critical` | A Home-status read saw the host-pressure level change: `state`, `transition`, CPU busy, loop utilization and load per CPU; it informs and never holds a worker back |

## Verify
`scripts/tron verify --module gateway/home` or `scripts/tron test gateway <file>` covers
`src/modules/home/*.test.ts` and `src/sessions/home-*.test.ts` (nested suites add `--config vitest.nested.config.ts`).
Boundary fixtures read session presence/files through Native; chapter metrics remain Home-owned.
The redelivery rollover case keeps the result pending across rollover, observes the
successor wake's acknowledgement, then waits for both `hasActiveAgentRun` and
`isBusy` to clear before proving logical prompting uses that successor without
duplicating the result or changing sealed bytes.
Managed queue persistence allows 60 s for two cold reopens; crash suites cover process abandonment, not power loss.
Backlog fixtures budget the full current Home catalog plus output reserve; the
never-fit case must still prove a large report is referenced, its small successor
arrives inline in order, and bounded immutable pages reconstruct the exact report.
`input-admission.integration.test.ts` locks unpersisted trigger release to pending before terminal settlement; `session-profile.integration.test.ts` locks one-shot creation and live append classification.

## Not here

Episodic memory internals ([gateway/episodic](../../episodic/README.md)), settings
keys ([settings-model.md](../../../docs/settings-model.md)), Knowledge, RuntimeSlot and the
generic session lifecycle ([Gateway README](../../../README.md)).
