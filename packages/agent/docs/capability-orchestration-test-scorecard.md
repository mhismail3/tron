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

Current manual-test substrate confidence: **82/100**.

This score is intentionally conservative. The production codebase can still be
high quality while this manual substrate exercise remains incomplete; this
score measures how much of the live execute/resource/approval/worker path has
been exercised end-to-end through the app and verified from server logs.

The axes below intentionally reframe the old subsystem-oriented score into
real-world use cases. The historical evidence table remains below as the audit
trail for why the starting score is still `77/100`; new rows in the scenario
ledger are the only way this score moves.

| Axis | Points | Current | What it proves | Remaining proof |
|---|---:|---:|---|---|
| Execute portal usability | 12 | 12 | One `execute` tool can resolve, prepare, correct, and run without fragile wrapper guessing. RWO-004 proved web search/fetch now run through clean `execute` calls after guidance and alias hardening. | Provider-shape parity, stale-plan recovery, and vector-warmup degradation remain tracked in their dedicated axes. |
| Core first-party capability usefulness | 12 | 11 | Filesystem and process paths are useful in real tasks, with partial generated UI, prompt, and settings coverage. | Web, browser/display, logs, model, memory, git/worktree, prompt, and settings under real prompts. |
| Multi-capability orchestration | 14 | 14 | The agent can chain filesystem discovery, resource-backed mutation, replay, and verification in a live isolated app session. | Web, subagent, memory, and state/queue/stream use cases. |
| Worker/function/trigger substrate | 12 | 7 | Engine tests cover many primitive contracts and some live function invocation paths. | Live state, queue, stream, trigger, subagent, local-process worker activation, and package disable/recovery. |
| Resource and durable output truth | 10 | 9 | Prompt library, voice notes, process materialization, and filesystem mutations are resource-backed and idempotent in covered paths. | Damage/CAS/hash/discard failure paths and resource-backed package evidence under live scenarios. |
| Safety, grants, and approvals | 10 | 9 | Unsafe read-only commands are rejected; safe process/filesystem composition runs autonomously; approval, denial, replay, and double-submit are covered. | Approval timeout/cancel, stale revision, reconnect recovery, grant expiry/revocation in UI/gateway paths. |
| Runtime resilience | 10 | 7 | Reconnect tests and queue/idempotency unit coverage exist; manual process retries are partly covered. | Server restart during session, queue retry, crash/partial-failure recovery, and activation cleanup under live use. |
| Observability and auditability | 8 | 7 | Manual tests have been reconstructed from invocation, audit, approval, and resource rows. | Standard per-scenario DB query bundle and queue/stream/state reconstruction. |
| Provider parity | 6 | 0 | Provider boundary tests exist, but manual parity is still blocked. | OpenAI, Anthropic, Gemini, Kimi, and Ollama must expose identical `execute` behavior. |
| Operator/generated UI | 6 | 6 | Generated UI surfaces, stored action coordinates, stale rejection, and iOS thinness are covered for prompt management. | Keep score only if future generated-UI scenarios preserve server-owned truth. |

## Scenario ledger

Every row is a deterministic eval. Screenshots are secondary evidence; the
acceptance source is the app result plus `~/.tron/internal/database/tron.sqlite`.

