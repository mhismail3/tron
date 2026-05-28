# Capability orchestration test scorecard

Last updated: 2026-05-28.

This scorecard tracks the manual and automated proof that Tron’s single
model-facing `execute` portal is intuitive, robust, auditable, and safe enough
for higher-level modular packages to build on. It is not the repo-wide
production-grade rubric. It is the live test map for the server substrate and
iOS harness while we exercise real sessions.

## Definition of done

The capability substrate is done when a model with only the `execute` primitive
can discover, prepare, invoke, retry, inspect, and recover from every common
first-party and package-owned capability path without guessing internal wrapper
fields, probing with expected failures, duplicating side effects, bypassing
approval, or losing audit evidence.

The “done” bar requires:

- one model-visible primitive, `execute`, across every provider surface;
- every required target field discoverable from intent resolution, recipes, or
  structured `needs_input` guidance;
- deterministic corrections for harmless shape mistakes, with no authority
  broadening;
- failed prepare paths create no child invocation, approval, resource ref, or
  durable output;
- duplicate idempotency keys replay, never mutate twice;
- approval, pause, resume, and denial state is visible in both events and the
  invocation ledger in chronological order;
- every durable output is backed by resource refs;
- iOS renders server truth only and never constructs target ids, grants,
  payload templates, lineage, or policy locally;
- logs/events are sufficient to debug a manual test without screenshots.

## Current score

Current manual-test substrate confidence: **70/100**.

This score is intentionally conservative. The production codebase can still be
high quality while this manual substrate exercise remains incomplete; this
score measures how much of the live execute/resource/approval/worker path has
been exercised end-to-end through the app and verified from server logs.

| Axis | Points | Current | Evidence | Remaining proof |
|---|---:|---:|---|---|
| Execute ergonomics and correction | 15 | 12 | `process::run` expected-output correction, wrapper/target guidance, actionable process failure diagnostics, `filesystem::apply_patch` append correction tests, `filesystem::list_dir` `maxEntries` alias correction, live simulator append execution without probe failures, live `needs_selection`/`needs_capability` guardrails, and live `needs_input` guidance with exact missing paths | Stale-plan and provider-shape parity tests |
| Capability resolution and recipes | 10 | 8 | Engine Console search/inspect flows, resolved explicit `process::run` targets across safe/rejected/approval/failure modes, live intent-only `filesystem::read_file` resolution from `execute` without an explicit target, broad/unknown intent fail-closed as `needs_capability`, filesystem-namespace ambiguity as `needs_selection`, and known-target missing input as `needs_input` | Intent-only resolution across web/worker/module, ranking audit, and vector-warmup degradation |
| Core filesystem/process paths | 15 | 15 | Read-only `process::run`, policy rejection for unsafe read-only commands, process cwd/path/root escape rejection, sandbox materialized output target bounding, process env allowlisting, live intent-only `filesystem::read_file`, live missing-file failure, live absolute-path root-bound rejection, bounded `filesystem::list_dir`/`glob`/`search_text`/`find` through `execute`, exact replacement `apply_patch`, `write_file`, `edit_file`, failed patch validation, process timeout/non-zero/stderr-only behavior, and missing expected sandbox output | Additional write/edit failure modes and broader command classifier edge cases |
| Approval and freshness | 10 | 7 | Approval-required sandbox command, approval execution/replay for sandbox materialization, resume ordering fix, no-approval detail-sheet suppression, and no-approval process failures staying out of the approval plane | Denial, timeout, stale revision, replayed approval UI edge cases, and concurrent approval edge cases |
| Idempotency and replay | 10 | 8 | Sandbox materialized replay inspection, live sandbox materialized approval replay with one child invocation, apply-patch append replay unit/integration tests, live simulator `filesystem::apply_patch` exact replacement replay, and live simulator `filesystem::write_file`/`edit_file` replay with stable refs | Queue retry, duplicate UI submission, duplicate provider tool call, and cross-session replay |
| Resource-output substrate | 10 | 8 | Prompt library and voice notes resource conversions, materialized `process::run` output refs, patch proposal refs, live simulator filesystem write/edit resource refs, failed patch validation with no accepted refs, missing expected sandbox output with no materialized-file ref, and replayed materialized output refs | Artifact/materialized-file damage, CAS, hash mismatch, discard, and retained evidence under failure |
| Generated UI/action gateway | 10 | 5 | Prompt management generated surface, action toasts, stale/offline fail-closed renderer behavior | Generic action staleness, malformed input, revoked grant, and target revision drift through live app |
| Module/worker extensibility | 10 | 2 | Rust module package activation/trust/health tests exist | Live local-process package activation, worker spawn/health/disable/recovery, trust audit, and package UI through app |
| Observability/log ingestion | 5 | 5 | Server ledger/event queries used during manual testing, auto-ingest path exercised, live replay test reconstructed from `engine_invocations` plus resource refs without relying on screenshots, and failed child invocations now remain visible in `execute` orchestration details | Standardize the DB query bundle for every scenario |
| Provider parity | 5 | 0 | Provider exports are covered by code tests, not manual testing yet. A direct Anthropic `/engine` retest stopped at `tool_use` without child invocations, so this axis stays blocked until provider loop parity is proven. | OpenAI, Anthropic, Gemini, Kimi, and Ollama execute-schema parity with identical correction/result behavior |

