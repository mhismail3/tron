# Collapsed Modular Engine 100% Hardening Scorecard And Implementation Playbook

Status: active implementation handoff

Created: 2026-05-28

Canonical previous checkpoint:
`packages/agent/docs/capability-orchestration-test-scorecard.md`

## Summary

This document is the next-phase scorecard and implementation playbook for hardening
Tron against the north-star architecture: the agent harness is the backend.

The prior capability-orchestration scorecard reached `99/100` for the paths that
were exercised during the first `execute` portal hardening pass. That score is
useful historical evidence, but it should not be treated as proof that every
collapsed-engine foundation is complete.

This new scorecard starts from a stricter standard. It measures whether Tron is
really a modular, resilient, extensible backend where every meaningful
participant composes through the same substrate:

- workers;
- functions;
- triggers;
- state;
- queues;
- streams;
- resources;
- grants;
- approvals;
- providers;
- memory;
- subagents;
- observability;
- thin clients.

Initial score: **45/100 provisional**.

Target score: **100/100** only after all foundational planes have real scenario
proof, DB reconstruction, root-cause fixes for failures, and no unclassified
dead, legacy, fallback, or backward-compatibility logic.

## Operating Rules

Every test must be grounded in a real, high-signal use case. Do not run arbitrary
demo prompts just to increase the count.

For every scenario:

1. Read this scorecard first.
2. Choose the highest-value unproven or failing scenario.
3. Run the scenario through the iOS simulator and real dev server unless the
   scenario explicitly requires a deterministic Rust fixture.
4. Observe the UI result.
5. Query `~/.tron/internal/database/tron.sqlite`.
6. Classify the result as `passed`, `failed`, `blocked`, or `inconclusive`.
7. If failed, stop broad testing and isolate the root cause.
8. Add or identify the smallest focused automated test.
9. Fix only the owning module.
10. Remove nearby dead, fallback, legacy, or compatibility code if discovered.
11. Rerun the exact same scenario.
12. Update this scorecard with evidence, score delta, and fix commit.
13. Commit only at logical checkpoints after code, tests, docs, and scorecard
    are consistent.

No workaround counts as fixed unless the database proves the corrected path uses
canonical substrate primitives.

## Current Score

Current score: **60/100 provisional**

This score is intentionally conservative. Tron has strong evidence for many
covered `execute` paths, but the full collapsed-backend architecture still needs
end-to-end proof across live workers, trigger composition, stream behavior,
actual memory retain, provider parity beyond simple tool calls, runtime
interruption, and resource failure states.

### Axis Scores

| Axis | Points | Current | Full Credit Requires |
|---|---:|---:|---|
| Execute portal ergonomics | 10 | 8 | One `execute` tool resolves, prepares, corrects, runs, pauses, replays, and explains failures without fragile model guessing |
| First-party capability usefulness | 10 | 9 | Filesystem, process, git/worktree, web, browser/display, logs, settings, model, memory, prompt, resource, state, queue, stream, worker, and module capabilities work in real tasks |
| Worker/function/trigger substrate | 14 | 7 | Live workers register functions/triggers, update discovery, invoke, stream, heartbeat, disconnect, and clean up without restart |
| Multi-capability orchestration | 12 | 9 | Agents chain read/search/edit/run/state/resource/approval/queue/subagent operations in realistic workflows |
| Resource truth and durability | 10 | 7 | Durable outputs, resource versions, CAS, hashes, discard, damaged state, and idempotency are proven through live paths |
| Safety, grants, and approvals | 10 | 6 | Safe work runs autonomously; risky work gates correctly; denial/replay/revocation/expiry leave no invalid side effects |
| Runtime resilience | 10 | 5 | Restart, reconnect, queue retry, approval pause, cancellation, partial failure, and cleanup are robust |
| Observability and auditability | 8 | 5 | Every scenario is reconstructable from DB invocation/event/log/resource/approval/queue/stream records |
| Provider parity | 6 | 3 | OpenAI, Anthropic, Gemini, and Ollama expose equivalent `execute` behavior for core scenarios |
| Code modularity and simplification | 10 | 1 | No central spaghetti, no unclassified dead/fallback/compat logic, clear ownership, and large files decomposed where useful |

Total: **60/100**

## Scoring Rules

- `+1` for a simulator-tested scenario with DB proof and no code changes needed.
- `+1` to `+2` for a scenario that exposes a bug, receives a root-cause fix, and
  passes the exact retest.
- `+0` for inconclusive tests, prompt-entry mistakes, screenshot-only evidence,
  or tests that do not prove a substrate invariant.
- No axis can receive full credit until it has at least:
  - one success path;
  - one failure path;
  - one replay or idempotency path where relevant;
  - one database reconstruction note.
- Do not award points for code that only works through fallback readers,
  compatibility aliases, client-owned policy, or side-channel state.
- Lower the score if a regression invalidates prior evidence.

## Failure Layer Taxonomy

Every failure must be assigned exactly one primary layer:

- `model_guidance`
- `execute_resolution`
- `execute_correction`
- `schema_or_recipe`
- `target_capability`
- `provider_runner`
- `grant_or_approval`
- `resource_truth`
- `queue_or_trigger`
- `stream_or_state`
- `worker_lifecycle`
- `runtime_reconnect`
- `ios_rendering`
- `observability_gap`
- `code_ownership`

A failure is not fixed until:

- the root layer is identified;
- the same scenario passes after the fix;
- database evidence proves the canonical substrate path was used;
- this scorecard records the fix commit.

## Database Evidence Checklist

After each simulator scenario, query or inspect the relevant rows in:

- sessions and session events;
- engine invocations;
- capability audit events;
- approvals;
- resources and resource versions;
- queue rows;
- stream rows;
- state rows;
- server logs;
- ingested iOS logs.

The evidence note must identify:

- session id;
- parent invocation id;
- child invocation ids;
- target capability ids;
- approval ids, if any;
- resource refs, if any;
- queue/stream/state refs, if any;
- any failed probe calls;
- final outcome.

## Scenario Ledger