| Scenario ID | Status | Session ID | Prompt | Capabilities expected | Capabilities observed | Resource refs | Approval refs | Failure root cause | Fix commit | Score delta |
|---|---|---|---|---|---|---|---|---|---|---:|
| RWO-001 repo-understanding smoke | passed | `sess_019e6daa-a76c-7c90-9bd2-fce540be184a` | Use only `execute`. Inspect this repo enough to explain the engine’s worker/function/trigger architecture, confirm project rules/skills loaded, avoid shell/date, avoid guessed-path listing, list capabilities used, and cite files. | `capability::execute` -> `filesystem::list_dir`, `filesystem::search_text`, `filesystem::read_file` | 21 `capability::execute`; 11 `filesystem::read_file`; 6 `filesystem::search_text`; 4 `filesystem::list_dir`; 0 `process::run`; 0 approvals; 0 failed invocations; project context showed `Loaded 1 rule` and the assistant confirmed available skills were present. | none | none | Prior epsilon exposed brittle regex default for `filesystem::search_text` (`dispatch(` rejected as invalid regex). Fixed by making search literal-by-default with explicit `regex: true`, plus contract/docs/tests. | `faf10430f` | +1 |
| RWO-002 practical code-change verify | passed | `sess_019e6deb-c688-7f93-ae8f-0b7a41a226fb` | Use only `execute`; find the scorecard, write `packages/agent/docs/capability-orchestration-test-sandbox.md`, replay the same write with `idempotencyKey=rwo-002-app-sandbox-note-2026-05-28-v4`, read it back, and report refs. | `filesystem::find`, `filesystem::write_file`, idempotent replay, `filesystem::read_file` | Worktree acquired at `.worktrees/session/sess_019e6deb-c688-7f93-ae8f-0b7a41a226fb`; one `filesystem::find`; one first `filesystem::write_file`; one replayed `filesystem::write_file` with `replayed_from=019e6ded-3a8c-7870-a86f-41513e938237`; one `filesystem::read_file`; 0 `process::run`; 0 failed target calls; 0 approvals. | `materialized_file:25b145f45b8dfbf76c016c48ebeda276019451685deaa6be3c7c29890baaa48b`, version `ver_019e6ded-3a8f-7943-a052-ccf218148155`, content hash `eef2a06fda44639bbce37fa8329226cb7700fd6b462a61ee1ead199cc35f7760` | none | Prior app run exposed hidden prompt-worktree fallback after `git worktree add` ran checkout hooks and Git LFS was unavailable. Fixed by disabling checkout hooks for worktree creation and making prompt worktree acquisition fail closed instead of falling back to the repo root. A direct retest then stalled after discovery; the final simulator retest completed the full app loop. | current checkpoint | +2 |
| RWO-003 safe process plus filesystem | passed | `sess_019e6f49-793e-7942-a270-80c8f54bb33c` | Use only `execute`; run safe read-only process commands for branch/status/first README lines, then read `README.md` through `filesystem::read_file` and compare the first line. | `process::run`, `filesystem::read_file` | Worktree acquired at `.worktrees/session/sess_019e6f49-793e-7942-a270-80c8f54bb33c`; one `process::run` child `019e6f4a-9e73-7233-9547-ab60bbc85fbf` with `executionMode=read_only`, `exitCode=0`, empty stderr, bounded stdout; one `filesystem::read_file` child `019e6f4a-acb1-7d73-9979-9538e468262a`; 0 failed target calls; 0 approval functions; first README line matched as `# Tron`. | none | none | none | n/a | +1 |
| RWO-004 web research | passed | `sess_019e6f63-b6ac-7580-b91b-a7c25c8c7b75` | Use only `execute`; search the web for official OpenAI model documentation, fetch one official result if available, summarize the source URL, and report exact capabilities/child invocation ids. | `web::search`, optional `web::fetch` | Final retest after hardening had exactly two `capability::execute` calls, one `web::search` child `019e6f64-af14-7df1-9be7-2d778249fc5a`, one `web::fetch` child `019e6f64-bb55-7ad1-b3dc-68a579f431be`, 0 failed target calls, 0 `process::run`, 0 approvals, official source `https://platform.openai.com/docs/models`, and fetched canonical URL `https://developers.openai.com/api/docs/models`. | none from target web calls; background prompt history and final agent result resources were expected session plumbing | none | Initial run `sess_019e6f55-25e3-7d30-9ecc-2c85b1c09f6c` exposed two avoidable prepare-level failures: the model invented `riskMax=low` for medium-risk network reads and used `maxResults` instead of `count`. Fixed with engine-owned `web::search` result-limit alias normalization plus execute/provider/README guidance that constraints are hard bounds and web reads are medium-risk pure reads. | current checkpoint | +1 |
| RWO-005 browser/display probe | pending | pending | Discover browser/display capabilities and inspect safe status without arbitrary browsing. | `browser::*` and/or `display::*` status capabilities, or `needs_capability` if unavailable | pending | pending | pending | pending | pending | 0 |
| RWO-006 state queue stream substrate | pending | pending | Create/read state, enqueue or inspect queue if available, inspect stream/trigger status, report invocation IDs. | `state::*`, `queue::*`, `stream::*` through `execute` | pending | pending | pending | pending | pending | 0 |
| RWO-007 subagent real use case | pending | pending | Delegate one narrow repo topic to a subagent and report lineage/capabilities. | `agent::spawn_subagent`/status/result or canonical agent path | pending | pending | pending | pending | pending | 0 |
| RWO-008 memory auto-retain context | pending | pending | Summarize a durable project lesson and observe whether memory auto-retain uses engine capabilities. | `memory::*` background workflow plus visible invocation/event lineage | pending | pending | pending | pending | pending | 0 |
| RWO-009 high-risk approval boundary | pending | pending | Attempt bounded high-risk mutation, deny once, approve once, and prove child/durable behavior. | approval records plus target child invocation only after approval | pending | pending | pending | pending | pending | 0 |
| RWO-010 server restart reconnect | pending | pending | Restart dev server during a mounted session and continue after reconnect. | connection events, preserved invocation state, no duplicate turn | pending | pending | pending | pending | pending | 0 |
| RWO-011 module worker package activation | pending | pending | Run deterministic package activation fixture through canonical capabilities. | `module::*`, `worker::spawn`, health, disable, recovery, grants/resources | pending | pending | pending | pending | pending | 0 |
| RWO-012 provider parity | pending | pending | Repeat intent-only read, safe process, and `needs_input` on every configured provider. | identical model-visible `execute` schema and child behavior | pending | pending | pending | pending | pending | 0 |