## Already exercised and fixed

| Area | Status | What was proven or fixed | Evidence |
|---|---|---|---|
| Dev server automation | Covered | `./scripts/tron status --json` is the authoritative automation check; dev takeover PID confusion was fixed by making scripts deterministic for agent use. Background dev startup now boots out stale loaded-but-not-running dev LaunchAgents before bootstrapping a fresh one. | Dev script checkpoint, `tron_dev_background_start_is_file_logged_and_health_checked`, simulator-testing notes |
| Prompt Library management | Covered | Management moved to server-authored generated UI; picker remains local composer insertion only. Styling, toast feedback, and expand/collapse behavior were cleaned up. | iOS Prompt Library source guards and generated UI tests |
| Engine Console capability UI | Covered | Removed redundant titles, improved inspection sheet hierarchy, color alignment, and tool-chip names. | Simulator screenshots and iOS source guards |
| Approval event ordering | Covered | Approval chips now sort before the resumed result when that was the actual event order. | Simulator retest and event ordering fix |
| Read-only process safety | Covered | Safe read-only process commands run directly; write-like `read_only` commands fail before child mutation. A fresh simulator session ran `date`, `pwd`, `test -f README.md`, bounded `sed -n`, and `git status --short` through `execute`/`process::run`; all five children succeeded with no approval, no durable refs, and bounded stdout/stderr/exit data in the ledger. A later simulator session tried redirection, deletion, Python file write, and curl POST as `read_only`; all four were `target_policy_rejected` with empty `childInvocationIds`, empty `resourceRefs`, zero approvals, and no marker files in the worktree. | Safe-read session `sess_019e6cf6-1c1b-74e3-9c74-2a67cd8ce7ce`; process children `019e6cf6-fc59-7170-a275-f821524b4122`, `019e6cf7-0489-79c3-ad4f-403a16c9d200`, `019e6cf7-0cb3-7c33-8505-bf17d0d97ffa`, `019e6cf7-1756-76d3-8709-877cf690e088`, `019e6cf7-1e3a-7bb0-a624-4f7cdbdb3fa7`; rejection session `sess_019e6d01-dcf1-7d90-a405-e8502fecc66a`; rejected execute invocations `019e6d02-af02-7301-89a8-1d3eec3a127c`, `019e6d02-b757-7152-bf7c-dcb05c6d147f`, `019e6d02-c22d-7603-affd-fa6cfd01aa74`, `019e6d02-d29c-7f50-8085-ef6249c52651`; process policy tests |
| Sandbox materialized process | Covered | Expected-output schema confusion was fixed; materialized output returns resource refs and approval/resume state. A simulator replay test ran one sandbox-materialized command with `expectedOutputs`, created one approval, executed one `process::run` child, returned `materialized_file` and `execution_output` refs, then replayed the same idempotency key through approval/idempotency without creating a second process child. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; approval `019e6d06-7d90-75f2-a731-4a42173b851c`; process child `019e6d06-d078-7d52-82ed-62d578d3072e`; materialized file `materialized_file:449b2b5be1c00eb0b51048d23f51f5fc21927507c6d93418ecc7d755aadf9f15`; execution output `res_019e6d06-d0a2-7861-adc5-f4fdfa545441`; process/orchestration tests |
| Process failure modes | Covered | A simulator continuation exercised timeout, non-zero exit, stderr-only output, and missing expected sandbox output. `sleep 2` with `timeoutMs=50` returned `timedOut=true` and no refs; `false` returned exit code 1 with no refs; missing `ls` returned stderr and no refs; missing sandbox output failed as `PROCESS_EXPECTED_OUTPUT_MISSING`, created a child invocation for the attempted run, created no approval, and produced no materialized-file ref. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; process children `019e6d0c-9057-7230-9400-0b013842298a`, `019e6d0c-98af-7bf0-a134-4897214327c6`, `019e6d0c-a4ff-7a42-9809-5dcb8d25498e`, failed child `019e6d0c-b783-7f51-bbef-71c647040e8a`; missing-output execute `019e6d0c-b69c-74a3-936f-3f6628c24b1c`; zero approvals after the failure-mode prompt |
| `filesystem::apply_patch` append | Covered | Append-only patches now use `oldString: ""`; execute normalizes missing `oldString` plus non-empty `newString` into that stable shape. Duplicate child keys replay instead of conflicting after a read/probe retry. Live simulator retest appended `automated replay smoke 2026-05-27 13:50` exactly once: the first child `filesystem::apply_patch` succeeded with `idem-apply-2026-05-27-1350`, the second child replayed from it, and no `read_file` or `process::run` appeared in the ledger. | `filesystem_apply_patch_empty_old_string_appends_and_replays`, `orchestrated_execute_normalizes_apply_patch_append_intent`, `capability_execute_apply_patch_append_shape_runs_without_failed_probe`, DB session `sess_019e6b1a-c7b4-7e81-9aff-1de4e632597d` |
| Intent-only `filesystem::read_file` | Covered | A fresh simulator session asked the model to use only `execute`, with no target, to read the first line of `README.md`. The orchestrator resolved `filesystem::read_file` in `intent_resolution` mode, ran one child invocation, required no approval, produced no resource refs, and returned `Testing out a README here.` | DB session `sess_019e6b22-5d18-75e3-909d-ffff4223aa0c`, `capability.orchestration` audit event at `2026-05-27T20:31:55Z` |
| Broad unresolved intent | Covered | A fresh simulator session called `execute` with intent `work with README.md` and empty arguments. The result failed closed as `needs_capability`, returned low-confidence candidates and a proposed capability shape, and created no child invocation. This is the intended behavior for no clear namespace/action anchor. | DB session `sess_019e6b25-445a-7ae2-82be-397acb398fff`, payload ref `payload_ref_019e6b25-ebc3-7a50-885e-7dbcb262ade8` |
| Namespace ambiguity | Covered | A fresh simulator session called `execute` with intent `filesystem README.md` and empty arguments. The result was `needs_selection`, returned bounded filesystem candidates, and created no child invocation. | DB session `sess_019e6b28-b568-7690-96b3-f1518b48fba7`, payload ref `payload_ref_019e6b29-7131-7d83-8bd0-b0bbf4dc5268` |
| Missing required input | Covered | A fresh simulator session called `execute` with intent `read a file` and empty arguments. The result selected `filesystem::read_file`, returned `needs_input`, reported missing `arguments.path`, included a concrete corrected example, and created no child invocation. | DB session `sess_019e6bd6-6178-7ca2-be97-5ff962236885`, payload ref `payload_ref_019e6bd6-fc9e-7273-8e6b-da475db81906` |
| Unknown capability intent | Covered | A fresh simulator session called `execute` with intent `calibrate a quantum pineapple teleporter` and empty arguments. The result was `needs_capability`, included the proposed capability shape, returned bounded low-confidence candidates, and created no child invocation. | DB session `sess_019e6bd8-a9a3-7922-9eee-37775e725f2c` |
| Model-facing filesystem root bounds | Covered | A simulator guardrail session proved missing files fail cleanly and absolute host paths such as `/etc/passwd` are rejected inside the model-facing filesystem capability path. Relative and allowed absolute paths still resolve against the active session worktree, while raw service helpers remain trusted-local internals only. Failed child invocations now surface in `execute.details.childInvocationIds` and nested orchestration details instead of disappearing from the user-facing result. | `filesystem::*` tests, `capability_execute_reports_failed_child_invocation_lineage`, DB sessions `sess_019e6bde-08d5-7331-8577-c74335d84ada` and `sess_019e6bec-0218-7d51-a211-0fe632f2963a` |
| Model-facing process root and env bounds | Covered by focused tests | `process::run` still supports useful read-only workspace checks, but every invocation requires active session worktree truth. Read-only cwd/path operands, symlink/glob operands, and sandbox materialization targets must stay inside that worktree. Child processes receive an allowlisted environment rather than inherited server secrets, and explicit env payloads reject secret-like keys/values. | `process_run_requires_active_session_worktree`, `read_only_process_rejects_paths_outside_session_worktree`, `read_only_process_rejects_symlink_operands_that_escape_worktree`, `read_only_process_rejects_shell_glob_path_operands`, `read_only_find_allows_name_globs_but_bounds_search_roots`, `sandbox_materialized_absolute_target_path_cannot_escape_session_worktree`, `safe_process_environment_is_explicitly_allowlisted`, `process_run_rejects_secret_like_env_payloads` |
| Bounded filesystem discovery | Covered in simulator and OpenAI path | A live simulator retest asked the model to use only `execute` for `filesystem::list_dir` with `maxEntries`, `filesystem::glob`, and `filesystem::search_text`. The orchestrator normalized `maxEntries` to `maxResults`, selected the correct targets, required no approval, created exactly one child invocation per target, returned no durable refs for pure reads, and recorded the correction in `capability.orchestration` audit diagnostics. A direct OpenAI `/engine` retest covered the same substrate path before the simulator window was available again. | Simulator DB session `sess_019e6ce7-8dc8-7912-9a9b-f7c06f744d39`; child invocations `019e6ce8-9040-7890-a15b-0e471941e28f`, `019e6ce8-9951-7c71-8ea0-865966b321bb`, `019e6ce8-a46f-7031-814e-c838d7830414`; prior `/engine` session `sess_019e6c9a-c3b7-73d1-afad-2b5df04824b8`; `list_dir_honors_max_results_bound`; `orchestrated_execute_normalizes_list_dir_max_entries_alias_before_schema_validation` |
| Exact replacement patch replay | Covered in simulator | A simulator session called `filesystem::apply_patch` twice with `idempotencyKey=idem-exact-replace-2026-05-28-0450`, then read the file. The first child created one materialized-file ref and one patch-proposal ref; the second child replayed from the first with the same refs; the final worktree file contained the marker exactly once. | DB session `sess_019e6ceb-6eeb-7b91-88b9-2ee810d083cd`; child invocations `019e6cec-5d60-7b50-8efb-e70a101d6a3c` and replay `019e6cec-68f3-77e2-8e96-aa4364889c51`; final file `README.md` contained `exact-replace-2026-05-28-0450` once |
| Failed patch validation | Covered in simulator | A simulator session attempted `filesystem::apply_patch` with a missing `oldString`, then searched for the proposed marker. The failed child returned `PATTERN_NOT_FOUND`, produced `[]`, created no materialized update or patch proposal, and the search returned zero matches. | DB session `sess_019e6cef-179e-7dc2-9640-577d74ea4f19`; failed child `019e6cf0-b9c3-7121-8221-b93daa15ed1b`; search child `019e6cf0-c4de-7032-871b-4e3092696d3d` |
| `find`/`write_file`/`edit_file` substrate | Covered in simulator | A simulator continuation ran bounded `filesystem::find`, `filesystem::write_file` twice with one idempotency key, `filesystem::edit_file` twice with one idempotency key, and a final `read_file`. `find` returned exactly two matches with `truncated=true`; second write/edit invocations replayed from their first children with identical resource refs; final file content was `beta\nstable\n`. | DB session `sess_019e6cef-179e-7dc2-9640-577d74ea4f19`; find child `019e6cf3-49fb-7011-8311-fb11ae635727`; write child/replay `019e6cf3-5454-7431-b396-276ac5c08b3c`/`019e6cf3-5f4a-75a2-996a-754910d1105c`; edit child/replay `019e6cf3-6ae2-7361-baa6-2599f07dd1c3`/`019e6cf3-7581-71c2-a07d-2acd1a058c00`; read child `019e6cf3-7e63-7a53-a56a-44bf1147cf75` |
| Direct Anthropic provider retest | Blocked | A direct `/engine` session on the default Anthropic model reached provider `tool_use` stop state but produced no capability child invocations. This is intentionally recorded as a provider-parity blocker instead of being blended into OpenAI substrate evidence. | DB session `sess_019e6c97-be45-7711-bee3-94b1c6ff1729`; Provider parity axis remains `0/5` |
| iOS reconnect after server rebuild | Covered by focused tests | Dashboard/chat connection state now belongs to the shared `EngineConnection` foreground reconnect loop. Normal reconnect keeps probing at a bounded cadence while foregrounded, so screens recover after dev-server rebuilds without owning retry logic or staying permanently failed until manual tap. | `ReconnectProbePolicyTests`, `EngineConnectionReconnectTests`, `packages/ios-app/docs/architecture.md`, `packages/ios-app/docs/onboarding.md` |
| Memory auto-retain | Partially covered | Auto-retain runs through engine capabilities and no longer blocks normal testing, but it needs a final regression under the current server build. | Prior server-log review; pending current-build retest |