| Scenario | Name | Status | Score Delta | Session Id | DB Evidence | Failure Root Cause | Fix Commit | Retest |
|---|---|---|---:|---|---|---|---|---|
| RWO-N1 | Repo understanding and discovery | passed_after_fix | +2 | compaction failure: `sess_019e728b-bfa5-7a03-98e7-5b5f5940fc78`; path-guidance failure: `sess_019e72a5-eda3-7f51-8628-bc043336296d`; passing retest: `sess_019e72b6-7237-7391-a178-c669e7d09cf5` | See 2026-05-29 result note below. Passing retest used 48 `capability::execute` child invocations; target functions were `filesystem::list_dir` (7), `filesystem::read_file` (24), and `filesystem::search_text` (17). Zero failed invocations, zero approvals, zero `compact.*` events, no session-scoped server log rows, and only substrate prompt-history plus final `agent_result` resource refs. | Fixed `stream_or_state`: no-op compaction no longer persists boundaries or injects notices. Fixed `model_guidance`: execute metadata/schema now tells models to list only known directories and locate uncertain filesystem paths with `find`, `glob`, or `search_text` before listing/reading. | `1c76b7bd1` | Passed exact prompt after rebuilt dev server PID 4541; DB reconstruction matches simulator UI and final answer cited real worker/function/trigger files. |
| RWO-N2 | Practical code change workflow | passed_after_fix | +2 | first failure: `sess_019e72c3-e190-7ba2-b447-8debb4e36054`; exact retest pass: `sess_019e72e6-88a4-71c1-bc85-787e86df0235`; replay failure: `sess_019e72ea-c4e7-7842-82bb-654538fa3ce5`; replay retest pass: `sess_019e72f3-ee99-7a91-84ef-e3f47604a2ff` | See 2026-05-29 RWO-N2 result notes below. Exact retest passed with 3 target `capability::execute` calls, `filesystem::write_file` 1, `filesystem::read_file` 1, `materialized_file::update` 1, `resource::create` 1, and 0 failed invocations/approvals/compact events/log rows. Replay retest passed with 2 `filesystem::write_file` rows under session-scoped `rwontwoalpha`, one `filesystem::read_file`, one materialized file resource/version, 0 failed invocations, 0 approvals, 0 compact events, 0 logs, 1 completed queue drain, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | Fixed `schema_or_recipe`: new-file guidance/search now prefers `filesystem::write_file` over missing-file `apply_patch`. Fixed `stream_or_state`: runtime event persistence advances from DB sequence truth before preassigned events. Fixed `resource_truth`: file-content mutations use session-scoped idempotency so the same key cannot replay another isolated worktree path. | `87f368dd6` | Passed exact prompt after rebuilt dev server PID 22402 and passed replay subcheck after rebuilt dev server PID 27362. DB reconstruction matches simulator UI and proves the replay reused one resource/version inside the active session. |
| RWO-N3 | Safe process plus filesystem composition | passed | +1 | `sess_019e72fd-5e00-75d1-b58f-a9853a621daa` | See 2026-05-29 RWO-N3 result note below. The run used 2 successful `capability::execute` invocations, 1 successful `process::run`, 1 successful `filesystem::read_file`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one completed `agent::prompt_queue_drain`, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; no code changes required | n/a | Passed exact prompt on the real dev server. `process::run` used `executionMode = read_only`; README first line matched the filesystem read. |
| RWO-N4 | Web research capability | passed | +1 | `sess_019e7301-b34f-7240-99aa-ea6d6cdac1c2` | See 2026-05-29 RWO-N4 result note below. The run used 2 successful `capability::execute` invocations, 1 successful `web::search`, 1 successful `web::fetch`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one completed `agent::prompt_queue_drain`, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; source returned an HTTP 403 Cloudflare/JS challenge through the web fetch capability and the agent reported it without fallback browsing | n/a | Passed exact prompt on the real dev server. Search returned official `https://platform.openai.com/docs/models`; fetch targeted that URL through `first_party.web.v1.fetch`; no browser/client-owned path was used. |
| RWO-N5 | Browser and display capability probe | passed | +1 | `sess_019e7308-762f-7691-987e-ea33f8eac543` | See 2026-05-29 RWO-N5 result note below. The run used 6 successful `capability::execute` invocations, 1 successful `browser::get_status`, 2 successful `capability::inspect`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one completed `agent::prompt_queue_drain`, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; no code changes required | n/a | Passed exact prompt on the real dev server. `browser::get_status` returned `hasBrowser = false` and `isStreaming = false`; `display::stop_stream` was inspected but not invoked; no browser/client-owned action path was used. |
| RWO-N6 | State, queue, stream, trigger chain | passed | +1 | `sess_019e730c-0b78-7b73-8598-80a75810a394` | See 2026-05-29 RWO-N6 result note below. The run used 21 successful `capability::execute` invocations, 7 successful `capability::inspect`, 1 successful `state::set`, 1 successful `state::get`, 1 successful `queue::enqueue`, 1 successful `queue::list`, 1 successful `stream::subscribe`, 1 successful `stream::poll`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one ready `agent.test` queue row, one session-scoped state row, one `agent.test.execute` stream subscription, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; no code changes required | n/a | Passed exact prompt on the real dev server. State write/read matched revision 1; queue enqueue/list returned the ready queued item; stream subscribe/poll succeeded and found no events; publish capability was not found. |
| RWO-N7 | Live worker extensibility | passed_after_fix | +2 | conformance failure: `sess_019e732f-c5e0-7bf3-8130-9da7d39a3deb`; trigger retest with cleanup gap: `sess_019e733b-af69-7f93-bb15-7a717d906aef`; cleanup-fixed retest: `sess_019e7341-8eac-7bb3-97bc-efd16de60757`; trigger-guidance retest: `sess_019e735b-9168-7b43-bb95-56fb6cacca43` | See 2026-05-29 RWO-N7 result note below. Trigger-guidance retest used one `needs_selection` execute row for trigger-id metadata guidance, one successful `capability::execute` row, one successful target `rwo_n7::echo` invocation, catalog revisions 389-394, 0 approvals, 0 `compact.*` events, 0 session logs, and expected post-disconnect `CAPABILITY_NOT_FOUND` cleanup probes after unregister. | `execute_resolution`: session-generated implementations stayed `candidate` and were not binding-selectable. `queue_or_trigger`: visible trigger metadata was not projected through capability discovery. `worker_lifecycle`: stale session-scoped registry plugin/implementation rows stayed healthy after disconnect. `execute_resolution`: explicit trigger-id targets returned generic not-found instead of metadata-only guidance naming the related function target. | `0aabb48a2`; trigger-guidance checkpoint in this commit | Passed after rebuilt dev server PID 63286. Trigger-id target now returns `needs_selection`/`trigger_metadata_target` with suggested target `rwo_n7::echo`, no child invocation, and no trigger-id aliasing. Post-disconnect registry sync removed the session-generated implementation/plugin rows and direct execute returned expected `CAPABILITY_NOT_FOUND`. |
| RWO-N8 | Module package activation | passed_after_fix | +2 | setup and first retest: `sess_019e7385-341e-7f30-8176-6b93396a6dbc`; final activation retest: `sess_019e7398-5d77-7d01-9c2a-465589dade48` | See 2026-05-29 RWO-N8 result note below. The setup run registered source/package, verified source, approved source, configured, activated, health-checked, disabled, and inspected the deterministic package. The final retest used 6 successful `capability::execute` rows, successful `module::activate`, `worker::spawn`, `module::check_health`, two `rwo_n8_20260529113609::health` invocations, duplicate activation replay, `module::disable`, `sandbox::stop_spawned_worker`, and `module::inspect_package`; 0 failed invocations; 2 executed approvals; disabled activation resource; revoked derived grant; no session logs. | `execute_correction`: nested wrapper cleanup stripped target-owned `arguments.mode` from `module::check_health`. `worker_lifecycle`: worker guide Python blocked in `recv_json` and stopped heartbeating while idle. `execute_resolution`: `worker::spawn` issued `engine_issued` scoped tokens, but binding selection only treated `session_scoped` session-generated functions as healthy. | `ae1b153bf` | Passed after rebuilt dev server PID 76020 with simulator booted. Direct fixture execute `019e7398-b60b-71b1-8e26-1ac35fcad2a1` selected `session_generated.rwo_n8_20260529113609.demo_echo` and invoked child `019e7398-b6f4-7b81-9c42-3acf2736499a`; disable stopped PID 77144 and revoked grant `sandbox-worker:rwo-n8-worker-20260529113609:019e7398-8526-7ff1-bbd5-280708370bf8`. |
| RWO-N9 | Subagent fan-out/fan-in | passed_after_fix | +2 | failed first run: `sess_019e73a5-c2ae-7fe3-b9b9-86131b2f7156`; passing retest: `sess_019e73ae-4645-7f03-bca5-fad68c3959c4` | See 2026-05-29 RWO-N9 result note below. The passing retest used 10 parent `capability::execute` rows, 2 non-blocking `agent::spawn_subagent` target rows, 4 `agent::subagent_status` rows, 2 `agent::subagent_result` rows, 8 child `capability::execute` rows, 2 deterministic `agent_result:subagent:*` resources, 1 final parent `agent_result`, 0 failed invocations, 0 approvals, 0 `compact.*` events, and 0 session-scoped log rows. | Primary `resource_truth`: completed blocking subagents did not write deterministic `agent_result:subagent:*` resources, so result/status could fall back to in-memory manager state. Secondary `schema_or_recipe`: omitted `blockingTimeoutMs` was coerced into a blocking wait and the contract did not name the result capability, so fan-out models were guided toward sequential work. | this checkpoint | Passed exact prompt after rebuilt dev server PID 83613 with simulator booted. Parent spawned child sessions `sess_019e73ae-7618-7e92-b86a-19a4f50c605a` and `sess_019e73ae-8413-7830-9a49-3c87c98180be` before waiting, status-polled both through `agent::subagent_status`, collected both through `agent::subagent_result`, and reported lineage/capabilities. A model-chosen `process::run sleep 10` was used only as a timer between canonical status polls; no hidden client or runner side channel was used. |
| RWO-N10 | Memory auto-retain | passed | +1 | `sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6` | See 2026-05-29 RWO-N10 result note below. The run used the real dev server and booted simulator evidence, kept the default auto-retain interval of 10, recorded 9 explicit `memory::auto_retain_fire` skips with `reason = below_threshold`, then fired on the tenth user message with `status = retaining`. The terminal `memory.retained` event recorded 4 resource refs: memory journal artifact, session materialized projection, memory-rule artifact, and rule materialized projection. DB evidence shows 0 failed invocations, 0 approvals, 0 `compact.*` events, 10 completed prompt queue drains, and resource versions with hashes/lifecycle state. | none; no code changes required | n/a | Passed without changing settings or using a side channel. Retain truth was engine-owned: `memory.retained` event seq 152, parent auto-retain invocation `019e73bb-209f-7561-912f-909dfe5f6e5a`, trace `019e73ba-fe7e-7511-ab2b-7275bfbecf3b`, and resource refs were produced by `artifact::create`, `materialized_file::update`, and `resource::link` children under that invocation. |
| RWO-N11 | Resource failure matrix | pending | 0 | | | | | |
| RWO-N12 | Approval and grant boundary | pending | 0 | | | | | |
| RWO-N13 | Runtime resilience | pending | 0 | | | | | |
| RWO-N14 | Provider full parity | pending | 0 | | | | | |

## Scenario Details

### RWO-N1: Repo Understanding And Discovery

Prompt:

```text
Use only execute. Inspect this repo enough to explain the worker/function/trigger architecture. Do not answer from memory. Cite files inspected and list every capability used.
```

Expected:

- Uses filesystem discovery, search, and read capabilities.
- No approval.
- No durable resources from target filesystem capabilities; ordinary
  substrate-owned prompt-history or final `agent_result` records are acceptable
  only if documented.
- No failed probe calls.
- Answer cites current code or docs.

Database proof:

- Parent session id.
- Child invocations for `capability::execute`.
- Child target functions.
- No approvals.
- No failed probe calls.
- No unexpected process calls unless justified.

2026-05-29 result:

- Initial simulator run `sess_019e728b-bfa5-7a03-98e7-5b5f5940fc78`
  exposed a `stream_or_state` failure before broader testing continued. The DB
  contained 13 `compact.summary_staging` and 13 `compact.boundary` events even
  though every boundary had `summarizedTurns = 0`, `compressionRatio = 1.0`, and
  several `compactedTokens` values greater than `originalTokens`.
- Root cause was in the compaction owner modules:
  `runner/context/compaction_engine.rs` returned `success: true` for an empty
  summarization window, and `runner/agent/compaction_handler.rs` injected the
  skill notice, persisted a boundary, and reset the trigger for that no-op.
- Focused regression coverage added:
  `has_summarizable_messages_false_for_single_preserved_turn`,
  `execute_skips_when_all_within_preserve_window`, and
  `execute_skips_when_summary_would_not_reduce_context`, plus
  `noop_compaction_persists_neither_event`.
- Intermediate retest `sess_019e7298-92ab-70a2-88d0-9f17b1b22510` used the exact
  prompt in a new iOS simulator session against rebuilt dev server PID 72170 and
  showed 0 failed invocations and 0 `compact.*` events.
- Current-binary retest `sess_019e72a5-eda3-7f51-8628-bc043336296d` ran the
  exact prompt against rebuilt dev server PID 78918. It verified the compaction
  fix on current code: 0 `compact.*` events despite crossing the previous
  threshold (`last_turn_input_tokens = 78570`). DB proof: 46
  `capability::execute` invocations, 26 `filesystem::read_file`, 16
  `filesystem::search_text`, 1 successful and 1 failed `filesystem::list_dir`, 1
  `filesystem::glob`, 1 `filesystem::find`, 0 approvals, no session-scoped
  server log rows, and final answer cited inspected files.
- Active blocker: the current-binary retest failed RWO-N1 pass criteria because
  one `filesystem::list_dir` target used guessed path
  `packages/agent/src/domains/worker` and failed with `FILE_NOT_FOUND`. The
  owning layer was classified as `model_guidance`. Focused coverage added to
  `execute_schema_teaches_target_call_shape_and_complete_payloads` now asserts
  that model-facing execute metadata/schema instructs filesystem repo discovery
  to list only known directories and to use `filesystem::find`,
  `filesystem::glob`, or `filesystem::search_text` before listing or reading
  uncertain paths.