## Already exercised and fixed

| Area | Status | What was proven or fixed | Evidence |
|---|---|---|---|
| Dev server automation | Covered | `./scripts/tron status --json` is the authoritative automation check; dev takeover PID confusion was fixed by making scripts deterministic for agent use. Background dev startup now boots out stale loaded-but-not-running dev LaunchAgents before bootstrapping a fresh one. | Dev script checkpoint, `tron_dev_background_start_is_file_logged_and_health_checked`, simulator-testing notes |
| Worktree isolation fail-closed | Covered by focused tests and simulator | Prompt runs, capability subagents, and subsessions fail before model execution when configured worktree isolation cannot be acquired. The hidden downgrade to the original repository was removed, and worktree creation no longer runs checkout hooks. | RWO-002 session `sess_019e6deb-c688-7f93-ae8f-0b7a41a226fb`; `prompt_worktree_acquisition_errors_do_not_passthrough_to_repo_root`; `spawn_fails_closed_when_subagent_worktree_acquisition_fails`; `spawn_subsession_fails_closed_when_worktree_acquisition_fails`; `create_worktree_does_not_run_checkout_hooks` |
| Prompt Library management | Covered | Management moved to server-authored generated UI; picker remains local composer insertion only. Styling, toast feedback, and expand/collapse behavior were cleaned up. | iOS Prompt Library source guards and generated UI tests |
| Engine Console capability UI | Covered | Removed redundant titles, improved inspection sheet hierarchy, color alignment, and tool-chip names. | Simulator screenshots and iOS source guards |
| Approval event ordering | Covered | Approval chips now sort before the resumed result when that was the actual event order. | Simulator retest and event ordering fix |
| Read-only process safety | Covered | Safe read-only process commands run directly; write-like `read_only` commands fail before child mutation. A fresh simulator session ran `date`, `pwd`, `test -f README.md`, bounded `sed -n`, and `git status --short` through `execute`/`process::run`; all five children succeeded with no approval, no durable refs, and bounded stdout/stderr/exit data in the ledger. A later simulator session tried redirection, deletion, Python file write, and curl POST as `read_only`; all four were `target_policy_rejected` with empty `childInvocationIds`, empty `resourceRefs`, zero approvals, and no marker files in the worktree. | Safe-read session `sess_019e6cf6-1c1b-74e3-9c74-2a67cd8ce7ce`; process children `019e6cf6-fc59-7170-a275-f821524b4122`, `019e6cf7-0489-79c3-ad4f-403a16c9d200`, `019e6cf7-0cb3-7c33-8505-bf17d0d97ffa`, `019e6cf7-1756-76d3-8709-877cf690e088`, `019e6cf7-1e3a-7bb0-a624-4f7cdbdb3fa7`; rejection session `sess_019e6d01-dcf1-7d90-a405-e8502fecc66a`; rejected execute invocations `019e6d02-af02-7301-89a8-1d3eec3a127c`, `019e6d02-b757-7152-bf7c-dcb05c6d147f`, `019e6d02-c22d-7603-affd-fa6cfd01aa74`, `019e6d02-d29c-7f50-8085-ef6249c52651`; process policy tests |
| Sandbox materialized process | Covered | Expected-output schema confusion was fixed; materialized output returns resource refs and approval/resume state. A simulator replay test ran one sandbox-materialized command with `expectedOutputs`, created one approval, executed one `process::run` child, returned `materialized_file` and `execution_output` refs, then replayed the same idempotency key through approval/idempotency without creating a second process child. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; approval `019e6d06-7d90-75f2-a731-4a42173b851c`; process child `019e6d06-d078-7d52-82ed-62d578d3072e`; materialized file `materialized_file:449b2b5be1c00eb0b51048d23f51f5fc21927507c6d93418ecc7d755aadf9f15`; execution output `res_019e6d06-d0a2-7861-adc5-f4fdfa545441`; process/orchestration tests |
| Approval denial | Covered in simulator | A sandbox-materialized `process::run` approval was denied. The engine recorded one denied approval, one `approval::resolve`, no `process::run` child, no resource refs, no durable output file, and a clear `capability::execute` denial result. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; approval `019e6d14-9b5b-7cc0-bee2-3d33e345d94a`; execute parent `019e6d14-9a7a-7040-b971-f9332687fd61`; approval resolve `019e6d14-d794-7270-b384-b21ce32972b0`; idempotency key `idem-approval-deny-2026-05-28-1035`; no `denied-output-2026-05-28-1035.txt` in the session worktree |
| Duplicate approval submission | Covered in simulator | A sandbox-materialized `process::run` approval was approved with a deliberate double tap. The substrate collapsed it to one approval row, one `approval::resolve`, one `process::run` child, two produced refs, and one materialized output file with exact expected content. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; approval `019e6d18-7038-7f51-9276-60743e9d3d29`; execute parent `019e6d18-6f3c-7a13-b29c-89af4dbb5db8`; approval resolve `019e6d18-a906-7ec1-a787-542b1a2f5507`; process child `019e6d18-a908-71e1-982a-c680df9c2822`; materialized file `materialized_file:fc4cf636323470fb55bcfd285e0f427f8b114c3ea00d2e2d76d41de700805ca1`; execution output `res_019e6d18-a927-7e03-97a8-624b9d4d31ea` |
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
| Literal-first filesystem content search | Covered in simulator | A repo-understanding simulator pass exposed that `filesystem::search_text` rejected literal code tokens such as `dispatch(` because the capability treated `pattern` as mandatory regex. The capability now searches literal text by default and supports regex only with explicit `regex: true`; the rebuilt-server retest completed with six successful searches, no process calls, no approvals, no failed invocations, and no non-ok capability completions. | Epsilon failure session `sess_019e6d98-3528-73e2-b2a5-74a7afd954e1`; fixed zeta pass `sess_019e6daa-a76c-7c90-9bd2-fce540be184a`; `search_text_treats_pattern_as_literal_by_default`; `search_text_supports_explicit_regex_mode`; `filesystem_contracts_steer_guessy_path_discovery_to_find_or_glob` |
| Exact replacement patch replay | Covered in simulator | A simulator session called `filesystem::apply_patch` twice with `idempotencyKey=idem-exact-replace-2026-05-28-0450`, then read the file. The first child created one materialized-file ref and one patch-proposal ref; the second child replayed from the first with the same refs; the final worktree file contained the marker exactly once. | DB session `sess_019e6ceb-6eeb-7b91-88b9-2ee810d083cd`; child invocations `019e6cec-5d60-7b50-8efb-e70a101d6a3c` and replay `019e6cec-68f3-77e2-8e96-aa4364889c51`; final file `README.md` contained `exact-replace-2026-05-28-0450` once |
| Failed patch validation | Covered in simulator | A simulator session attempted `filesystem::apply_patch` with a missing `oldString`, then searched for the proposed marker. The failed child returned `PATTERN_NOT_FOUND`, produced `[]`, created no materialized update or patch proposal, and the search returned zero matches. | DB session `sess_019e6cef-179e-7dc2-9640-577d74ea4f19`; failed child `019e6cf0-b9c3-7121-8221-b93daa15ed1b`; search child `019e6cf0-c4de-7032-871b-4e3092696d3d` |
| `find`/`write_file`/`edit_file` substrate | Covered in simulator | A simulator continuation ran bounded `filesystem::find`, `filesystem::write_file` twice with one idempotency key, `filesystem::edit_file` twice with one idempotency key, and a final `read_file`. `find` returned exactly two matches with `truncated=true`; second write/edit invocations replayed from their first children with identical resource refs; final file content was `beta\nstable\n`. | DB session `sess_019e6cef-179e-7dc2-9640-577d74ea4f19`; find child `019e6cf3-49fb-7011-8311-fb11ae635727`; write child/replay `019e6cf3-5454-7431-b396-276ac5c08b3c`/`019e6cf3-5f4a-75a2-996a-754910d1105c`; edit child/replay `019e6cf3-6ae2-7361-baa6-2599f07dd1c3`/`019e6cf3-7581-71c2-a07d-2acd1a058c00`; read child `019e6cf3-7e63-7a53-a56a-44bf1147cf75` |
| Generated UI stored action submit | Covered in simulator | A chat-driven simulator test created a prompt-snippet `resource_collection` surface through `ui::surface_for_target`, then submitted the stored `create-snippet` action through `ui::submit_action`. The target child was `prompt_library::snippet_create`, no approval was required, and the only durable output was the prompt-snippet `artifact` ref. The test also exposed an ergonomics gap where `ui::submit_action` required `idempotencyKey` inside target arguments; `execute` now safely copies the top-level wrapper key into target arguments when the selected target schema declares that field. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; surface invocation `019e6d1e-b378-71a2-93cd-f09f1a6e43f9`; `ui_surface` `ui-surface-resource_collection-artifact-prompt-snippet` version `ver_019e6d1e-b37f-7d22-a5cf-05338ae6fb55`; submit invocation `019e6d1e-e230-7870-904d-e3a57a4ea82a`; snippet child `019e6d1e-e232-7f32-a6a6-4f86ca77b543`; artifact `artifact:prompt-snippet:019e6d1e-e234-7a71-a130-64ec683d1a06`; `orchestrated_execute_forwards_wrapper_idempotency_when_target_schema_requires_it` |
| Generated UI wrapper idempotency forwarding | Covered in simulator | A rebuilt-server simulator retest submitted a generated prompt-snippet action while keeping `idempotencyKey` only at the top-level `execute` wrapper. The orchestrator copied that key into the target `ui::submit_action` arguments, recorded `wrapper_idempotency_key_to_target_argument`, and executed exactly one target child with no `needs_input` retry. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; surface invocation `019e6d31-85ec-7f11-afcf-43444844a2cb`; surface version `ver_019e6d31-85f2-7b71-a063-db00606143c1`; execute invocation `019e6d31-95e8-72c3-b732-bcd6b68d7375`; submit invocation `019e6d31-96c3-7822-a471-04d42b794450`; snippet child `019e6d31-96c4-72a2-abc8-e1f369e4dd58`; artifact `artifact:prompt-snippet:019e6d31-96c4-72a2-abc8-e20d9988ce68`; correction kinds `wrapper_idempotency_key_to_target_argument`, `freshness_prepared` |
| Generated UI malformed input rejection | Covered in simulator | A simulator test created a prompt-snippet `resource_collection` surface, then intentionally submitted the stored `create-snippet` action with `userInput` missing `text`. `ui::submit_action` failed schema validation at `$.text`, produced no resource refs, and no `prompt_library::snippet_create` target child ran. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; surface invocation `019e6d37-720f-7c13-800c-aaae33579779`; surface version `ver_019e6d37-7215-7aa3-9543-81eed0a2885a`; failed submit invocation `019e6d37-83c3-75c3-813a-98d16d0ea5fd`; error kind `schema_violation`; error path `$.text`; matching prompt-library target children `0` |
| Fixed iOS management sheet generated action path | Covered in simulator | The Prompt Library management sheet created snippets through server-authored generated UI rather than local management code. A normal create and a deliberate double tap both produced exactly one `ui::submit_action` and one `prompt_library::snippet_create` child for each submitted snippet, with artifact refs as the only durable outputs. | UI-created `Sheet alpha`: engine invoke `019e6d3c-2ac2-78d2-a9ff-7ed31449183d`, submit `019e6d3c-2ac2-78d2-a9ff-7eefd3415344`, child `019e6d3c-2ac7-7ed1-a8f2-d2fcf6d39b01`, artifact `artifact:prompt-snippet:019e6d3c-2ac8-7d12-9cd7-5382e9422fa5`; double-tap `Sheet beta`: engine invoke `019e6d3d-d515-7d40-ad19-3491ce3ceda8`, submit `019e6d3d-d516-7a40-92f3-b03586f4bea1`, child `019e6d3d-d51c-77a0-b769-de0826806f6d`, artifact `artifact:prompt-snippet:019e6d3d-d51d-7e12-9551-cc1a5bfb99fb` |
| Generated UI stale surface rejection | Covered in simulator | After refreshing the prompt-snippet collection surface to a newer current version, a stale `ui::submit_action` using the older surface version failed with a `stale ui_surface version` policy violation. The failed submit produced no resource refs and no `prompt_library::snippet_create` child invocation. | DB session `sess_019e6d05-8cb5-7be2-a302-486ba0078b2e`; refresh invocation `019e6d20-e32e-7a92-831b-5209a62eece4`; new surface version `ver_019e6d20-e332-7ca0-9cd7-5ca14948d823`; stale submit invocation `019e6d20-fbe9-7ca1-813d-4e18ae47c904`; stale submit idempotency key `idem-ui-submit-stale-snippet-2026-05-28-1050`; zero matching prompt-library children for marker `STALE UI SHOULD NOT CREATE 2026-05-28 1050` |
| Direct Anthropic provider retest | Blocked | A direct `/engine` session on the default Anthropic model reached provider `tool_use` stop state but produced no capability child invocations. This is intentionally recorded as a provider-parity blocker instead of being blended into OpenAI substrate evidence. | DB session `sess_019e6c97-be45-7711-bee3-94b1c6ff1729`; Provider parity axis remains `0/5` |
| iOS reconnect after server rebuild | Covered by focused tests | Dashboard/chat connection state now belongs to the shared `EngineConnection` foreground reconnect loop. Normal reconnect keeps probing at a bounded cadence while foregrounded, so screens recover after dev-server rebuilds without owning retry logic or staying permanently failed until manual tap. | `ReconnectProbePolicyTests`, `EngineConnectionReconnectTests`, `packages/ios-app/docs/architecture.md`, `packages/ios-app/docs/onboarding.md` |
| Memory auto-retain | Partially covered | Auto-retain runs through engine capabilities and no longer blocks normal testing, but it needs a final regression under the current server build. | Prior server-log review; pending current-build retest |

