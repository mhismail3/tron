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

Current score: **55/100 provisional**

This score is intentionally conservative. Tron has strong evidence for many
covered `execute` paths, but the full collapsed-backend architecture still needs
end-to-end proof across live workers, trigger composition, stream behavior,
module activation, actual memory retain, provider parity beyond simple tool
calls, runtime interruption, and resource failure states.

### Axis Scores

| Axis | Points | Current | Full Credit Requires |
|---|---:|---:|---|
| Execute portal ergonomics | 10 | 8 | One `execute` tool resolves, prepares, corrects, runs, pauses, replays, and explains failures without fragile model guessing |
| First-party capability usefulness | 10 | 8 | Filesystem, process, git/worktree, web, browser/display, logs, settings, model, memory, prompt, resource, state, queue, stream, worker, and module capabilities work in real tasks |
| Worker/function/trigger substrate | 14 | 6 | Live workers register functions/triggers, update discovery, invoke, stream, heartbeat, disconnect, and clean up without restart |
| Multi-capability orchestration | 12 | 8 | Agents chain read/search/edit/run/state/resource/approval/queue/subagent operations in realistic workflows |
| Resource truth and durability | 10 | 6 | Durable outputs, resource versions, CAS, hashes, discard, damaged state, and idempotency are proven through live paths |
| Safety, grants, and approvals | 10 | 5 | Safe work runs autonomously; risky work gates correctly; denial/replay/revocation/expiry leave no invalid side effects |
| Runtime resilience | 10 | 5 | Restart, reconnect, queue retry, approval pause, cancellation, partial failure, and cleanup are robust |
| Observability and auditability | 8 | 5 | Every scenario is reconstructable from DB invocation/event/log/resource/approval/queue/stream records |
| Provider parity | 6 | 3 | OpenAI, Anthropic, Gemini, and Ollama expose equivalent `execute` behavior for core scenarios |
| Code modularity and simplification | 10 | 1 | No central spaghetti, no unclassified dead/fallback/compat logic, clear ownership, and large files decomposed where useful |

Total: **55/100**

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
| RWO-N7 | Live worker extensibility | passed_after_fix | +2 | conformance failure: `sess_019e732f-c5e0-7bf3-8130-9da7d39a3deb`; trigger retest with cleanup gap: `sess_019e733b-af69-7f93-bb15-7a717d906aef`; final cleanup-fixed retest: `sess_019e7341-8eac-7bb3-97bc-efd16de60757` | See 2026-05-29 RWO-N7 result note below. Final retest used 4 successful `capability::execute` rows, 1 successful target `rwo_n7::echo` invocation, catalog revisions 389-394, 0 approvals, 0 `compact.*` events, 0 session logs, one final `agent_result`, one completed agent queue row, and worker lifecycle stream rows for connect/register/disconnect/unregister. | `execute_resolution`: session-generated implementations stayed `candidate` and were not binding-selectable. `queue_or_trigger`: visible trigger metadata was not projected through capability discovery. `worker_lifecycle`: stale session-scoped registry plugin/implementation rows stayed healthy after disconnect. | `0aabb48a2` | Passed after rebuilt dev server PID 56952. Post-disconnect registry sync removed the session-generated implementation/plugin rows and direct execute returned `CAPABILITY_NOT_FOUND`. |
| RWO-N8 | Module package activation | pending | 0 | | | | | |
| RWO-N9 | Subagent fan-out/fan-in | pending | 0 | | | | | |
| RWO-N10 | Memory auto-retain | pending | 0 | | | | | |
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
- The model still made two documented trigger-target detours:
  `019e7341-b780-7bd2-9042-4ea75eaaf895` returned a `needs_selection` style
  discovery response, and `019e7341-ca5c-7fb3-b0a1-59761e853524` returned
  `CAPABILITY_NOT_FOUND` for target `manual:rwo_n7.echo`. These did not create
  child target invocations and are retained as guidance evidence for later
  trigger ergonomics work.
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
- Post-disconnect registry snapshot proof: direct `execute` target
  `rwo_n7::echo` returned `CAPABILITY_NOT_FOUND`, and DB counts were
  `capability_implementations(function_id = rwo_n7::echo) = 0` and
  `capability_plugins(plugin_id = session_generated.rwo-n7-fixture-worker) = 0`.
- DB reconstruction for the final retest: 31 events, 6 messages, 5 turns, 4
  successful `capability::execute`, 1 successful `rwo_n7::echo`, 0 approvals, 0
  `compact.*` events, 0 session logs, one final `agent_result` resource
  `res_019e7342-28bd-7032-8ea8-90f29e5f718e`, one completed `agent` queue row,
  and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows.
- The scenario passes with score delta `+2`. Current score is 55/100. The next
  scenario is RWO-N8.

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

- RWO-N8 remains `pending` with no score delta until the simulator/dev-server
  scenario is executed and DB evidence is recorded.
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

Recommended next scenario: **RWO-N8: Module Package Activation**

Setup:

- Use a deterministic local package fixture, not an ad hoc model-authored
  package.
- Use the currently configured real dev server.
- Use the iOS simulator for the agent activation and invocation step after the
  fixture package/source is prepared.

Procedure:

1. Register the package/source through canonical engine capabilities.
2. Verify the source.
3. Approve the source if required by the capability contract.
4. Configure and activate the local-process worker through the engine substrate.
5. Check health and invoke the registered function through `execute`.
6. Disable the package.
7. Confirm no package/source/policy/trust table was introduced and no worker or
   grant leaked after disable.

After completion, inspect:

- package, config, source trust, approval, activation, health, and disable
  resource refs and versions;
- module lifecycle invocations and their child `worker::spawn`,
  `sandbox::stop_spawned_worker`, health-function, grant, queue, and stream
  records;
- worker connection, heartbeat, disconnect, and catalog-change rows/events for
  the local-process fixture worker;
- function and trigger definitions registered by the activated package fixture,
  if the package declares triggers;
- simulator session id and model provider;
- parent invocation and all child `capability::execute` invocations;
- target module lifecycle and fixture capability/function invocation ids;
- failed invocations, if any;
- approval records for high-risk package/source/activation operations, including
  denial/replay rows if they occur;
- resource refs from substrate-owned prompt-history or final `agent_result`
  records;
- queue/stream/state rows emitted by module lifecycle, worker lifecycle, or
  invocation;
- logs mentioning worker transport, package policy, activation, catalog
  propagation, invocation, heartbeat, or cleanup failures.

Pass criteria:

- Package/source registration, source verification, source approval,
  configuration, activation, health check, fixture invocation, duplicate
  activation/retry check, and disable all compose through canonical
  `module::*`, `worker::spawn`, grant, resource, queue, and stream substrate.
- Local-process worker spawn occurs only through the activation child
  `worker::spawn` invocation.
- Live catalog exposes the package fixture function after activation, and the
  simulator agent invokes it through `capability::execute`.
- Heartbeat/disconnect or spawned-worker lifecycle is observable.
- Duplicate activation does not duplicate live worker/grant state.
- Disable revokes the derived grant, stops or disconnects the worker through
  canonical lifecycle APIs, and leaves no leaked volatile worker.
- No alternate worker-spawn path, package/source/policy/trust/audit table, or
  client-owned policy path is used.
- DB reconstruction matches the UI, fixture logs, resource versions, approvals,
  grants, invocations, queues, and streams.

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