- Passing retest `sess_019e72b6-7237-7391-a178-c669e7d09cf5` used the exact
  prompt in a new iOS simulator session against rebuilt dev server PID 4541.
  Parent run invocation was
  `019e72b6-ae5e-7ef1-8c2a-c3b293c5a356`. The 48 child
  `capability::execute` invocation ids were:
  `019e72b6-bfa1-7622-8cdf-3a83b67daaa8`,
  `019e72b6-c7e4-7151-adc3-5f132dd055ff`,
  `019e72b6-d026-7d03-a581-761491f38949`,
  `019e72b6-ded9-7b60-b5b0-4c0e3606f9a3`,
  `019e72b6-dfbe-73d2-bfc6-b1af42d09f11`,
  `019e72b6-e0aa-7cc3-ad60-d7db258b3887`,
  `019e72b6-fbcf-7592-ba01-89b709159f25`,
  `019e72b6-fcc4-7ca2-890b-e4d080550079`,
  `019e72b6-fda7-7133-89a9-6d8c89f776a3`,
  `019e72b7-11d5-7531-9d20-f506940d135f`,
  `019e72b7-12b0-7442-94bd-778e783687bb`,
  `019e72b7-1390-7881-8fb4-967dde083604`,
  `019e72b7-1d5c-7831-bd26-4d9003a9d454`,
  `019e72b7-49f8-7393-9ec5-e324d3f54f1e`,
  `019e72b7-4aff-7260-a4d5-57301b2d09f9`,
  `019e72b7-4bec-73f0-9d07-9de6cbabe9a9`,
  `019e72b7-553f-7bc3-972c-11df669b3998`,
  `019e72b7-6013-7572-92df-9c35a1fc7346`,
  `019e72b7-71c9-7711-9711-d3dc04777e0e`,
  `019e72b7-72ce-74c2-8012-f032559ee384`,
  `019e72b7-7445-7b41-9a1f-7dcd0bd95920`,
  `019e72b7-90e5-7393-bfdf-fbf1e3288d4e`,
  `019e72b7-91cb-7021-87b7-a12eda94b04d`,
  `019e72b7-92a8-7332-bd8d-e8b2d749e50e`,
  `019e72b7-9fa0-77c0-8677-e4b1217a4508`,
  `019e72b7-ab57-7d80-896d-1d47e169e787`,
  `019e72b7-c7a5-7211-bf93-c36b9fdc8d19`,
  `019e72b7-c8a5-7a40-9f7e-76076be0bc7e`,
  `019e72b7-c983-7563-bd4c-9be925d11b1f`,
  `019e72b7-daf9-76c0-9562-f389c3102bd6`,
  `019e72b7-dbe6-7df3-aa73-b13b5fe9bc74`,
  `019e72b7-dcd6-7123-8318-96038fc38324`,
  `019e72b7-e870-7fa0-a9cc-b6d41171d618`,
  `019e72b7-fd2f-7860-a357-1a1231ec35bb`,
  `019e72b7-fe20-7e20-863f-858c83174b17`,
  `019e72b7-fefe-78f3-9e1c-0ac36de3963a`,
  `019e72b8-161e-7012-8220-32ce92322983`,
  `019e72b8-171a-76a1-9b07-e31cdd3bb23c`,
  `019e72b8-1805-7101-8af4-07f13d786715`,
  `019e72b8-2768-7380-bd88-8b950dac0e25`,
  `019e72b8-335a-7a42-983f-18d095d12364`,
  `019e72b8-4d52-7c93-b60a-3134d417c4ab`,
  `019e72b8-4e3a-7d32-982f-d5b87a96b041`,
  `019e72b8-4f1c-7493-a4e6-6ecafc4cf7ed`,
  `019e72b8-5a4f-77a1-a2e5-6eff33de3f85`,
  `019e72b8-6bda-7760-9d36-f1b92a0b6986`,
  `019e72b8-7800-77c0-ae2b-7d76602fe27f`, and
  `019e72b8-82f0-7953-92ef-888eac1c98c4`.
- Passing retest DB proof: 27 turns, `last_turn_input_tokens = 75634`, 0
  failed engine invocations, 0 `compact.*` events, 0 approvals, 48
  `capability.execute` audit events, 48 `capability.orchestration` audit
  events, target counts `filesystem::list_dir` 7, `filesystem::read_file` 24,
  and `filesystem::search_text` 17. Queue evidence was one completed
  `agent::prompt_queue_drain` row. Stream evidence was session-scoped
  `events.session`, `agent.runtime`, and `queue.lifecycle` rows. State and
  session-scoped server log queries returned no rows. The only new session
  resource was final `agent_result`
  `res_019e72b8-daec-7b92-a40e-2253b39f9d47`; prompt-history refs were normal
  substrate-owned updates. Filesystem target invocations produced no resource
  refs, and no approval or mutation-capability path was used.
- Non-blocking wording observation: the final answer listed the target
  capabilities and also mentioned `multi_tool_use.parallel`. A DB search found
  that string only in the final text, not in model tool-call payloads or engine
  invocations; every recorded model tool call name was `execute`, so this is not
  treated as a substrate failure for RWO-N1.

Score axes:

- Execute portal ergonomics.
- First-party capability usefulness.
- Observability and auditability.

Failure focus:

- intent-only discovery fails;
- wrong repo/worktree;
- model answers from memory;
- filesystem capability shape confusion;
- missing DB reconstruction.

### RWO-N2: Practical Code Change Workflow

Prompt:

```text
Use only execute. Find the collapsed-engine hardening scorecard, add one harmless scratch note to a docs sandbox or scratch file, verify it by reading it back, and report resource refs. Use idempotency.
```

Expected:

- Searches and reads before editing.
- Applies a bounded mutation through canonical filesystem/resource capability.
- Returns resource refs.
- Verification read succeeds.
- Repeating with the same idempotency key does not duplicate edits or resource
  versions.

Failure focus:

- patch shape confusion;
- missing resource refs;
- duplicate idempotency behavior;
- over-approval for low-risk bounded edit;
- direct file side channel.

2026-05-29 first attempt:

- Simulator session `sess_019e72c3-e190-7ba2-b447-8debb4e36054` ran the exact
  prompt against the rebuilt dev server. The run found the scorecard, created
  `docs-sandbox-note.txt` through `filesystem::write_file`, read it back
  successfully, and reported materialized file resource
  `materialized_file:0a550143ecb7e15d37b68f8be190fcf1e55be965987825c6236b96fc49be005a`
  version `ver_019e72c4-bf86-78e3-83ee-c1746cf33e1b`.
- The scenario still failed because the DB contains one failed probe before the
  recovery: `filesystem::apply_patch` invocation
  `019e72c4-b136-7393-8cae-5499e8d52260`, parent `capability::execute`
  invocation `019e72c4-b052-7ca3-a863-5e234b0f3d6a`, returned
  `FILE_NOT_FOUND` for nonexistent `docs-sandbox-note.txt`.
- DB evidence: 8 successful `capability::execute` invocations, target counts
  `filesystem::find` 4, `filesystem::read_file` 2, `filesystem::write_file` 1,
  `filesystem::apply_patch` 1 failed, `materialized_file::update` 1,
  `artifact::create` 1, and `resource::create` 1 final `agent_result`. There
  were 0 approvals, 0 `compact.*` events, one completed
  `agent::prompt_queue_drain` row, session-scoped `events.session`,
  `agent.runtime`, and `queue.lifecycle` stream rows, no matching state rows,
  and no session-scoped server log rows.
- Primary failure layer: `schema_or_recipe`. `filesystem::apply_patch` failed
  closed correctly for a missing file; the guidance/recipe boundary should make
  creation-vs-patch selection unambiguous enough that a scratch-file create path
  starts with `filesystem::write_file` or an existing-file append target.
- Smallest focused follow-up: add or identify a filesystem contract/recipe test
  proving new-file creation guidance points models to `filesystem::write_file`
  and that `filesystem::apply_patch` is only selected for existing files or
  exact replacement/append operations on known paths.

2026-05-29 exact retest after create-vs-patch fix:

- Focused tests covered the owning guidance layer:
  `filesystem_recipes_separate_new_file_creation_from_existing_patch`,
  `first_party_recipe_parity_covers_common_direct_capabilities`, and
  `lexical_search_returns_recipes_for_common_first_party_queries`. The registry
  lexical scorer now treats identifier parts as parts instead of matching
  `file` inside `filesystem`, which keeps `filesystem::write_file` ahead of
  `filesystem::create_dir` for scratch-file creation requests.
- Simulator session `sess_019e72e6-88a4-71c1-bc85-787e86df0235` reran the exact
  RWO-N2 prompt after rebuilt dev server PID `22402`. DB evidence: 26 events, 5
  messages, 4 turns, 3 successful `capability::execute` invocations,
  `filesystem::find` 1, `filesystem::write_file` 1, `filesystem::read_file` 1,
  `materialized_file::update` 1, `resource::create` 1, 0 failed invocations, 0
  approvals, 0 `compact.*` events, and 0 session-scoped server log rows.
- The written scratch note used idempotency key
  `2026-05-29-collapsed-engine-scorecard-scratch-note-write` and produced
  `materialized_file:f1facb4d99a42a1a9a1eec5d24c76c88b085584647de34eeda4e2b611481a5eb`
  version `ver_019e72e7-2bfc-7ca2-baa3-71d1a6b423d5`, content hash
  `0b39f7bad10240a6c1243b39a327628d89ae56b5c6b02dc2df9ea61547a7ce87`.
  The final assistant message cited the resource ref/version/hash and confirmed
  the read-back.

2026-05-29 replay/idempotency subchecks:

- Simulator session `sess_019e72da-a3c1-7923-b37f-36d539f43ddd` exposed a
  runtime persistence failure while replay testing: after the first
  `filesystem::write_file`, a background hook/worktree auto-event advanced the
  DB sequence and a runtime-persisted assistant event reused an old in-memory
  sequence, producing `UNIQUE constraint failed: events.session_id,
  events.sequence`. Focused test
  `runtime_sequence_syncs_after_background_auto_append` now proves
  runtime-preassigned events call `EventPersister::append_with_runtime_sequence`,
  which syncs from DB max and retries sequence collisions.