## Real-world eval blocks

Run these as deterministic real sessions. Start each block by reading this
scorecard, then choose the next pending scenario with the highest substrate
value. A block is not complete until the iOS result and DB evidence agree.

### RWO-001 Agent Harness Smoke: Repo Understanding

Prompt:

```text
Use only execute. Inspect this repo enough to explain the engine's worker/function/trigger architecture. Do not answer from memory. Read relevant docs/code, list the capabilities used, and cite the files inspected.
```

Acceptance criteria:

- Uses `capability::execute` with filesystem discovery/read children.
- Uses `filesystem::list_dir`, `filesystem::search_text` or `filesystem::glob`,
  and `filesystem::read_file` unless it explains a better canonical filesystem
  path.
- Creates no approval and no durable target resource refs.
- Produces no failed probe invocations.
- Answer correctly describes workers registering functions/triggers and agents
  using the same capability fabric as the backend.

### RWO-002 Practical Code Change: Find, Edit, Verify

Prompt:

```text
Use only execute. Find the capability-orchestration scorecard, add one harmless note to a scratch test file or docs sandbox, verify it by reading/searching it back, then report resource refs. Use idempotency.
```

Acceptance criteria:

- Searches/reads before editing.
- Uses `filesystem::apply_patch` or `filesystem::write_file` for the mutation.
- Reports `materialized_file` and any proposal/output refs from the target
  child invocation.