## Remaining test matrix

Run these from easiest foundation to highest-level composition. A checkpoint is
complete only when the app behavior, server ledger, and relevant Rust tests all
agree.

### 1. Execute portal basics

- Intent-only discovery for known capability: read a file without target.
- Explicit target execution: `filesystem::read_file` and `process::run`.
- Ambiguous intent: must return `needs_selection`, no child invocation.
- Missing required fields: must return `needs_input`, exact fields, no child.
- Unknown domain: must return `needs_capability`, proposed shape, no child.
- Wrapper-shape mistakes: nested `payload`, nested `idempotencyKey`, target
  aliases, process output aliases, and apply-patch append shape must correct or
  reject deterministically.

### 2. Filesystem substrate

- `read_file` with line bounds, missing file, relative path, absolute path.
- `list_dir`, `find`, `glob`, and `search_text` with bounded results.
- `write_file`, `edit_file`, and `apply_patch` exact replacement.
- Append patch via `apply_patch` without a read/probe detour.
- Duplicate idempotency for each mutating path.
- Resource refs for every durable mutation; no refs on failed validation.

### 3. Process substrate

- Safe `read_only`: `date`, `pwd`, `test -f`, bounded `sed -n`, `git status`.
- Unsafe `read_only`: redirection, deletion, in-place edit, network mutation.
- `sandbox_materialized` with one expected output and approval.
- Duplicate sandbox idempotency: no duplicate materialized output or approval.
- Timeout, non-zero exit, stderr-only output, and missing expected output.