- A simulator prompt-entry mistake corrupted a numeric idempotency key in one
  unscored replay attempt. It is treated as invalid prompt-entry evidence, not
  engine behavior.
- Simulator session `sess_019e72ea-c4e7-7842-82bb-654538fa3ce5` then exposed a
  real replay failure layer: the same `rwontwoalpha` key in a new isolated
  session replayed old invocation `019e72db-239a-76d3-9d02-77460eca4135` from a
  different session worktree and returned that old materialized path. The active
  session could not read the old path, so subsequent `filesystem::read_file` and
  `process::run` recovery attempts correctly failed scoped path checks. Primary
  failure layer: `resource_truth`; `filesystem::write_file` idempotency was
  system-scoped even though relative paths are session-worktree materializations.
- Focused regression
  `filesystem_write_file_idempotency_is_session_scoped_for_isolated_worktrees`
  now proves the same key/payload/path does not replay across isolated sessions,
  but does replay inside the same session without creating a duplicate
  materialized version. `filesystem::write_file`, `filesystem::edit_file`, and
  `filesystem::apply_patch` now use session-scoped engine-ledger idempotency;
  `filesystem::create_dir` stays system-scoped because the iOS workspace picker
  can create folders before a chat session exists.
- Passing replay retest: simulator session
  `sess_019e72f3-ee99-7a91-84ef-e3f47604a2ff` after rebuilt dev server PID
  `27362`. DB evidence: 26 events, 5 messages, 4 turns, 3 successful
  `capability::execute` invocations, `filesystem::write_file` 2 with
  `idempotency_scope_kind = session` and
  `idempotency_scope_value = sess_019e72f3-ee99-7a91-84ef-e3f47604a2ff`,
  second write `replayed_from = 019e72f4-5fbd-70a3-bcf6-4a47018b3b74`,
  `filesystem::read_file` 1, `materialized_file::update` 1, `resource::create`
  1, 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped
  logs, one completed `agent::prompt_queue_drain`, and stream rows for
  `agent.runtime`, `events.session`, and `queue.lifecycle`.
- Replay resource proof:
  `materialized_file:e6369e848ad94cdc101929e802b7a347ce3b3dea3609208bfc0db64f8c9fb8c2`
  has one version, `ver_019e72f4-5fbe-7a80-8637-2be6734aa7f7`, content hash
  `774a50e85956ac66c78a1eeaeb03b07ac9e02ccf34adfb0ffb27a38d5104d858`, scoped
  to the passing session. Final assistant message sequence 254 reported the
  content read back and confirmed the duplicate write reused the same
  resource/version.
- Score impact: RWO-N2 earns `+2` after root-cause fixes and exact/replay
  retests. Current score is 49/100. The next scenario is RWO-N3.

### RWO-N3: Safe Process Plus Filesystem Composition

Prompt:

```text
Use only execute. Run safe read-only commands to inspect repo status, current branch, and the first three README lines. Then read README.md through filesystem and compare the first line. Report exact capabilities and whether approval was required.
```

Expected:

- `process::run` read-only path succeeds without approval.
- `filesystem::read_file` succeeds.
- No durable refs.
- Execution details are visible in UI and DB.

Failure focus:

- classifier too strict;
- process output projection weak;
- README path or worktree confusion;
- approval requested for safe read-only work.

2026-05-29 result:

- Simulator session `sess_019e72fd-5e00-75d1-b58f-a9853a621daa` ran the exact
  RWO-N3 prompt against the real dev server. The UI completed with one
  `process::run` and one `filesystem::read_file` capability card and reported
  no approval requirement.
- Parent runtime invocation: `agent::run_turn`
  `019e72fd-a041-77e0-beab-6157f5410084`.
- `process::run` child invocation `019e72fd-b827-7d61-b7c6-10b4727d9948`
  executed through parent `capability::execute`
  `019e72fd-b71f-74c2-b1aa-fe4f2685739c`. The corrected request used
  `executionMode = "read_only"` with command
  `git status --short --branch && printf '\nBRANCH:\n' && git branch
  --show-current && printf '\nREADME_FIRST_THREE:\n' && sed -n '1,3p'
  README.md`; it exited 0 and returned the session branch plus the first three
  README lines.
- `filesystem::read_file` child invocation
  `019e72fd-c29b-7080-ba2e-0e8783ecc134` executed through parent
  `capability::execute` `019e72fd-c186-7670-8166-2be7f8716add` with
  `path = README.md`, `startLine = 1`, and `endLine = 3`.
- DB reconstruction: 21 events, 4 messages, 3 turns, 2 successful
  `capability::execute` invocations, 1 successful `process::run`, 1 successful
  `filesystem::read_file`, 0 failed invocations, 0 approvals, 0 `compact.*`
  events, and 0 session-scoped logs. Queue evidence was one completed
  `agent::prompt_queue_drain`; stream evidence was `agent.runtime`,
  `events.session`, and `queue.lifecycle`.
- Resource refs were substrate-owned only:
  `artifact:prompt-history:86f9751d156f98cca8d16d578ccb0cc1197441048ad4cd0ad79eb9749809fc7f`
  version `ver_019e72fd-a045-7fc1-986f-fd86973c8384`, and final
  `agent_result` resource `res_019e72fd-d304-7fb0-b999-6990728b588d` version
  `ver_019e72fd-d304-7fb0-b999-69b8588badc3`.
- The process output and filesystem read both returned README first line
  `# Tron`; the scenario passes with score delta `+1`. Current score is
  50/100. The next scenario is RWO-N4.

### RWO-N4: Web Research Capability

Prompt:

```text
Use only execute. Search the web for official OpenAI model documentation, fetch one official result if available, summarize the source used, and do not browse outside the capability system.
```

Expected:

- Resolves to web search/fetch capabilities.
- Source URL returned.
- Network failures are clear and actionable.
- No browser or client-side policy path.

Failure focus:

- web capability undiscoverable;
- payload shape unclear;
- opaque network errors;
- provider returns unsupported browsing path.

2026-05-29 result:

- Simulator session `sess_019e7301-b34f-7240-99aa-ea6d6cdac1c2` ran the exact
  RWO-N4 prompt against the real dev server. The UI completed with one
  `Search Web` capability card and one `Fetch Web Page` capability card, then
  reported that it did not browse outside the capability system.
- Parent runtime invocation: `agent::run_turn`
  `019e7301-e572-7883-bad6-2778677fca9e`.
- `web::search` child invocation `019e7301-f526-7a30-be8a-4dba0d5fab5a`
  executed through parent `capability::execute`
  `019e7301-f442-7af0-b308-90897e4849ed`. The corrected request targeted
  `web::search` with query
  `site:platform.openai.com/docs/models OpenAI models documentation official`,
  normalized the result limit to `count = 5`, selected
  `first_party.web.v1.search`, and required no approval.
- Search result 1 was official OpenAI documentation:
  `https://platform.openai.com/docs/models`, title `Models | OpenAI API`. The
  result snippet was the source the final answer summarized.
- `web::fetch` child invocation `019e7302-0260-7bb3-b026-e2c8f545f383`
  executed through parent `capability::execute`
  `019e7302-0169-7923-840e-2b851d98d7b5`. The corrected request targeted
  `web::fetch` for `https://platform.openai.com/docs/models`, selected
  `first_party.web.v1.fetch`, and required no approval.
- The fetch invocation succeeded at the engine/capability layer and returned an
  HTTP `403` `text/html` Cloudflare/JavaScript challenge page from
  `platform.openai.com`. The agent surfaced that source-side fetch limit
  explicitly and did not invoke browser/display or any client-owned browsing
  path.
- DB reconstruction: 21 events, 4 messages, 3 turns, 2 successful
  `capability::execute` invocations, 1 successful `web::search`, 1 successful
  `web::fetch`, 0 failed invocations, 0 approvals, 0 `compact.*` events, and 0
  session-scoped logs. Queue evidence was one completed
  `agent::prompt_queue_drain`; stream evidence was `agent.runtime`,
  `events.session`, and `queue.lifecycle`.
- Resource refs were substrate-owned only:
  `artifact:prompt-history:e202cf50c93122156273e8d146033318c0ddf1a97ad9287f5bddaf97c21fb170`
  version `ver_019e7301-e573-7082-95c4-b3a97fb1f34e`, and final
  `agent_result` resource `res_019e7302-16b6-7b71-9bcd-e8f2033dc2a6` version
  `ver_019e7302-16b7-7981-9f65-81ebe671c385`.
- The scenario passes with score delta `+1`. Current score is 51/100. The next
  scenario is RWO-N5.

### RWO-N5: Browser And Display Capability Probe

Prompt:

```text
Use only execute. Discover whether browser or display capabilities are available. If available, inspect their status and report what they can safely do. Do not open arbitrary sites unless the capability explicitly supports it.
```

Expected:

- Available capabilities are accurately reported.
- Missing capabilities produce `needs_capability` or clear unavailable status.
- No hallucinated browser/display API.

Failure focus:

- discovery ranking;
- bad `needs_selection` UI;
- ambiguous unavailable-state messaging;
- client-owned browser action path.

2026-05-29 result:

- Simulator session `sess_019e7308-762f-7691-987e-ea33f8eac543` ran the exact
  RWO-N5 prompt against the real dev server. The UI completed with execute
  cards only and did not open arbitrary sites or invoke a client-owned browser
  action.
- Parent runtime invocation: `agent::run_turn`
  `019e7308-ba8a-7471-b965-af35e5c2434c`.
- Discovery and inspection were all mediated through `capability::execute`.
  Execute invocation ids were `019e7308-c6c6-7283-88c1-7e97f2820959`,
  `019e7308-dbc5-7810-abd7-880c3eec59fa`,
  `019e7308-ed57-71b3-b9f8-adfe06d56216`,
  `019e7308-f71e-7003-8b53-6a2adbb77a2a`,
  `019e7309-014d-7662-a4b4-cf383d7b8868`, and
  `019e7309-0bba-70d1-b87d-7af5b6b52a1d`.
- Broad and namespace-scoped discovery returned `needs_selection` guidance
  rather than failed probe calls. Browser discovery narrowed to
  `browser::get_status`; display discovery narrowed to `display::stop_stream`.