- Reads or searches the edited content back.
- Replaying the same idempotency key does not duplicate edits or resources.

### RWO-003 Safe Process + Filesystem Composition

Prompt:

```text
Use only execute. Run safe read-only commands to inspect the repo status, current branch, and first three README lines. Then read README.md through filesystem and compare the first line. Report exact capabilities and whether approval was required.
```

Acceptance criteria:

- `process::run` read-only calls run without approval when classifier-proven
  safe.
- `filesystem::read_file` runs without approval.
- No durable resource refs are produced.
- UI and DB execution details make the run path clear.

### RWO-004 Web Research Through Capabilities

Prompt:

```text
Use only execute. Search the web for official OpenAI model documentation, fetch one result if available, summarize what source was used, and do not browse outside the capability system.
```

Acceptance criteria:

- Resolves to `web::search` and optionally `web::fetch`.
- Returns bounded source URLs/content.
- Network failures return actionable diagnostics, not hallucinated results.
- No browser/client-side policy path is used.

Status: passed in simulator session `sess_019e6f63-b6ac-7580-b91b-a7c25c8c7b75`.
The final retest used one search and one fetch through `execute`, with no
approval, shell/process, filesystem mutation, or failed target invocation.

### RWO-005 Browser/Display Capability Probe

Prompt:

