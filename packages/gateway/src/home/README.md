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
  `tron-home-extension.ts` (`tron-home`: tools, operating context, cache-warming answer).
- **Memory, research, profile:** `home-memory*.ts`, `home-research-tools.ts`, `home-profile.ts`.
- **Tasks and wake inbox:** `home-task-*.ts`, `home-wake-inbox.ts`; contract in
  [home-tasks.md](../../docs/home-tasks.md). Also `home-diagnostic.ts`, `host-pressure.ts`,
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
- **Workspace.** `<tronHome>/gateway/home/workspace` (`0700`, empty) is recorded **untrusted**;
  `noExtensions`, `noContextFiles` and an always-false project trust are a second guard.
  User-level skills and prompt templates feed the composer only (`disableModelInvocation`);
  they reach the model only when the user inserts them.
- **Identity.** Every chapter presents the title **Home** in snapshots, catalog cuts and
  notifications, without rewriting JSONL; `session.list` (`scope: "user"`) omits all chapters.
  Search, `session.open` by id and `scope: "all"` are unfiltered; a sealed chapter opens
  read-only.
- **Rollover.** At a quiescent boundary, the soft limit (24 MiB or 50,000 entries) seals the
  active chapter and reserves a successor; before a `home.prompt` receipt binds, the hard limit
  (200 MiB or 100,000 entries) does the same. Every physical prompt rechecks the hard limit in
  its slot lane and refuses without redirecting. A running activation crossing it is stopped
  with reason `chapter-limit`. Only the next `home.prompt` materializes a reserved chapter.
- **Sealed chapters** refuse every mutation (`conflict` `sealed-chapter`); a bound slot
  refuses identity replacement (`home-identity-replacement`).
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

HomeOwner owns one `EpisodicMemory` ([episodic-memory.md](../../docs/episodic-memory.md))
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

- Capabilities: `home.v1`; `home-memory-view.v1`, `home-chapter-list.v1`;
  `home-profile-list.v1` and `home-profile-edit.v1` (Knowledge owner only). Params are strict;
  mutations carry a `commandId` receipt. Shapes live in `src/protocol/types.ts`.
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
- **Clients.** iOS and `tron-chat` (`/home` commands: `HOME_USAGE`) open `openSessionId` and
  send `home.prompt`, never `session.prompt` to a sealed chapter.

## Invariants

- The record's chapter ledger is Home's only identity; an unusable record never means no Home.
- One writable chapter; sealed chapters never mutate; nothing redirects to another chapter.
- Accepted input is never replayed; uncertain receipts and deliveries stay fenced.
- Memory text is request-local evidence, never instructions, never persisted in JSONL.
- Signals carry no canonical IDs, paths, transcript or free text.

## Entry points

`HomeOwner` (`home-owner.ts`), `RuntimeRegistry.create(cwd, "home")`, the `home.*` handlers,
`tron-home` and `tron-home-research` extensions, `HomeTaskDispatcher`, `WakeInboxOwner`.

## Signals

`home.route-bound`, `home.client-control`, `home.task.*`, `home.inbox.*` and Home transition
signals from `home-diagnostic.ts`; [observability.md](../../docs/observability.md) owns them.

## Verify

`scripts/tron verify --module gateway/home`, or `scripts/tron test gateway <file>` for
`src/home/*.test.ts` and `src/sessions/home-*.test.ts` (nested provider suites add `--config
vitest.nested.config.ts`). Crash suites cover process abandonment, not power loss.

## Not here

Episodic memory internals ([episodic-memory.md](../../docs/episodic-memory.md)), settings
keys ([settings-model.md](../../docs/settings-model.md)), Knowledge, RuntimeSlot and the
generic session lifecycle ([Gateway README](../../README.md)).