- `browser::get_status` child invocation
  `019e7308-f7f5-7a70-808c-b156ab733e7f` executed through parent
  `capability::execute` `019e7308-f71e-7003-8b53-6a2adbb77a2a`, selected
  `first_party.browser.v1.get_status`, required no approval, and returned
  `hasBrowser = false` and `isStreaming = false`.
- `capability::inspect` child invocation
  `019e7309-022b-7211-a762-f796e35670e4` inspected
  `display::stop_stream`, selected `first_party.display.v1.stop_stream`, and
  reported `effect = external_side_effect`, `risk = medium`, required
  `streamId`, and caller-supplied idempotency. The display capability was not
  invoked because stopping a stream is an action, not inspection.
- `capability::inspect` child invocation
  `019e7309-0c8f-70e3-835d-4dc33eff16bb` inspected
  `browser::get_status`, selected `first_party.browser.v1.get_status`, and
  reported `effect = pure_read`, `risk = low`, with no approval requirement.
- DB reconstruction: 41 events, 8 messages, 7 turns, 6 successful
  `capability::execute` invocations, 1 successful `browser::get_status`, 2
  successful `capability::inspect`, 0 failed invocations, 0 approvals, 0
  `compact.*` events, and 0 session-scoped logs. Queue evidence was one
  completed `agent::prompt_queue_drain`; stream evidence was `agent.runtime`,
  `events.session`, and `queue.lifecycle`.
- Resource refs were substrate-owned only:
  `artifact:prompt-history:39c1567733a6b43fe22ba97ad4fefdaa105e8cd7b65c0ac1cc3c8b0487a26e29`
  version `ver_019e7308-ba8b-7dd1-bf05-b7699b0478b3`, and final
  `agent_result` resource `res_019e7309-1b86-73d1-8e8f-f9113d7d40b5` version
  `ver_019e7309-1b86-73d1-8e8f-f94d12b7ce72`.
- The scenario passes with score delta `+1`. Current score is 52/100. The next
  scenario is RWO-N6.

### RWO-N6: State, Queue, Stream, Trigger Chain

Prompt:

```text
Use only execute. Create a small state value, read it back, enqueue related work if queue capabilities are available, inspect or drain the queue, publish or read a stream event if available, and report every invocation id.
```

Expected:

- State is written and read through an engine primitive.
- Queue action is traceable.
- Stream availability is exercised or clearly unavailable.
- Invocation lineage is reconstructable.

Failure focus:

- state/queue/stream not resolvable;
- awkward required fields;
- missing queue/stream audit trail;
- side-channel state.

2026-05-29 result:

- Simulator session `sess_019e730c-0b78-7b73-8598-80a75810a394` ran the exact
  RWO-N6 prompt against the real dev server. The UI completed with execute
  cards for state, queue, and stream capability surfaces and reported every
  invocation id used.
- Parent runtime invocation: `agent::run_turn`
  `019e730c-55c8-7453-985f-dfe9583360b6`.
- Discovery and inspection stayed inside `capability::execute`. The run
  produced 21 successful `capability::execute` invocations and 7 successful
  `capability::inspect` child invocations, including inspections for
  `state::compare_and_set`, `state::set`, `state::get`, `queue::enqueue`,
  `queue::list`, `stream::subscribe`, and `stream::poll`.
- State write/read proof: `state::set` child invocation
  `019e730c-d29f-7d30-8f75-facb8557d7ae` executed through parent
  `capability::execute` `019e730c-d1c4-7e41-9576-7a9edfc6c6b0`; `state::get`
  child invocation `019e730c-e46d-7af2-a2ff-eb3405c887a5` executed through
  parent `capability::execute` `019e730c-e37b-75b0-891b-2250a38da7a1`. Both
  referenced session-scoped state `agent.test/execute-state-queue-stream`,
  revision `1`, value `{"message":"small state value","source":"user-request"}`.
- Queue proof: `queue::enqueue` child invocation
  `019e730d-2e5d-7ff2-a2c7-236d774223f3` executed through parent
  `capability::execute` `019e730d-2d73-73d0-a0d6-eba165be9fee` and created
  receipt `019e730d-2e5d-7ff2-a2c7-23798c8c2eab` in queue `agent.test`,
  function `state::get`, status `ready`. `queue::list` child invocation
  `019e730d-3879-7030-b073-f545adc0e233` executed through parent
  `capability::execute` `019e730d-377f-72e1-ac94-079874d9efb4` and returned
  that ready queue item.
- Stream proof: stream publish discovery did not find a publish capability, so
  the agent exercised available stream read capability instead.
  `stream::subscribe` child invocation
  `019e730d-85fc-7dd0-b163-1547b31ca70a` executed through parent
  `capability::execute` `019e730d-8528-7df3-b31a-630feea8bef7`, creating
  subscription `019e730d-860a-7c72-b293-c8a430971098` on topic
  `agent.test.execute`. `stream::poll` child invocation
  `019e730d-934f-7e63-925a-3645e38be4d0` executed through parent
  `capability::execute` `019e730d-9254-7e22-bf1d-b5d3ecbe6b53` and returned
  `events = []`, `hasMore = false`, `nextCursor = 0`.
- DB reconstruction: 116 events, 23 messages, 22 turns, 21 successful
  `capability::execute`, 7 successful `capability::inspect`, 1 successful
  `state::set`, 1 successful `state::get`, 1 successful `queue::enqueue`, 1
  successful `queue::list`, 1 successful `stream::subscribe`, 1 successful
  `stream::poll`, 0 failed invocations, 0 approvals, 0 `compact.*` events, and
  0 session-scoped logs. Queue rows included the ready `agent.test` item and
  one completed `agent::prompt_queue_drain`; stream rows included
  `agent.runtime`, `events.session`, and `queue.lifecycle`, plus the
  `engine_stream_subscriptions` row for `agent.test.execute`.
- Resource refs were substrate-owned only:
  `artifact:prompt-history:31b318477f7835dba466570fa9d35729f13ab34fa5d3d892c89caed2dfc40f9f`
  version `ver_019e730c-55c9-7792-b9ce-8ce447507829`, and final
  `agent_result` resource `res_019e730d-de13-7171-a97d-2f4621beb54a` version
  `ver_019e730d-de13-7171-a97d-2f69a26ebfb0`.
- The scenario passes with score delta `+1`. Current score is 53/100. The next
  scenario is RWO-N7.

### RWO-N7: Live Worker Extensibility

Use a deterministic local worker fixture, not an ad hoc model-authored worker.

Procedure:

1. Start the worker fixture.
2. Confirm worker connects.
3. Confirm function and trigger registration appears in the catalog.
4. Ask the agent through the simulator to discover and invoke the new function.
5. Stop the worker.
6. Confirm disconnect cleanup and catalog removal or unhealthy projection.

Expected:

- No server restart.
- Live catalog update.
- Function invocation succeeds.
- Trigger metadata is visible.
- Heartbeat/disconnect is observable.
- No leaked volatile worker.

Failure focus:

- worker lifecycle;
- catalog propagation;
- live discovery freshness;
- disconnect cleanup;
- stale function visibility.

2026-05-29 result:

- Deterministic fixture:
  `packages/agent/tests/fixtures/rwo_n7_live_worker_fixture.py` connected to the
  real dev server `/engine/workers` transport and registered worker
  `rwo-n7-fixture-worker`, function `rwo_n7::echo`, and trigger
  `manual:rwo_n7.echo`. The final retest fixture log is
  `/tmp/rwo_n7_live_worker_fixture_cleanupfix.jsonl`.
- First failure root cause was `execute_resolution`. The worker function and
  trigger reached the live catalog, but `capability::execute` refused
  `rwo_n7::echo` because the durable capability implementation was projected as
  `conformanceState = candidate`, so binding selection treated
  `session_generated.rwo_n7.rwo_n7_echo` as not selectable. The fix engine-stamps
  external worker capability policy metadata from the scoped token, rejects
  trust-tier overclaims, marks healthy session-scoped workers as `healthy`, and
  allows authoritative registry resync to promote stale `candidate` rows.
- Second failure root cause was `queue_or_trigger`. The function invocation
  passed after the conformance fix, but the agent could not see trigger metadata
  through `execute` discovery and reported trigger metadata as not visible. The
  fix projects visible related triggers into capability registry function
  metadata and discovery messages, while preserving the invariant that trigger
  ids are metadata and function ids are executable targets.
- Third failure root cause was `worker_lifecycle`. After disconnect, the live
  catalog removed the worker/function/trigger, and direct `execute` no longer
  exposed `rwo_n7::echo`, but `capability_implementations` and
  `capability_plugins` still contained healthy session-generated rows. The fix
  removes stale `session_generated`/`session_scoped` plugin and implementation
  projections during registry snapshot sync when they are absent from the live
  catalog.
- Focused regression coverage added:
  `local_external_worker_rejects_trust_tier_outside_scoped_token`,
  `local_external_worker_stamps_capability_policy_metadata_from_scoped_token`,
  `registry_promotes_candidate_conformance_on_authoritative_resync`,
  `registry_snapshot_projects_related_triggers_into_function_metadata`,
  `discovery_message_surfaces_related_trigger_metadata`,
  `registry_sync_removes_stale_session_generated_projection`, and a protocol
  guide assertion that heartbeat examples include a `sequence`.
- Final exact retest session:
  `sess_019e7341-8eac-7bb3-97bc-efd16de60757`, prompt invocation
  `019e7341-8eb2-7f01-916d-d1cc9c920919`, run
  `019e7341-8eb4-7122-b977-12a6ba1ff69e`. Discovery execute invocation
  `019e7341-a398-7a11-ae54-3fdb7ec49e13` surfaced
  `Related triggers visible as metadata: manual:rwo_n7.echo; invoke this
  capability by function id, not by trigger id.`
- Historical cleanup-fixed retest detours: the model still made two documented
  trigger-target detours:
  `019e7341-b780-7bd2-9042-4ea75eaaf895` returned a `needs_selection` style
  discovery response, and `019e7341-ca5c-7fb3-b0a1-59761e853524` returned
  `CAPABILITY_NOT_FOUND` for target `manual:rwo_n7.echo`. These did not create
  child target invocations. The trigger-guidance checkpoint treats this as a
  real ergonomics bug, not a passing-path artifact.