```text
Use only execute. Discover whether browser or display capabilities are available. If available, inspect their status and report what they can safely do. Do not open arbitrary sites unless the capability explicitly supports it.
```

Acceptance criteria:

- Uses `browser::*` or `display::*` status capabilities when available.
- If not available, returns `needs_capability` or a clear unavailable status.
- Does not hallucinate browser APIs or perform arbitrary browsing.

### RWO-006 State, Queue, Stream, Trigger Substrate

Prompt:

```text
Use only execute. Create a small state value, read it back, enqueue a small queue item if the capability is available, inspect queue/drain status, and report every invocation id. Do not use external files.
```

Acceptance criteria:

- Uses state and queue primitives through `execute`.
- Demonstrates CAS/idempotency behavior where the capability supports it.
- Queue enqueue/drain status is traceable from DB rows.
- No new durable state plane is introduced.

### RWO-007 Subagent Real Use Case

Prompt:

```text
Use only execute. Spawn or delegate to a subagent to inspect one narrow repo topic, wait for the result, and report the subagent lineage and capabilities involved.
```

Acceptance criteria:

- Uses the canonical `agent::*` subagent path.
- Parent/child lineage is reconstructable from events and invocations.
- Subagent worktree/session isolation is visible.
- No separate harness bypass is required for the agent to use backend
  capabilities.