### 4. Approval and pause/resume

- Required approval creates one approval record and no child execution before
  resolution.
- Approve resumes exactly once and preserves parent/child lineage.
- Deny leaves no durable output and returns a clear result.
- Timeout/cancel remains inspectable.
- No-approval calls never show approval UI.

### 5. Resource and generated UI boundaries

- Generated UI `surface_for_target` and `submit_action` on a known safe target.
- Stale surface version fails before child execution.
- Malformed user input fails before child execution.
- Revoked/expired grant fails before child execution.
- Resource CAS/hash/lifecycle errors remain inspectable and never rewrite truth.

### 6. Module/package extensibility

- Register local digest-pinned package.
- Configure, activate, health-check, disable, and recover local-process worker.
- Trust/source verification and policy denial before spawn.
- Duplicate activation/recovery keys produce no duplicate worker/grant/resource.
- Generated package surfaces expose only canonical stored actions.

### 7. Queue, retry, and crash resilience

- Queue retry of transient failure does not duplicate child invocation,
  resource versions, grants, approvals, or workers.
- Interrupted activation recovery cleans leaked grants/workers.
- Scheduled health/trust audit derives due work without a durable scheduler
  plane.
- Server restart during app session reconnects and preserves action state.

### 8. Provider parity

- OpenAI, Anthropic, Gemini, Kimi, and Ollama expose only `execute`.
- The same request shapes produce the same target payloads and correction
  diagnostics across providers.