- Trigger-guidance root cause was `execute_resolution`: when the requested
  target exactly matched a visible `relatedTriggers[].triggerId`, `execute`
  fell through to generic target resolution and returned `CAPABILITY_NOT_FOUND`.
  The fix checks visible trigger metadata during intent resolution and explicit
  target-not-found handling, returns `needs_selection` with
  `guidance.kind = trigger_metadata_target`, and suggests the related function
  target without aliasing the trigger id or creating a child invocation.
- Focused trigger-guidance regression coverage added:
  `trigger_metadata_target_guidance_names_related_function_without_aliasing_trigger`
  and `trigger_metadata_intent_guidance_uses_exact_visible_trigger_ids`.
- Direct replay of the historical bad call against rebuilt dev server PID 63286
  returned execute invocation `019e735a-5d89-7c81-b783-3b5fdb7ceab1` with
  `details.status = needs_selection`, `guidance.kind =
  trigger_metadata_target`, `suggestedCalls[0].target = rwo_n7::echo`,
  `childInvocationCreated = false`, and no `CAPABILITY_NOT_FOUND`.
- Trigger-guidance exact retest session:
  `sess_019e735b-9168-7b43-bb95-56fb6cacca43`, prompt invocation
  `019e735b-916e-7083-a488-7047b379bded`, run
  `019e735b-916e-7083-a488-7059e9046afa`, trace
  `019e735b-916e-7083-a488-702f9baf2bf2`. The simulator app was running
  against the real dev server while the prompt executed.
- Trigger-guidance retest invocation sequence:
  `capability::execute` `019e735b-a1af-7530-890f-ac656a040838` returned
  `needs_selection`/`trigger_metadata_target` with suggested target
  `rwo_n7::echo` and no child invocation. The follow-up
  `capability::execute` `019e735b-b058-79f3-955e-299420040da6` returned `ok`
  and invoked target `rwo_n7::echo` invocation
  `019e735b-b146-7331-b942-263bedfe92eb`. The agent final answer reported the
  discovery execute id, invoke execute id, target fixture invocation id, fixture
  result fields, and that trigger metadata is visible but trigger ids are not
  executable targets.
- Successful function invocation:
  `capability::execute` `019e7341-d9b1-7f53-a053-f71ffbabe7b2` selected
  implementation `session_generated.rwo_n7.rwo_n7_echo` under policy
  `approved_external_or_session_healthy` and invoked target
  `rwo_n7::echo` invocation `019e7341-da9c-74d1-9f73-da6356a7cb3d`.
  Fixture result fields matched the requested payload:
  `message = rwo-n7 live worker test`, `nonce = rwo-n7-2026-05-29`,
  `rwoN7Fixture = true`, `workerId = rwo-n7-fixture-worker`.
- Cleanup proof: catalog changes recorded `WorkerRegistered`/`FunctionRegistered`
  /`TriggerRegistered` at revisions 389-391 and
  `FunctionUnregistered`/`TriggerUnregistered`/`WorkerUnregistered` at revisions
  392-394. `worker.lifecycle` stream events recorded connected,
  function_registered, trigger_registered, disconnected, and unregistered for
  `rwo-n7-fixture-worker`.
- Trigger-guidance retest cleanup proof: fixture log
  `/tmp/rwo_n7_live_worker_fixture_trigger_guidance_fix.jsonl` recorded
  `disconnect_sent` at 2026-05-29T10:52:07Z. Post-disconnect direct `execute`
  target `rwo_n7::echo` returned expected `CAPABILITY_NOT_FOUND` in invocation
  `019e7360-69bd-7f62-99a4-484583506c68` at catalog revision 394 with
  `childInvocationCreated = false`, and DB counts were
  `capability_implementations(function_id = rwo_n7::echo) = 0` and
  `capability_plugins(plugin_id = session_generated.rwo-n7-fixture-worker) = 0`.
- DB reconstruction for the final retest: 31 events, 6 messages, 5 turns, 4
  successful `capability::execute`, 1 successful `rwo_n7::echo`, 0 approvals, 0
  `compact.*` events, 0 session logs, one final `agent_result` resource
  `res_019e7342-28bd-7032-8ea8-90f29e5f718e`, one completed `agent` queue row,
  and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows.
- DB reconstruction for the trigger-guidance retest agent turn: events through
  sequence 428 showed 0 `compact.*` events, 0 approvals, 0 session logs, and 0
  failed invocations. The expected post-disconnect cleanup probes were recorded
  after the final answer and are classified as cleanup evidence, not scenario
  invocation failures.
- The scenario remains passed with score delta `+2`. Current score stays
  55/100 because the trigger-guidance checkpoint hardens RWO-N7 evidence but
  does not add a new scenario. The next scenario is RWO-N8.

### RWO-N8: Module Package Activation

Use a deterministic local package fixture.

Procedure:

1. Register package/source.
2. Verify source.
3. Approve source.
4. Configure package.
5. Activate local-process worker.
6. Check health.
7. Invoke registered function.
8. Disable.
9. Inspect no leaked worker/grant.

Expected:

- No package/source/policy/trust tables.
- Activation truth is resource, grant, invocation, and worker substrate.
- Duplicate activation does not duplicate worker/grant.
- Disable revokes grant and stops worker.

Failure focus:

- activation retry;
- grant leaks;
- worker cleanup;
- health evidence;
- direct spawn path.

2026-05-29 preparation checkpoint:

- RWO-N8 was formalized as the next deterministic module activation scenario
  before execution. The simulator/dev-server scenario is now passed after
  root-cause fixes and exact activation retest evidence.
- The next-test checklist is now module-specific rather than copied from the
  live-worker scenario. It requires package/source registration, source
  verification, source approval, configuration, activation, health check,
  fixture invocation, duplicate activation or retry, and disable to compose
  through canonical `module::*`, `worker::spawn`, grant, resource, queue, and
  stream substrate.
- The pass criteria now explicitly require local-process spawn to appear only
  as the activation child `worker::spawn` invocation; duplicate activation must
  not duplicate live worker or grant state; disable must revoke the derived
  grant and stop or disconnect the worker through canonical lifecycle APIs.
- The DB inspection checklist now calls out package, config, source-trust,
  approval, activation, health, disable, worker lifecycle, catalog-change,
  fixture invocation, queue, stream, state, log, grant, resource-version, and
  approval evidence. It also keeps the negative checks for alternate worker
  spawn paths and package/source/policy/trust/audit tables.

2026-05-29 result:

- Fresh setup/retest session
  `sess_019e7385-341e-7f30-8176-6b93396a6dbc` ran against the real dev server
  with the iOS simulator booted. It prepared the local-process Python fixture
  from `worker::protocol_guide`, materialized
  `/tmp/tron-rwo-n8-20260529113609/rwo_n8_worker.py`, registered source and
  package `rwo-n8-runtime-20260529113609`, verified and approved the digest,
  configured the package, activated worker
  `rwo-n8-worker-20260529113609`, health-checked through
  `module::check_health`, disabled, and inspected final package diagnostics.
- That setup run exposed three root causes before RWO-N8 could pass. First,
  `execute` treated nested target argument keys named `mode`,
  `inspectionHandle`, and related wrapper vocabulary as wrapper cleanup even
  when the selected target schema owned those fields; `module::check_health`
  therefore lost required `arguments.mode`. Second, the Python worker template
  emitted by `worker::protocol_guide` blocked indefinitely in `recv_json`, so
  idle local-process workers stopped heartbeating before later invocation.
  Third, `worker::spawn` correctly issued `engine_issued` scoped worker tokens,
  but external-worker conformance classified only `session_scoped`
  session-generated functions as `healthy`, so a health check could invoke the
  function while a later direct model-facing `execute` returned
  `needs_capability`.
- Focused regression coverage added:
  `nested_target_arguments_preserve_target_owned_mode_field`,
  `primitive_catalog_worker_and_observability_functions_share_engine_path`,
  `local_external_worker_stamps_capability_policy_metadata_from_scoped_token`,
  and `local_external_worker_engine_issued_token_is_binding_selectable`.
- Final retest session
  `sess_019e7398-5d77-7d01-9c2a-465589dade48` ran after rebuilt dev server PID
  76020, with the simulator still booted (`iPhone 17 Pro`,
  `267F6468-09AE-471D-9157-29144173EB82`). It reused the verified package from
  the setup run and reran the exact failed activation leg: activate, health
  check, direct fixture invocation, duplicate activation retry, disable, and
  inspect. The run log is
  `/tmp/rwo_n8_agent_retest_20260529045705.json`.
- Retest invocation proof: `module::activate`
  `019e7398-8526-7ff1-bbd5-280708370bf8` created activation version
  `ver_019e7398-85a7-76c3-9ed3-a9e01a8078bc`; child `worker::spawn`
  `019e7398-852c-77f0-a1d9-14b6172caece` registered
  `rwo_n8_20260529113609::health`; `module::check_health`
  `019e7398-a1de-7911-a0bb-74705b5cbeda` invoked health child
  `019e7398-a1df-7282-b0c6-adada0155327` and wrote activation version
  `ver_019e7398-a1e1-7530-b7e6-b5bbdc26b7e2`; direct fixture execute
  `019e7398-b60b-71b1-8e26-1ac35fcad2a1` selected binding
  `binding_decision_019e7398-b6f4-7b81-9c42-3aa322bc8724` under
  `approved_external_or_session_healthy` and invoked child
  `019e7398-b6f4-7b81-9c42-3acf2736499a`; duplicate activation replayed the
  original target result; `module::disable`
  `019e7398-fc56-7651-bafb-306242f5d7ff` stopped spawned process PID 77144 via
  `sandbox::stop_spawned_worker`
  `019e7398-fc58-7ae3-b59e-9adbc4ee5905`; `module::inspect_package`
  `019e7399-1496-78b1-be30-83bda5eee586` returned disabled diagnostics.
- Registry proof: the session-generated implementation
  `session_generated.rwo_n8_20260529113609.demo_echo` carried
  `trust_tier = session_generated`, `signature_status = engine_issued`,
  `conformance_state = healthy`, `visibility = system`, and
  `health = Healthy` during selection. Catalog changes recorded
  `FunctionRegistered` at revision 390 and `FunctionUnregistered` at revision
  391 for the retest worker.