### RWO-008 Memory Auto-Retain and Context

Prompt:

```text
Use only execute. Ask the agent to summarize a durable project lesson, then observe whether memory auto-retain runs. Report whether memory actions went through engine capabilities.
```

Acceptance criteria:

- Auto-retain events are visible and bounded.
- Memory writes use `memory::*` capability paths or a documented internal-only
  boundary.
- No endless spinner or hidden client-owned memory policy.

### RWO-009 High-Risk Approval Scenario

Prompt:

```text
Use only execute. Attempt a high-risk but bounded mutation that requires approval, then wait for user denial. Report whether the child mutation ran and whether any durable output exists.
```

Acceptance criteria:

- Denial creates one approval and no target child execution.
- Durable refs remain empty on denial.
- Follow-up approval/double-tap creates one target child and one durable result.
- UI ordering remains chronological.

### RWO-010 Server Restart and App Reconnect

Procedure:

1. Start a session and begin a read-only multi-step task.
2. Restart the server with `./scripts/tron dev -bdt`.
3. Keep the simulator mounted.
4. Continue after reconnect.

Acceptance criteria:

- Dashboard and chat reconnect automatically.
- No duplicate turns or duplicate child invocations.
- Interrupted invocation state is inspectable.
- Failed/retried work is explicit, never silent.

