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

Current score: **49/100 provisional**

This score is intentionally conservative. Tron has strong evidence for many
covered `execute` paths, but the full collapsed-backend architecture still needs
end-to-end proof across live workers, trigger composition, stream behavior,
module activation, actual memory retain, provider parity beyond simple tool
calls, runtime interruption, and resource failure states.

### Axis Scores

| Axis | Points | Current | Full Credit Requires |
|---|---:|---:|---|
| Execute portal ergonomics | 10 | 8 | One `execute` tool resolves, prepares, corrects, runs, pauses, replays, and explains failures without fragile model guessing |
| First-party capability usefulness | 10 | 6 | Filesystem, process, git/worktree, web, browser/display, logs, settings, model, memory, prompt, resource, state, queue, stream, worker, and module capabilities work in real tasks |
| Worker/function/trigger substrate | 14 | 4 | Live workers register functions/triggers, update discovery, invoke, stream, heartbeat, disconnect, and clean up without restart |
| Multi-capability orchestration | 12 | 6 | Agents chain read/search/edit/run/state/resource/approval/queue/subagent operations in realistic workflows |
| Resource truth and durability | 10 | 6 | Durable outputs, resource versions, CAS, hashes, discard, damaged state, and idempotency are proven through live paths |
| Safety, grants, and approvals | 10 | 5 | Safe work runs autonomously; risky work gates correctly; denial/replay/revocation/expiry leave no invalid side effects |
| Runtime resilience | 10 | 5 | Restart, reconnect, queue retry, approval pause, cancellation, partial failure, and cleanup are robust |
| Observability and auditability | 8 | 5 | Every scenario is reconstructable from DB invocation/event/log/resource/approval/queue/stream records |
| Provider parity | 6 | 3 | OpenAI, Anthropic, Gemini, and Ollama expose equivalent `execute` behavior for core scenarios |
| Code modularity and simplification | 10 | 1 | No central spaghetti, no unclassified dead/fallback/compat logic, clear ownership, and large files decomposed where useful |

Total: **49/100**

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
| RWO-N2 | Practical code change workflow | passed_after_fix | +2 | first failure: `sess_019e72c3-e190-7ba2-b447-8debb4e36054`; exact retest pass: `sess_019e72e6-88a4-71c1-bc85-787e86df0235`; replay failure: `sess_019e72ea-c4e7-7842-82bb-654538fa3ce5`; replay retest pass: `sess_019e72f3-ee99-7a91-84ef-e3f47604a2ff` | See 2026-05-29 RWO-N2 result notes below. Exact retest passed with 3 target `capability::execute` calls, `filesystem::write_file` 1, `filesystem::read_file` 1, `materialized_file::update` 1, `resource::create` 1, and 0 failed invocations/approvals/compact events/log rows. Replay retest passed with 2 `filesystem::write_file` rows under session-scoped `rwontwoalpha`, one `filesystem::read_file`, one materialized file resource/version, 0 failed invocations, 0 approvals, 0 compact events, 0 logs, 1 completed queue drain, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | Fixed `schema_or_recipe`: new-file guidance/search now prefers `filesystem::write_file` over missing-file `apply_patch`. Fixed `stream_or_state`: runtime event persistence advances from DB sequence truth before preassigned events. Fixed `resource_truth`: file-content mutations use session-scoped idempotency so the same key cannot replay another isolated worktree path. | this RWO-N2 checkpoint commit | Passed exact prompt after rebuilt dev server PID 22402 and passed replay subcheck after rebuilt dev server PID 27362. DB reconstruction matches simulator UI and proves the replay reused one resource/version inside the active session. |
| RWO-N3 | Safe process plus filesystem composition | pending | 0 | | | | | |
| RWO-N4 | Web research capability | pending | 0 | | | | | |
| RWO-N5 | Browser and display capability probe | pending | 0 | | | | | |
| RWO-N6 | State, queue, stream, trigger chain | pending | 0 | | | | | |
| RWO-N7 | Live worker extensibility | pending | 0 | | | | | |
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
cd /Users/moose/Downloads/projects/tron/packages/agent
cargo test --test threat_model_invariants -- --nocapture
cd /Users/moose/Downloads/projects/tron
git diff --check
```

For Rust capability or engine changes:

```bash
cd /Users/moose/Downloads/projects/tron/packages/agent
cargo test capability_ --lib -- --nocapture
cargo test resource_ --lib -- --nocapture
cargo test generated_ui --lib -- --nocapture
cargo test module_ --lib -- --nocapture
cargo test --test threat_model_invariants -- --nocapture
```

For broad Rust/server changes:

```bash
cd /Users/moose/Downloads/projects/tron
scripts/tron ci fmt check clippy test
```

For iOS changes:

```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app
xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<targeted-test>
```

## Next Test

Recommended next scenario: **RWO-N3: Safe Process Plus Filesystem Composition**

Session:

- Use a new simulator session in the `tron` workspace.
- Use the currently configured primary provider unless provider parity testing is
  the active goal.

Prompt:

```text
Use only execute. Run safe read-only commands to inspect repo status, current branch, and the first three README lines. Then read README.md through filesystem and compare the first line. Report exact capabilities and whether approval was required.
```

After completion, inspect:

- session id;
- model provider;
- parent invocation;
- all child `capability::execute` invocations;
- target process/filesystem capabilities used;
- failed invocations, if any;
- approvals, expected none for safe read-only commands and bounded file reads;
- resource refs from substrate-owned prompt-history or final `agent_result`
  records;
- queue/stream/state evidence if present;
- logs mentioning process read-only classification, path, or approval failures.

Pass criteria:

- `process::run` uses `executionMode = "read_only"` for safe commands.
- `filesystem::read_file` reads README.md through the canonical filesystem
  capability.
- The reported first README line matches the process output.
- No failed probe calls.
- No approval is required.
- No filesystem mutation or process write side effect occurs.
- DB reconstruction matches the UI.

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
