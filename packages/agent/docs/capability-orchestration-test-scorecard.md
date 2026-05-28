# Capability orchestration test scorecard

Last updated: 2026-05-27.

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

Current manual-test substrate confidence: **58/100**.

This score is intentionally conservative. The production codebase can still be
high quality while this manual substrate exercise remains incomplete; this
score measures how much of the live execute/resource/approval/worker path has
been exercised end-to-end through the app and verified from server logs.

| Axis | Points | Current | Evidence | Remaining proof |
|---|---:|---:|---|---|
| Execute ergonomics and correction | 15 | 10 | `process::run` expected-output correction, wrapper/target guidance, `filesystem::apply_patch` append correction tests, live simulator append execution without probe failures, live `needs_selection`/`needs_capability` guardrails, and live `needs_input` guidance with exact missing paths | Stale-plan and provider-shape parity tests |
| Capability resolution and recipes | 10 | 7 | Engine Console search/inspect flows, resolved explicit `process::run` targets, live intent-only `filesystem::read_file` resolution from `execute` without an explicit target, broad/unknown intent fail-closed as `needs_capability`, filesystem-namespace ambiguity as `needs_selection`, and known-target missing input as `needs_input` | Intent-only resolution across process/web/worker/module, ranking audit, and vector-warmup degradation |
| Core filesystem/process paths | 15 | 10 | Read-only `process::run`, policy rejection for unsafe read-only commands, sandbox materialized output, live intent-only `filesystem::read_file`, live missing-file failure, live absolute-path root-bound rejection, and apply-patch append/replay tests | List/find/search/write/edit failure modes, timeouts, resource-output replay, and no probe calls |
| Approval and freshness | 10 | 5 | Approval-required sandbox command, resume ordering fix, no-approval detail-sheet suppression | Denial, timeout, stale revision, replayed approval, and concurrent approval edge cases |
| Idempotency and replay | 10 | 5 | Sandbox materialized replay inspection, apply-patch append replay unit/integration tests, and live simulator `filesystem::apply_patch` replay verification | Queue retry, duplicate UI submission, duplicate provider tool call, and cross-session replay |
| Resource-output substrate | 10 | 5 | Prompt library and voice notes resource conversions, materialized `process::run` output refs, patch proposal refs | Artifact/materialized-file damage, CAS, hash mismatch, discard, and retained evidence under failure |
| Generated UI/action gateway | 10 | 5 | Prompt management generated surface, action toasts, stale/offline fail-closed renderer behavior | Generic action staleness, malformed input, revoked grant, and target revision drift through live app |
| Module/worker extensibility | 10 | 2 | Rust module package activation/trust/health tests exist | Live local-process package activation, worker spawn/health/disable/recovery, trust audit, and package UI through app |
| Observability/log ingestion | 5 | 5 | Server ledger/event queries used during manual testing, auto-ingest path exercised, live replay test reconstructed from `engine_invocations` plus resource refs without relying on screenshots, and failed child invocations now remain visible in `execute` orchestration details | Standardize the DB query bundle for every scenario |
| Provider parity | 5 | 0 | Provider exports are covered by code tests, not manual testing yet | OpenAI, Anthropic, Gemini, Kimi, and Ollama execute-schema parity with identical correction/result behavior |

## Already exercised and fixed