### RWO-011 Module/Worker Package Activation

Use a deterministic server-side fixture, not a massive chat-authored manifest.

Acceptance criteria:

- Register digest-pinned local package, verify source, approve source,
  configure, activate local-process worker, health check, invoke a registered
  function, disable, and recover/inspect cleanup.
- Durable truth stays in resources, grants, invocations, evidence, workers, and
  links.
- Duplicate activation/recovery creates no duplicate workers or grants.
- No second worker-spawn path is introduced.

### RWO-012 Provider Parity

Run the same three prompts through every configured provider:

- intent-only read file;
- safe process command;
- missing required field returning `needs_input`.

Acceptance criteria:

- Providers expose only model-visible `execute`.
- Same target selected and same correction classes returned.
- Provider tool-call IDs do not alter child idempotency.

## Failure protocol

When any scenario fails, freeze the test and record:

- session id and prompt;
- visible UI result;
- `engine_invocations` rows for the turn tree;
- `capability_audit_events` rows for orchestration diagnostics;
- approvals, resources, queues, streams, state rows, and server logs when
  relevant.

Classify the layer before fixing:

- model prompt/guidance;
- execute resolution;
- schema/recipe;
- target capability;
- grant/approval;
- resource output;
- queue/retry;
- iOS rendering;
- provider runner.

Then add or identify the smallest failing automated test, fix the owning module
only, remove nearby dead/fallback/compatibility code if found, update
progressive docs when invariants change, rerun the exact scenario, update the
scenario ledger, and commit.

No workaround counts as fixed unless DB evidence proves the corrected path uses
canonical substrate primitives.

## Score update rules

- `+1` for a simulator-tested scenario with DB proof and no code changes
  required.
- `+1` to `+2` for a scenario that exposed a bug, received a root-cause fix,
  and passed retest.
- `0` for inconclusive tests, prompt-entry errors, or tests that only prove UI
  screenshots.
- No axis can reach full points until it has at least one success path, one
  failure path, one replay/idempotency path where relevant, and one DB
  reconstruction note.

Target checkpoints:

- `80/100`: real repo-inspection plus code-change orchestration pass.
- `84/100`: web/browser plus state/queue/stream substrate pass.
- `88/100`: subagent plus memory auto-retain pass.
- `92/100`: module/local-process package activation pass.
- `96/100`: restart/retry/crash resilience pass.
- `100/100`: provider parity plus no unclassified high-signal foundation gaps.

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