- Provider-specific tool-call ids map to stable wrapper idempotency without
  changing child idempotency.

## Simulator harness notes

- Keep manual simulator prompts to one line when using automation. Newlines in
  `type_text` can submit the first line before the rest of the test prompt is
  entered, which creates a false negative for instruction-following and replay
  coverage.
- Use a fresh idempotency key and exact expected line for every mutating
  simulator scenario, then verify the file/resource state from the DB and the
  session worktree.
- Treat screenshots as UI evidence only; the acceptance decision comes from
  `engine_invocations`, `capability_audit_events`, resource refs, and the
  resulting workspace state.
- If the macOS Simulator window is not visible to Computer Use but
  `xcrun simctl io booted screenshot` works, label any `/engine` WebSocket
  retest as server-substrate evidence rather than full app UI evidence.

## Next logical checkpoint

Move to execute-portal basics under the current build:

1. intent-only `filesystem::read_file` from a new simulator session, with no
   explicit target and no approval; **covered on 2026-05-27**
2. ambiguous intent returning `needs_selection` without a child invocation;
   **covered on 2026-05-27**
3. missing required fields returning `needs_input` with exact fields and no
   child invocation; **covered on 2026-05-27**
4. unknown domain returning `needs_capability` with a proposed shape and no
   hallucinated target; **covered on 2026-05-27**
5. DB reconstruction for each case using invocation rows, orchestration
   diagnostics, and capability audit events.

The process substrate breadth checkpoint is covered as of 2026-05-28:

1. unsafe `read_only` commands failed before child mutation;
2. sandbox-materialized output required approval, produced resource refs, and
   replayed without a duplicate child;
3. timeout, non-zero exit, stderr-only output, and missing expected output all
   returned bounded, inspectable results.

The next checkpoint should move to approval and freshness edge cases:

1. denial leaves no child execution or durable output;
2. approval timeout/cancel remains inspectable and resumable only through the
   canonical approval path;
3. stale plan/revision fails before child execution;
4. concurrent duplicate approval submissions resolve exactly once;
5. reconnect recovery during a live dev-server rebuild while a dashboard/chat
   screen is already mounted.