| Area | Status | What was proven or fixed | Evidence |
|---|---|---|---|
| Dev server automation | Covered | `./scripts/tron status --json` is the authoritative automation check; dev takeover PID confusion was fixed by making scripts deterministic for agent use. Background dev startup now boots out stale loaded-but-not-running dev LaunchAgents before bootstrapping a fresh one. | Dev script checkpoint, `tron_dev_background_start_is_file_logged_and_health_checked`, simulator-testing notes |
| Prompt Library management | Covered | Management moved to server-authored generated UI; picker remains local composer insertion only. Styling, toast feedback, and expand/collapse behavior were cleaned up. | iOS Prompt Library source guards and generated UI tests |
| Engine Console capability UI | Covered | Removed redundant titles, improved inspection sheet hierarchy, color alignment, and tool-chip names. | Simulator screenshots and iOS source guards |
| Approval event ordering | Covered | Approval chips now sort before the resumed result when that was the actual event order. | Simulator retest and event ordering fix |
| Read-only process safety | Covered | Safe read-only process commands run directly; write-like `read_only` commands fail before child mutation. | Manual simulator tests and process policy tests |
| Sandbox materialized process | Covered with follow-up needed | Expected-output schema confusion was fixed; materialized output returns resource refs and approval/resume state. | Manual simulator test and process/orchestration tests |
| `filesystem::apply_patch` append | Covered | Append-only patches now use `oldString: ""`; execute normalizes missing `oldString` plus non-empty `newString` into that stable shape. Duplicate child keys replay instead of conflicting after a read/probe retry. Live simulator retest appended `automated replay smoke 2026-05-27 13:50` exactly once: the first child `filesystem::apply_patch` succeeded with `idem-apply-2026-05-27-1350`, the second child replayed from it, and no `read_file` or `process::run` appeared in the ledger. | `filesystem_apply_patch_empty_old_string_appends_and_replays`, `orchestrated_execute_normalizes_apply_patch_append_intent`, `capability_execute_apply_patch_append_shape_runs_without_failed_probe`, DB session `sess_019e6b1a-c7b4-7e81-9aff-1de4e632597d` |
| Intent-only `filesystem::read_file` | Covered | A fresh simulator session asked the model to use only `execute`, with no target, to read the first line of `README.md`. The orchestrator resolved `filesystem::read_file` in `intent_resolution` mode, ran one child invocation, required no approval, produced no resource refs, and returned `Testing out a README here.` | DB session `sess_019e6b22-5d18-75e3-909d-ffff4223aa0c`, `capability.orchestration` audit event at `2026-05-27T20:31:55Z` |
| Broad unresolved intent | Covered | A fresh simulator session called `execute` with intent `work with README.md` and empty arguments. The result failed closed as `needs_capability`, returned low-confidence candidates and a proposed capability shape, and created no child invocation. This is the intended behavior for no clear namespace/action anchor. | DB session `sess_019e6b25-445a-7ae2-82be-397acb398fff`, payload ref `payload_ref_019e6b25-ebc3-7a50-885e-7dbcb262ade8` |
| Namespace ambiguity | Covered | A fresh simulator session called `execute` with intent `filesystem README.md` and empty arguments. The result was `needs_selection`, returned bounded filesystem candidates, and created no child invocation. | DB session `sess_019e6b28-b568-7690-96b3-f1518b48fba7`, payload ref `payload_ref_019e6b29-7131-7d83-8bd0-b0bbf4dc5268` |
| Missing required input | Covered | A fresh simulator session called `execute` with intent `read a file` and empty arguments. The result selected `filesystem::read_file`, returned `needs_input`, reported missing `arguments.path`, included a concrete corrected example, and created no child invocation. | DB session `sess_019e6bd6-6178-7ca2-be97-5ff962236885`, payload ref `payload_ref_019e6bd6-fc9e-7273-8e6b-da475db81906` |
| Unknown capability intent | Covered | A fresh simulator session called `execute` with intent `calibrate a quantum pineapple teleporter` and empty arguments. The result was `needs_capability`, included the proposed capability shape, returned bounded low-confidence candidates, and created no child invocation. | DB session `sess_019e6bd8-a9a3-7922-9eee-37775e725f2c` |
| Model-facing filesystem root bounds | Covered | A simulator guardrail session proved missing files fail cleanly and absolute host paths such as `/etc/passwd` are rejected inside the model-facing filesystem capability path. Relative and allowed absolute paths still resolve against the active session worktree, while raw service helpers remain trusted-local internals only. Failed child invocations now surface in `execute.details.childInvocationIds` and nested orchestration details instead of disappearing from the user-facing result. | `filesystem::*` tests, `capability_execute_reports_failed_child_invocation_lineage`, DB sessions `sess_019e6bde-08d5-7331-8577-c74335d84ada` and `sess_019e6bec-0218-7d51-a211-0fe632f2963a` |
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

The next checkpoint should continue filesystem substrate breadth:

1. `filesystem::list_dir`, `filesystem::glob`, and `filesystem::search_text`
   bounded result behavior;
2. exact replacement `filesystem::apply_patch` and duplicate idempotency;
3. failed validation proving no accepted resource refs or child side effects;
4. reconnect recovery during a live dev-server rebuild while a dashboard/chat
   screen is already mounted.