- Safety/resource proof: approvals
  `019e7398-8326-7052-b1e3-25a5515ee4fd` (`module::activate`) and
  `019e7398-f970-7c10-b30d-26a69a580613` (`module::disable`) both ended
  `executed`. Derived grant
  `sandbox-worker:rwo-n8-worker-20260529113609:019e7398-8526-7ff1-bbd5-280708370bf8`
  ended `revoked` at revision 2 with allowed capability
  `rwo_n8_20260529113609::health`. Package resource
  `worker-package:rwo-n8-runtime-20260529113609` remains `available`, config
  resource `module-config:system:rwo-n8-runtime-20260529113609` remains
  `active`, and activation resource
  `activation:system:rwo-n8-runtime-20260529113609` ended `disabled` at version
  `ver_019e7398-fc6a-7631-9549-ad4949d36696`.
- Observability proof: the final retest recorded 0 failed engine invocations,
  0 session log rows, 1 completed `agent::prompt_queue_drain`, and stream rows
  on `agent.runtime`, `approvals`, `compensation.records`, `events.session`,
  `queue.lifecycle`, `resource.leases`, `sandbox.lifecycle`, and
  `worker.lifecycle`. The negative table probe found only pre-existing audit
  and engine resource tables:
  `capability_audit_events`, `constitution_home_audit`,
  `constitution_resolution_audit`, `engine_resource_events`,
  `engine_resource_leases`, `engine_resource_links`,
  `engine_resource_type_definitions`, `engine_resource_versions`, and
  `engine_resources`; there are still no package/source/policy/trust tables.
- Score impact: RWO-N8 earns `+2`. Worker/function/trigger substrate increases
  to 7/14 because a module package now proves local-process worker spawn,
  registration, direct invocation, heartbeat, and cleanup. Safety, grants, and
  approvals increases to 6/10 because activation/disable approvals, grant
  derivation, duplicate activation replay, and grant revocation are all
  DB-reconstructable.

### RWO-N9: Subagent Fan-Out/Fan-In

Prompt:

```text
Use only execute. Spawn two subagents to inspect separate narrow repo topics, wait for both, compare the results, and report parent/child lineage and capabilities involved.
```

Expected:

- Two child subagents.
- Parent waits or polls through canonical job/subagent path.
- Results are isolated but lineage is connected.
- Failure/cancel is inspectable.

Failure focus:

- subagent invocation shape;
- job wait clarity;
- parent-child trace;
- hidden sidecar orchestration;
- missing cancellation semantics.

2026-05-29 result:

- First run: `/tmp/rwo_n9_agent_run_20260529051143.json`, parent session
  `sess_019e73a5-c2ae-7fe3-b9b9-86131b2f7156`, real dev server PID 76020,
  simulator booted. The parent invoked `agent::spawn_subagent` twice through
  `capability::execute`, but both spawns used blocking waits and therefore ran
  sequentially. The parent retrieved two `agent::subagent_result` values, but
  no deterministic `agent_result:subagent:*` resource existed for either child.
  One child had a recoverable failed `filesystem::read_file` against a
  directory; the parent had no failed engine invocation because a later
  `process::run` DB probe was rejected inside `capability::execute` before
  child execution. This classified the scenario as failed with primary layer
  `resource_truth` and secondary layer `schema_or_recipe`.
- Focused tests/fixes: `spawn_blocking_records_resource_native_subagent_result`
  first failed because a completed blocking subagent had no resource-native
  result; it now passes. `omitted_subagent_blocking_timeout_is_nonblocking`
  pins `agent::spawn_subagent` so omitted `blockingTimeoutMs` remains
  non-blocking instead of being coerced into a blocking wait.
  `interactive_and_subagent_contracts_project_lifecycle_metadata` now requires
  `resultContractId = agent::subagent_result` and model guidance that fan-out
  callers omit `blockingTimeoutMs`.
- Retest: `/tmp/rwo_n9_agent_run_20260529052101.json`, parent session
  `sess_019e73ae-4645-7f03-bca5-fad68c3959c4`, rebuilt dev server PID 83613,
  simulator booted. The parent spawned `sess_019e73ae-7618-7e92-b86a-19a4f50c605a`
  for filesystem capability inspection and
  `sess_019e73ae-8413-7830-9a49-3c87c98180be` for agent/subagent capability
  inspection before waiting. Both `agent::spawn_subagent` target rows returned
  `status = running`, proving non-blocking fan-out. The parent then used
  `agent::subagent_status` twice while both children were running, used one
  `process::run` `sleep 10` timer through `execute`, status-polled both
  children to `completed`, and used `agent::subagent_result` for each child.
- Retest DB evidence: 10 parent `capability::execute` rows, 2
  `agent::spawn_subagent` rows, 4 `agent::subagent_status` rows, 2
  `agent::subagent_result` rows, 8 child `capability::execute` rows,
  3 parent-scoped `agent_result` resources, 0 failed engine invocations, 0
  approvals, 0 `compact.*` events, 0 session-scoped log rows, 1 completed
  `agent::prompt_queue_drain` queue row, and stream rows on `agent.runtime`,
  `compensation.records`, `events.session`, `queue.lifecycle`, and
  `resource.leases`.
- Resource proof: `agent_result:subagent:sess_019e73ae-7618-7e92-b86a-19a4f50c605a`
  has version `ver_019e73ae-a256-7023-b2cd-717109d0894c`, and
  `agent_result:subagent:sess_019e73ae-8413-7830-9a49-3c87c98180be` has version
  `ver_019e73ae-ad62-7090-8da1-2bca70a81db7`; both are session-scoped to the
  parent and record parent/child ids in metadata. The parent final
  `agent_result` is `res_019e73af-8618-7073-a7fb-d685e41d3c3e`.
- Negative proof: the table probe still found only pre-existing audit and
  engine resource tables:
  `capability_audit_events`, `constitution_home_audit`,
  `constitution_resolution_audit`, `engine_resource_events`,
  `engine_resource_leases`, `engine_resource_links`,
  `engine_resource_type_definitions`, `engine_resource_versions`, and
  `engine_resources`; no package/source/policy/trust product-state tables were
  introduced.
- Score impact: RWO-N9 earns `+2`. Multi-capability orchestration increases to
  9/12 because parent/child execute, status polling, result retrieval, and child
  filesystem work compose through the engine. Resource truth and durability
  increases to 7/10 because completed subagent outputs are now represented by
  deterministic resource truth for both blocking and non-blocking paths.

### RWO-N10: Memory Auto-Retain

Run two scenarios:

- below-threshold memory skip;
- actual retain with durable project lesson.

Expected:

- Skip is explicit and bounded.
- Actual retain writes through engine-owned memory/resource path.
- No endless spinner.
- Retain records are visible in DB.
- Failure path is visible if model/provider fails.

Failure focus:

- hidden side-effect bypass;
- background task lifecycle;
- resource refs;
- cancellation/retry;
- client-owned memory truth.

2026-05-29 result: **passed**.

Evidence:

- Harness artifact: `/tmp/rwo_n10_agent_run_20260529053401.json`.
- Simulator evidence: booted `iPhone 17 Pro` screenshot captured at
  `/tmp/rwo_n10_simulator_booted.png`; the harness marked all prompt contexts as
  simulator-backed while driving the real dev server WebSocket.
- Dev server: real `/engine` WebSocket on `127.0.0.1:9847`; health was `ok`
  before the run.
- Parent session: `sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6`.
- Prompt path: 10 `agent::prompt` invocations, 10 `agent::run_turn`
  invocations, 10 `agent::prompt_queue_drain` queue rows, all completed.
- Skip path: first prompt recorded
  `memory::auto_retain_fire` invocation
  `019e73ba-45fe-7261-9de5-0aab4453d707`, idempotency key
  `memory.auto_retain:sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6:019e73ba-2db1-7a01-bd80-e3fa3ea4259c`,
  `status = skipped`, `reason = below_threshold`,
  `userMessagesSinceRetain = 1`, and `produced_resource_refs_json = []`.
- Threshold path: prompts 2 through 9 recorded the same bounded skip with
  `userMessagesSinceRetain = 2..9`; no retain event or memory resource mutation
  appeared before the threshold.
- Retain path: prompt 10 recorded
  `memory::auto_retain_fire` invocation
  `019e73bb-209f-7561-912f-909dfe5f6e5a`, idempotency key
  `memory.auto_retain:sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6:019e73ba-fe81-74a3-b03b-177ec857a797`,
  `fired = true`, `status = retaining`, `userMessagesSinceRetain = 10`,
  with trace `019e73ba-fe7e-7511-ab2b-7275bfbecf3b`.
- Memory lifecycle: `memory.auto_retain_triggered` event seq 150 preceded
  `memory.retained` event seq 152. There was no
  `memory.auto_retain_failed` event.
- Resource truth: `memory.retained` recorded four resource refs:
  `artifact:memory-journal:sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6:1d8d7683c4a3721548e1867d8161db63`,
  `materialized_file:memory-session:sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6`,
  `artifact:memory-rule:tron-architecture:1d8d7683c4a3721548e1867d8161db63`,
  and `materialized_file:memory-rule:tron-architecture`.
- Resource versions: all four current versions were `available`; artifacts were
  `promoted`, materialized projections were `materialized`, and each retained a
  content hash. The markdown files under `~/.tron/memory/` were projections
  linked to resource versions, not the source of truth.
- Child resource invocations: memory artifacts were created by
  `artifact::create`; projections were written by `materialized_file::update`;
  artifact-to-projection relationships were recorded by `resource::link`, all
  parented to the auto-retain invocation.
- Observability: DB reconstruction found 0 failed invocations, 0 approvals, 0
  `compact.*` events, 0 session-scoped logs, and stream topics
  `agent.runtime`, `events.session`, `queue.lifecycle`, and
  `compensation.records`.
- Side-channel check: the scenario did not modify settings, did not read or
  write memory through files directly, did not use a fallback reader, and did
  not create package/source/policy/trust side tables. Existing engine resource
  tables remained the substrate for resource truth.

Scoring:

- `+1` for a simulator-backed real-dev-server pass with DB proof and no code
  changes required.
- Current score increases to `60/100`.
- First-party capability usefulness increases to `9/10` because actual
  memory auto-retain now has live proof through engine-owned memory/resource
  capabilities.

### RWO-N11: Resource Failure Matrix

Exercise through `execute` or deterministic fixture:

- stale CAS;
- missing payload;
- damaged/missing blob;
- hash mismatch;
- discarded resource;
- duplicate idempotency key.

Expected:

- Invalid versions are not promoted.
- No accepted refs on failed finish.
- Failure state remains inspectable.
- Duplicate replay does not duplicate versions.

Failure focus:

- resource lifecycle;
- CAS enforcement;
- blob truth;
- idempotency;
- silent repair or fallback reader.

### RWO-N12: Approval And Grant Boundary

Run:

- denied high-risk mutation;
- approved high-risk mutation;
- double-submit approval;
- revoked/expired grant attempt.

Expected:

- No child execution before approval.
- Denial creates no durable refs.
- Approval creates one child execution.
- Double submit replays safely.
- Revoked/expired grants fail before handler.

Failure focus:

- approval ordering;
- grant narrowing;
- replay correctness;
- UI chronology;
- over-approval for safe work.

### RWO-N13: Runtime Resilience

Procedure:

1. Start a task.
2. Restart dev server with `./scripts/tron dev -bdt`.
3. Continue from dashboard and chat.
4. Repeat during approval pause, queue drain, and long process.

Expected:

- Dashboard and chat reconnect.
- No duplicate turns.
- Interrupted invocations are visible.
- Queue/retry/idempotency remain correct.

Failure focus:

- iOS reconnect;
- server process detection;
- invocation recovery;
- duplicate child execution;
- indefinite spinner.

### RWO-N14: Provider Full Parity

Run these prompts through OpenAI, Anthropic, Gemini, and Ollama:

- intent-only file read;
- safe process command;
- missing required field;
- high-risk approval pause/resume;
- idempotency replay;
- multi-step repo inspection.

Expected:

- Same target selection where applicable.
- Same correction classes.
- Same approval behavior.
- Same resource/idempotency semantics.
- Provider-specific tool ids do not leak into engine semantics.

Failure focus:

- provider schema conversion;
- tool call reconstruction;
- streaming deltas;
- pause/resume handling;
- provider-specific fallback.

## Structural Cleanup Backlog

### 1. Decompose `capability::execute`

Problem:

The central execute orchestrator has grown into a large mixed-owner module. It
contains parsing, resolution, correction, decomposition, target-specific
normalizers, presentation, audit details, and tests.

Target:

- Central execute owns only parse, resolve, prepare, run, observe.
- Target-specific knowledge moves to capability-owned recipes or affordances.
- New capabilities do not require new central branches.

Acceptance criteria:

- No new target-specific `if capability == ...` logic in the shared execute flow.
- Process/filesystem/web/resource/worktree heuristics are owned by their domains
  or a focused resolver/correction module.
- Tests prove existing behavior is preserved.

### 2. Split Capability Registry Ownership

Problem:

The registry currently mixes store behavior, SQLite, ranking, indexing, recipes,
plugin manifests, primer rendering, and projection logic.

Target:

- Store and SQLite implementation are separate from ranking/indexing.
- Recipes and docs projection have focused ownership.
- Primer rendering is not tangled with catalog persistence.

Acceptance criteria:

- No behavior changes.
- Module docs explain ownership.
- Tests continue to prove search/ranking/discovery parity.

### 3. Canonicalize Resource Projections

Problem:

Several domains perform repeated list-and-inspect resource traversal. The prompt
history prune issue showed that ad hoc resource scans can become expensive or
fragile.

Target:

- A canonical bounded helper or internal projection path for resource collection
  summaries.
- Domains do not invent their own unbounded resource scans.

Acceptance criteria:

- Prompt library, voice notes, generated UI, module trust/audit, and control
  projections use bounded resource access.
- Public schemas remain stable unless a root-cause defect requires a narrow
  additive change.

### 4. Classify Provider Normalization

Problem:

Provider-boundary code contains logic that may be active protocol normalization
or may be legacy compatibility.

Target:

- Provider-specific schema repairs live only in provider or shared
  provider-protocol modules.
- True backward-compatibility logic is removed.
- Current provider API normalization is documented and tested.

Acceptance criteria:

- Engine and capability core do not know provider schema details.
- Malformed tool arguments fail closed with useful diagnostics.
- Provider parity tests pass.

### 5. Harden Hidden Side Effects

Problem:

Prompt history and memory retain can run asynchronously after normal agent
responses. These must remain engine-owned and observable.

Target:

- Prompt history and memory retain actions have invocation/event evidence.
- Async side effects do not become invisible sidecars.
- Failures are bounded and visible.

Acceptance criteria:

- Real retain scenario passes.
- Prompt-history scenario passes.
- No endless spinner.
- No client-owned memory or prompt truth.

### 6. Continue Test Decomposition

Problem:

Some large test files still mix concerns and make ownership hard to scan.

Target:

- Split files over 1k lines when they cover multiple behaviors.
- Keep generated or fixture-heavy files only with explicit justification.

Acceptance criteria:

- New tests land near the owning concern.
- No new broad catch-all test files.
- Static gates record intentional exceptions.

### 7. Move Capability Presentation Toward Server Ownership

Problem:

iOS should not infer capability semantics, colors, detail sections, or action
meaning from client-side guesses.

Target:

- Capability presentation hints come from server-owned capability metadata where
  practical.
- iOS renders server truth.

Acceptance criteria:

- Capability detail sheets remain native and consistent.
- iOS submits only stored action coordinates and user input where generated UI is
  involved.
- No client-owned policy, grants, or action target construction.

## Static Gates To Add Or Strengthen

Add or strengthen tests in `packages/agent/tests/threat_model_invariants.rs`:

- New scorecard exists.
- Historical scorecard links to the new scorecard.
- New scorecard contains:
  - current score;
  - rubric;
  - scenario ledger;
  - failure protocol;
  - structural cleanup backlog;
  - no fallback/compatibility rule.
- `execute` remains the only Tron model-facing capability primitive.
- `search` and `inspect` remain internal/operator only.
- No prompt tables return.
- No fallback readers, compatibility aliases, client-authored generated UI
  actions, `control::act`, dynamic UI catalogs, raw-scope authorization,
  package/source/policy/trust/audit tables, or alternate worker-spawn paths.
- Provider-specific schema terms do not leak outside provider/protocol modules.
- New target-specific execute behavior must be capability-owned, not
  central-spaghetti owned.
- Large-file audit rows exist for files over 1k lines that remain intentionally
  large.

## Verification Commands

For scorecard-only changes:

```bash
cd <repo>/packages/agent
cargo test --test threat_model_invariants -- --nocapture
cd <repo>
git diff --check
```

For Rust capability or engine changes:

```bash
cd <repo>/packages/agent
cargo test capability_ --lib -- --nocapture
cargo test resource_ --lib -- --nocapture
cargo test generated_ui --lib -- --nocapture
cargo test module_ --lib -- --nocapture
cargo test --test threat_model_invariants -- --nocapture
```

For broad Rust/server changes:

```bash
cd <repo>
scripts/tron ci fmt check clippy test
```

For iOS changes:

```bash
cd <repo>/packages/ios-app
xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<targeted-test>
```

## Next Test

Recommended next scenario: **RWO-N11: Resource Failure Matrix**

Setup:

- Use the currently configured real dev server.
- Use the iOS simulator for the parent agent prompt when practical; use a
  deterministic fixture only where the exact damaged-resource state cannot be
  reached through a model-authored prompt without broad side effects.
- Exercise stale CAS, missing payload, damaged or missing blob, hash mismatch,
  discarded resource, idempotency replay, and resource inspection paths through
  `execute` or engine-owned deterministic fixture calls.
- Keep resource truth engine-owned; do not inspect or mutate resources through
  client-owned state or ad hoc filesystem side channels.

Prompt:

```text
Use only execute. Create or identify a session-scoped resource, prove a normal inspect/update path, then exercise stale-CAS, missing-payload, damaged-or-missing-blob, hash-mismatch, discarded-resource, and idempotency-replay behavior. Report each resource id, version id, error class, and DB-observable lifecycle state.
```

Procedure:

1. Start a fresh simulator-backed session on the real dev server.
2. Create a session-scoped resource through the resource or materialized-file
   capability path and record its current version/hash.
3. Exercise a normal inspect/update/read path first so the success baseline is
   reconstructable.
4. Trigger each failure class with the smallest deterministic mutation or
   capability request that owns that failure mode.
5. Confirm each failure returns a bounded typed error and leaves resource
   lifecycle/version state correct.
6. Inspect DB resource, invocation, queue, stream, event, log, and failure
   evidence before scoring.

After completion, inspect:

- session ids, run ids, prompt invocations, target capability invocations, and
  parent/child invocation ids;
- resource ids, version ids, content hashes, lifecycle state, links, discarded
  markers, damaged-state markers, and idempotency keys;
- stale CAS, missing payload, missing blob, hash mismatch, discarded read/update,
  and replay results;
- queue rows and stream topics emitted for prompt completion and resource
  lifecycle;
- failed invocations, if any;
- approval records, if any;
- logs mentioning resource, blob, queue, stream, or provider failures.

Pass criteria:

- The normal success path records durable resource refs, versions, and hashes.
- Every requested failure path is bounded, typed, reconstructable, and leaves no
  invalid current version.
- Replay/idempotency proves the same logical operation does not duplicate or
  silently mutate resource truth.
- Resource decisions, versions, and failures are reconstructable from DB
  invocation/event/log/resource/queue/stream records.
- No client-owned policy, alternate worker-spawn path, fallback reader,
  compatibility layer, or product-state side channel is used.

If it fails, classify the primary failure layer and stop broader testing until
the exact scenario passes.

## Acceptance Criteria For This Planning Checkpoint

This planning checkpoint is complete when:

- This file exists at
  `packages/agent/docs/collapsed-engine-hardening-scorecard.md`.
- The previous scorecard is treated as historical in future implementation.
- A future agent can start from this document and run the next scenario without
  asking what to do.
- No runtime code, public API, storage generation, iOS/Mac policy path, fallback
  reader, compatibility layer, or product behavior is changed merely by adding
  this plan.

The new score reaches `100/100` only after every scenario block has passed or has
an explicit, tested, documented reason why it is not applicable.
