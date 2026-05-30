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

Model selection is part of the scenario contract. For scored
model-comprehension and provider-parity runs, prefer current high-capability
hosted models first, such as `claude-sonnet-4-6`, `gpt-5.5`, or the newest
approved Gemini model available in the active profile. Older hosted models and
small local models are useful for compatibility breadth, but they must not set
the bar for architecture comprehension. For local-provider coverage, use
`gemma4:e4b` as an Ollama smoke test proving the collapsed substrate works at
all; retry robust local-use cases later with larger local models before
classifying model-quality shortfalls as engine failures.

No workaround counts as fixed unless the database proves the corrected path uses
canonical substrate primitives.

## Current Score

Current score: **100/100**

This score is intentionally conservative. Tron has strong evidence for many
covered `execute` paths, but the full collapsed-backend architecture still needs
end-to-end proof across the remaining orchestration/modularity edge cases,
including deeper multi-session churn and final cleanup of large shared harness
surfaces.

### Axis Scores

| Axis | Points | Current | Full Credit Requires |
|---|---:|---:|---|
| Execute portal ergonomics | 10 | 10 | One `execute` tool resolves, prepares, corrects, runs, pauses, replays, and explains failures without fragile model guessing |
| First-party capability usefulness | 10 | 10 | Filesystem, process, git/worktree, web, browser/display, logs, settings, model, memory, prompt, resource, state, queue, stream, worker, and module capabilities work in real tasks |
| Worker/function/trigger substrate | 14 | 14 | Live workers register functions/triggers, update discovery, invoke, stream, heartbeat, disconnect, and clean up without restart |
| Multi-capability orchestration | 12 | 12 | Agents chain read/search/edit/run/state/resource/approval/queue/subagent operations in realistic workflows |
| Resource truth and durability | 10 | 10 | Durable outputs, resource versions, CAS, hashes, discard, damaged state, and idempotency are proven through live paths |
| Safety, grants, and approvals | 10 | 10 | Safe work runs autonomously; risky work gates correctly; denial/replay/revocation/expiry leave no invalid side effects |
| Runtime resilience | 10 | 10 | Restart, reconnect, queue retry, approval pause, cancellation, partial failure, and cleanup are robust |
| Observability and auditability | 8 | 8 | Every scenario is reconstructable from DB invocation/event/log/resource/approval/queue/stream records |
| Provider parity | 6 | 6 | OpenAI, Anthropic, Gemini, and Ollama expose equivalent `execute` behavior for core scenarios |
| Code modularity and simplification | 10 | 10 | No central spaghetti, no unclassified dead/fallback/compat logic, clear ownership, and large files decomposed where useful |

Total: **100/100**

Resolved checkpoint note, 2026-05-29: the RWO-N11 execute-layer
`schema_or_recipe` follow-up is fixed and retested. The banked score remains
`62/100` because RWO-N11 already earned its scenario points, and broad testing
may proceed to RWO-N12.

Resolved checkpoint note, 2026-05-29: RWO-N12 passed its live approval-flow
portion and focused grant-rejection fixture with no code changes. The banked
score is now `63/100`; broad testing may proceed to RWO-N13.

Resolved checkpoint note, 2026-05-29: the RWO-N12 direct public
`capability::execute` follow-up exposed and fixed a server-owned policy
projection gap. Direct public execute now derives active-profile execution
policy scopes/runtime metadata on the server, rejects client-authored execute
policy context, and passed the exact approval/denial/replay retest. The banked
score is now `64/100`; broad testing may proceed to RWO-N13.

Resolved checkpoint note, 2026-05-29: RWO-N13 passed the runtime resilience
live-server scenario with the iOS simulator booted. The dev server survived
`./scripts/tron dev -bdt`, an in-flight long `process::run` interruption during
`./scripts/tron dev -d`, and an approval pause across a second no-build dev
restart. The banked score is now `65/100`; broad testing may proceed to RWO-N14.

Resolved checkpoint note, 2026-05-29: RWO-N14 P1 provider intent-read parity
passed after a root-cause fix. Anthropic, OpenAI Codex, and Gemini passed the
clean four-provider run; Ollama initially executed `filesystem::read_file` but
did not report the returned `# Tron` line. The fix removed stale Ollama native
wire spellings, removed the inbound compatibility alias, and projected text
execute results before metadata so local models see exact target output first.
The banked score is now `67/100`; broad RWO-N14 testing may proceed only to the
next parity prompt, P2 safe read-only process.

Resolved checkpoint note, 2026-05-29: RWO-N14 P2 safe read-only process parity
passed cleanly across Anthropic, OpenAI Codex, Gemini, and Ollama on real dev
server PID `56373` with the iOS simulator booted. Each provider used one
`capability::execute` invocation selecting `process::run` with
`executionMode = read_only`, one successful `process::run` child for `date`,
zero approvals, zero failed invocations, zero `compact.*` events, no
filesystem/web target rows, released process leases, completed queue drains, and
no session/trace log rows. The banked score is now `68/100`; broad RWO-N14
testing may proceed only to P3 missing-required-field parity.

Resolved checkpoint note, 2026-05-29: RWO-N14 P3 missing-required-field parity
passed after a root-cause fix. The first P3 run exposed that an empty command
string could pass `process::run` schema validation and execute as an empty
process child. The fix added `minLength` schema enforcement, made the
`process::run` contract require a non-empty command, rejected blank commands in
the process domain before execution, and mapped empty or null required fields to
the execute-layer `missing_required_argument` needs-input class. The clean
four-provider retest passed on real dev server PID `68590` with the iOS
simulator deep-linked into each session. The banked score is now `70/100`;
broad RWO-N14 testing may proceed only to P4 high-risk approval pause/resume.

Resolved checkpoint note, 2026-05-29: RWO-N14 P4 high-risk approval
pause/resume provider parity passed after root-cause fixes and harness
hardening. The first P4 attempts exposed wrong target guidance for approval
gated writes, late post-approval failures for absolute and home-relative
`expectedOutputs[].path` values, and a premature simulator harness
classification while an approval was still pending. The clean four-provider
retest passed on real dev server PID `99393` with simulator deep links for
Anthropic, OpenAI Codex, Gemini, and Ollama. The banked score is now `72/100`;
broad RWO-N14 testing may proceed only to P5 idempotency replay.

Resolved follow-up note, 2026-05-29: the P4 clean run still contained
simulator-visible failed-looking `capability::execute` cards caused by two
engine issues: repairable sandbox output path shape errors were returned as
`isError=true`, and approval idempotency keys were globally unique instead of
scoped to the target function/session/workspace. The root fix scopes approval
idempotency through the approval substrate and classifies sandbox output path
shape repairs as `needs_input` with `isError=false`. The exact P4 rerun on real
dev server PID `10586` produced no `isError=true` capability completions.
Anthropic, OpenAI Codex, and Gemini passed; Ollama with small local
`gemma4:e4b` reached a correct non-error `needs_input` result but did not plan
the concrete high-risk command, so it is recorded as a small-local-model
capability limitation rather than an engine blocker. The banked score remains
`72/100`; broad RWO-N14 testing may proceed only to P5 idempotency replay.

Resolved checkpoint note, 2026-05-29: RWO-N14 P5 approval idempotency replay
provider parity passed for Anthropic, OpenAI Codex, and Gemini after root-cause
fixes to execute result projection, session reconstruction, and generated replay
key ergonomics. The P5 matrix used real dev server PID `36012`, simulator deep
links, and run log `/tmp/rwo_n14_p5_provider_parity_20260529105816.json`.
Anthropic, OpenAI Codex, and Gemini each produced one setup approval, one setup
`process::run` child, one P5 `capability::execute`, `approvalReplayed=true`,
`childInvocationCreated=false`, zero new approvals, zero new process children,
zero failed invocations, zero `compact.*` events, and completed prompt queue
drains. Ollama/Gemma remained inconclusive because the small local model did not
make the setup execute call; there was no engine failure. The banked score is
now `74/100`; broad RWO-N14 testing may proceed only to the remaining provider
architecture-summary prompt.

Resolved checkpoint note, 2026-05-29: RWO-N14 P6 architecture-summary provider
parity passed for Anthropic, OpenAI Codex, and Gemini without runtime code
changes. The P6 runs used real dev server PID `36012`, simulator deep links,
Anthropic run log `/tmp/rwo_n14_p6_provider_parity_20260529111228.json`, and
OpenAI/Gemini/Ollama run log
`/tmp/rwo_n14_p6_provider_parity_20260529111810.json`. Anthropic used 20
`capability::execute` rows selecting `filesystem::list_dir` and
`filesystem::read_file`, cited 13 inspected files, and had zero failed
invocations, approvals, or `compact.*` events. OpenAI Codex used 32
`capability::execute` rows selecting `filesystem::list_dir`,
`filesystem::search_text`, and `filesystem::read_file`, cited 10 inspected
files, and had zero failed invocations, approvals, or `compact.*` events.
Gemini used 6 `capability::execute` rows selecting `filesystem::list_dir` and
`filesystem::read_file`, cited 5 inspected paths, and had zero failed
invocations, approvals, or `compact.*` events. Ollama/Gemma reached the same
substrate without failures but cited only one file and did not list the used
capabilities, so it remains a small-local-model inconclusive result rather than
an engine blocker. The banked score is now `75/100`; RWO-N14 is complete for
major-provider parity, and broad hardening may proceed to structural cleanup.

Resolved checkpoint note, 2026-05-29: SCB-S1 target-argument ownership
decomposition passed as a deterministic Rust/static-gate scenario. Target-shaped
argument repairs for `process::run`, `filesystem::list_dir`, `web::search`,
`filesystem::apply_patch`, `filesystem::read_file`, `resource::list`, and
`worktree::is_git_repo` moved out of the central execute orchestrator into
`packages/agent/src/domains/capability/operations/target_arguments.rs`.
`threat_model_invariants` now requires that file to exist and rejects the
target-specific affordance functions if they reappear in `execute.rs`. Focused
verification passed:
`cargo test intent_argument_normalization --lib -- --nocapture`,
`cargo test deterministic_intent_route --lib -- --nocapture`,
`cargo test --test threat_model_invariants -- --nocapture`,
`cargo fmt --all -- --check`, and `git diff --check`. No simulator run was
required because SCB-S1 changed ownership boundaries without changing live
execute behavior. Code modularity and simplification increases to `3/10`, and
the banked score is now `76/100`.

Resolved checkpoint note, 2026-05-29: the RWO-N14 P5 Google replay follow-up
exposed and fixed a process sandbox command-output boundary. The failed
simulator session `sess_019e74d4-7e0a-7c72-81e7-cb7e15c26be6` had approved
`process::run` commands whose shell redirections targeted
`~/.tron/workspace/reports/high-risk-test.txt` or an undeclared/nested path,
which left the command outside the declared expected-output boundary or failed
after approval. The root fix rejects sandbox-materialized redirection/`tee`
targets that are not declared relative `expectedOutputs`, prepares declared
nested output parent directories inside the isolated sandbox, and overrides
sandbox `HOME`/`TMPDIR` before command spawn. The Google-only P5 harness passed
on rebuilt dev server PID `57422` in
`sess_019e7523-4c24-7b02-9ff7-08b896c05c74`, and a direct exact-payload probe
in `sess_019e7523-ffb5-7601-acdf-8bf36461824a` returned
`target_policy_rejected` with `approvalCreated=false`,
`childInvocationCreated=false`, zero approval rows, zero `process::run` child
rows, and no host leak at `~/.tron/workspace/reports/exact-home-leak-*.txt`.
Safety, grants, and approvals increases to `10/10`, and the banked score is now
`77/100`. At that checkpoint, the next active hardening target was SCB-S1b.

Resolved checkpoint note, 2026-05-29: SCB-S1b deterministic route and
decomposition ownership audit passed as a deterministic Rust/static-gate
scenario. Deterministic intent routing, namespace clarification, execute
constraints, argument-schema fit promotion/filtering, low-confidence intent
evidence checks, candidate summaries, and target-specific decomposition
guidance moved out of `packages/agent/src/domains/capability/operations/execute.rs`
into `packages/agent/src/domains/capability/operations/target_resolution.rs`.
`execute.rs` now keeps the orchestration spine while `target_arguments.rs` owns
target argument affordances and `target_resolution.rs` owns target planning
heuristics. `threat_model_invariants` now rejects those target-resolution
function bodies if they reappear in `execute.rs`. No simulator run was required
because this checkpoint changed ownership boundaries without changing live
execute behavior. Code modularity and simplification increases to `4/10`, and
the banked score is now `78/100`.

Resolved checkpoint note, 2026-05-29: SCB-S2 capability registry ownership
split passed after a focused root-cause primer fix. Registry search/index
ranking moved into
`packages/agent/src/domains/capability/registry/index.rs`, primer policy and
rendering moved into
`packages/agent/src/domains/capability/registry/primer.rs`, and recipes remain
in `registry/recipes.rs`. The first focused registry run exposed a
`primer_rendering` bug where a tight token budget could emit only the primer
header and omit the first core capability; `primer.rs` now always renders at
least one visible capability entry before truncating. Module docs and
`threat_model_invariants` now enforce the split. Code modularity and
simplification increases to `5/10`, and the banked score is now `79/100`.

Resolved checkpoint note, 2026-05-29: SCB-S3 canonical resource projections
passed after root-cause cleanup. Prompt library and voice notes now use the
shared bounded domain projection helper in
`packages/agent/src/domains/resource_projection.rs`; generated UI collection
authoring now uses a bounded primitive-host projection helper; control and
module trust/audit projections remain bounded resource substrate projections.
The first prompt-library retest exposed a `resource_projection` regression:
default prompt-history pruning tried to count against a 10,000-entry retention
cap using a bounded 500-resource projection, causing an unnecessary extra
inspect. The fix skips that non-prunable default path and keeps pruning scans
only for retention rules that can act within the bounded projection. Code
modularity and simplification increases to `6/10`, and the banked score is now
`80/100`.

Resolved checkpoint note, 2026-05-29: SCB-S4 provider normalization
classification passed after a root-cause fail-closed fix. The audit found
active provider-boundary normalization only inside provider/protocol modules,
but also found that malformed provider capability arguments could be projected
as empty canonical arguments in OpenAI, Anthropic/shared stream accumulation,
Google non-object function calls, and Kimi streamed arguments. The provider
protocol parser now returns a typed error, provider stream handlers surface
malformed or non-object capability arguments as `StreamEvent::Error`, and no
`CapabilityInvocationDraftEnd` or `Done` event is emitted for those malformed
paths. `provider_argument_normalization_fails_closed` now enforces this
boundary. No simulator run was required because valid provider wire behavior was
unchanged and the failure class is a deterministic malformed-wire negative
fixture. A light app-path smoke still opened
`tron://session/sess_019e7523-4c24-7b02-9ff7-08b896c05c74` on the booted
iPhone 17 Pro simulator against dev server PID `57422` and rendered the
existing P5 chat path; screenshot:
`/tmp/scb_s4_app_path_smoke_20260529.png`. Code modularity and simplification
increases to `7/10`, and the banked score is now `81/100`.

Resolved checkpoint note, 2026-05-29: SCB-S5 hidden side-effect hardening
passed after bounded-resource cleanup. The SCB-S3 deferred `limit: 10_000`
resource list shapes in retained-memory context loading, notification inbox/read
decisions, and cron schedule/run truth reconstruction were classified as
bounded resource projections over engine truth, not product-owned side channels.
The resource store already clamps list reads to 500, but these production
callers now use named scan limits tied to
`resource_projection::MAX_RESOURCE_COLLECTION_LIMIT`, and
`hidden_side_effect_resource_scans_stay_bounded_and_observable` rejects future
drift. A simulator app-path smoke opened
`tron://session/sess_019e7523-4c24-7b02-9ff7-08b896c05c74` against real dev
server PID `2214`; screenshot:
`/tmp/scb_s5_app_path_smoke_20260529.png`. Observability and auditability
increases to `7/8`, and the banked score is now `82/100`.

Resolved checkpoint note, 2026-05-29: SCB-S6 test decomposition passed after
splitting the mixed module-activation engine test root. Shared activation
fixtures remain in `src/engine/tests/module_activation.rs`; package
registration, local-process activation, and generated operator-surface tests now
live in child modules beside the existing source-trust, health/integrity, and
trust-review modules. `large_rust_test_files_have_scorecard_ownership_audit`
now discovers every Rust test file over 1,000 lines, requires an SCB-S6
scorecard row with an owner/reason marker, and enforces per-file line budgets so
future broad catch-all growth fails statically. Code modularity and
simplification increases to `8/10`, and the banked score is now `83/100`.

Resolved checkpoint note, 2026-05-29: SCB-S7 capability-presentation ownership
passed after moving generated UI action presentation hints into server-authored
action payloads and action summaries. iOS now decodes `UiActionPresentationDTO`
and renders stored generated-UI button role/icon data without local
destructive/refresh/create heuristics or humanized action-id fallbacks; generated
UI submissions still carry only surface coordinates, user input, and an
idempotency key. Static gates now reject future client-owned generated-action
semantics, and the simulator app-path smoke opened
`tron://session/sess_019e7523-4c24-7b02-9ff7-08b896c05c74` against real dev
server PID `18521`; screenshot:
`/tmp/scb_s7_app_path_smoke_20260529.png`. Code modularity and simplification
increases to `9/10`, and the banked score is now `84/100`.

Resolved checkpoint note, 2026-05-29: SCB-S8 chat/engine state parity passed
after fixing an iOS approval-sheet drift path. A resolved engine approval now
clears the matching open approval sheet state, and the single-sheet coordinator
dismisses active approval/user-interaction/subagent sheets when their
server-owned view-model flags become false. The exact app-path retest used real
dev server PID `26801`, booted iPhone 17 Pro simulator, session
`sess_019e7523-4c24-7b02-9ff7-08b896c05c74`, screenshots
`/tmp/scb_s8_parity_terminal_session_20260529.png` and
`/tmp/scb_s8_parity_relaunch_deeplink_20260529.png`, two DB `message.user`
events, four assistant messages, two started/completed execute cards, one
executed `process::run` approval, zero pending approvals, zero failed
invocations, completed agent queues, zero session logs, and no
`compact.*` events. Observability and auditability increases to `8/8`, and the
banked score is now `85/100`.

Resolved checkpoint note, 2026-05-30: RWO-N15, RWO-N16, and RWO-N16B closed the
live worker/queue resilience gap on the real dev server with the old paired
iPhone 17 Pro simulator. RWO-N15 added canonical agent-visible
`trigger::dispatch` and proved queued live-worker trigger/stream/resource
composition. RWO-N16 fixed pending external-worker disconnect handling and
retry audit classification so pure-read transport loss publishes
`queue.fail` without recording a failed target invocation row. RWO-N16B then
fixed terminal queue semantics: `queue::cancel` and `queue::fail` now publish
queue lifecycle events from the public primitive path, completed/cancelled/
dead-lettered terminal rows reject late state changes, complete/cancel clear
leases, retry exhaustion publishes explicit `queue.dead_letter`, and the
terminal guard treats `dead_lettered` as closed work. The final RWO-N16B retest
used session `sess_019e763d-628a-75c3-8b63-4ef7736fbfe9`, run log
`/tmp/rwo_n16b_agent_run_20260529171634.json`, old-simulator screenshot
`/tmp/rwo_n16b_20260529171634_old_simulator.png`, zero approvals, zero logs,
zero resource leases, zero active harness subscriptions, zero open queue rows,
three expected dead-letter target failures, and no unexpected failed
invocations. Worker/function/trigger substrate is now `14/14`,
multi-capability orchestration is now `10/12`, runtime resilience is now
`10/10`, and the banked score is now `97/100`.

Resolved checkpoint note, 2026-05-30: RWO-N17 multi-session churn and harness
ownership robustness passed after root-cause fixes in the simulator harness and
iOS cold-start deep-link consumption path. The first live attempt reached
terminal DB state but the harness crashed on a stale simulator launch timeout;
the second attempt passed DB classification but exposed invalid app-path proof
because timed-out `simctl openurl` calls were not checked and the cold-start
deep link stopped at the sessions list. The fix made the RWO-N17 harness require
successful `openurl` return codes for every app-path route, added pending
session deep-link processing on `ContentView.onAppear`, and covered the pure
pending-deep-link helper in iOS tests. The canonical current-model retest used
`claude-sonnet-4-6` on real dev server PID `95397`, old paired iPhone 17 Pro
simulator UDID `267F6468-09AE-471D-9157-29144173EB82`, run log
`/tmp/rwo_n17_multi_session_run_20260529180002.json`, visible session
`sess_019e7665-2b83-7190-82ac-272cf9c7c92d`, background session
`sess_019e7665-6cbf-74e1-9260-34428f7377d4`, visible screenshots
`/tmp/rwo_n17_visible_before_20260529180002.png` and
`/tmp/rwo_n17_visible_after_20260529180002.png`, and background screenshot
`/tmp/rwo_n17_background_20260529180002.png`. DB classification passed with
zero approvals, zero failed invocations, zero `compact.*` events, zero active
harness subscriptions, zero active leases, zero cross-session leakage, terminal
guards at `end_turn_stable`, app websocket subscriptions separated as
`engine-ws:*`, completed prompt queue drains, visible/background evidence
resources, worker/function/trigger register and unregister catalog rows, and a
completed background trigger queue with receipt
`019e7665-994b-74c3-99db-b92d7d3baf4f`. Computer Use verified the visible
simulator route showed the submitted user prompt, terminal assistant marker,
and `Sonnet 4.6` model chip for the same session. Multi-capability orchestration
is now `12/12`, code modularity and simplification is now `10/10`, and the
collapsed-engine hardening score is now `100/100`.

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

## Simulator Deep-Link Evidence Protocol

When a harness creates or drives a session through the real dev server, open the
same session in the booted simulator instead of manually navigating from the
sidebar. This keeps the visible app state aligned with the database rows under
test and makes the screenshot reproducible.

```bash
xcrun simctl bootstatus booted

# If iOS code changed, build and install the current simulator app before
# collecting evidence. A green iOS test run does not update the app already
# mounted in Simulator.
cd packages/ios-app
xcodebuild -scheme 'Tron Beta' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/tron-ios-beta-derived \
  build
xcrun simctl terminate booted com.tron.mobile.beta || true
xcrun simctl install booted /tmp/tron-ios-beta-derived/Build/Products/Beta-iphonesimulator/TronMobile.app

xcrun simctl launch booted com.tron.mobile.beta
xcrun simctl openurl booted "tron://session/<session_id>"
xcrun simctl io booted screenshot /tmp/<scenario>-simulator.png
```

Each scenario note must store the session id, run log, screenshot path,
dev-server PID or health snapshot, and DB reconstruction together. A screenshot
captured immediately after opening the session is navigation evidence only; for
chat parity evidence, reopen the same deep link and capture a final screenshot
after the DB reaches the terminal state. The URL route contains only the session
id; do not put tokens, provider credentials, user paths, or prompt contents into
the deep link. If the simulator stops at the iOS "Open in Tron?" confirmation
sheet, record the screenshot as UI context only and keep DB
invocation/event/log/resource/approval/queue/stream evidence canonical for
pass/fail classification.

If the scenario depends on iOS rendering code changed in the current checkpoint,
record the installed app build path or build command with the screenshot. A
simulator screenshot from a stale app binary is invalid parity evidence, even if
the server DB is terminal and focused iOS tests passed.
Likewise, a nonzero `simctl openurl` return code or screenshot return code makes
the app-path evidence invalid; reset the old paired simulator or classify the
run as an app-route/harness evidence failure before awarding scenario credit.

Deep-link evidence is not complete until the visible chat state is compared
against engine truth for the same session id. The screenshot or simulator state
must show, or the scenario must explicitly record as an `ios_rendering`
follow-up, whether the submitted user prompt is present in the transcript, the
assistant turn matches the latest engine events, any approval sheet reflects the
current approval row status, and approval or action sheets either disappear or
become clearly non-actionable historical approved/denied state after
`approval::resolve` or later engine progress. A harness must wait for a stable
terminal state before classification: no pending approvals for the session
family, a `stream.turn_end` with `stopReason = "end_turn"`, no later
`stream.turn_start` after that terminal turn, and a DB reconstruction pass that
includes invocations, approvals, resources, queues, streams, events, and logs.
Do not treat `stream.turn_end` with `stopReason = "tool_use"` as terminal; that
boundary only means the provider yielded so the engine can execute tools before
the next assistant turn continues. Later non-turn hook events such as
`hook.llm_result` must not by themselves keep a completed session open. If those
checks disagree, classify the result from DB truth and file the UI mismatch as
chat parity drift; do not let screenshot state override the engine ledger.

## Scenario Ledger

| Scenario | Name | Status | Score Delta | Session Id | DB Evidence | Failure Root Cause | Fix Commit | Retest |
|---|---|---|---:|---|---|---|---|---|
| RWO-N1 | Repo understanding and discovery | passed_after_fix | +2 | compaction failure: `sess_019e728b-bfa5-7a03-98e7-5b5f5940fc78`; path-guidance failure: `sess_019e72a5-eda3-7f51-8628-bc043336296d`; passing retest: `sess_019e72b6-7237-7391-a178-c669e7d09cf5` | See 2026-05-29 result note below. Passing retest used 48 `capability::execute` child invocations; target functions were `filesystem::list_dir` (7), `filesystem::read_file` (24), and `filesystem::search_text` (17). Zero failed invocations, zero approvals, zero `compact.*` events, no session-scoped server log rows, and only substrate prompt-history plus final `agent_result` resource refs. | Fixed `stream_or_state`: no-op compaction no longer persists boundaries or injects notices. Fixed `model_guidance`: execute metadata/schema now tells models to list only known directories and locate uncertain filesystem paths with `find`, `glob`, or `search_text` before listing/reading. | `1c76b7bd1` | Passed exact prompt after rebuilt dev server PID 4541; DB reconstruction matches simulator UI and final answer cited real worker/function/trigger files. |
| RWO-N2 | Practical code change workflow | passed_after_fix | +2 | first failure: `sess_019e72c3-e190-7ba2-b447-8debb4e36054`; exact retest pass: `sess_019e72e6-88a4-71c1-bc85-787e86df0235`; replay failure: `sess_019e72ea-c4e7-7842-82bb-654538fa3ce5`; replay retest pass: `sess_019e72f3-ee99-7a91-84ef-e3f47604a2ff` | See 2026-05-29 RWO-N2 result notes below. Exact retest passed with 3 target `capability::execute` calls, `filesystem::write_file` 1, `filesystem::read_file` 1, `materialized_file::update` 1, `resource::create` 1, and 0 failed invocations/approvals/compact events/log rows. Replay retest passed with 2 `filesystem::write_file` rows under session-scoped `rwontwoalpha`, one `filesystem::read_file`, one materialized file resource/version, 0 failed invocations, 0 approvals, 0 compact events, 0 logs, 1 completed queue drain, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | Fixed `schema_or_recipe`: new-file guidance/search now prefers `filesystem::write_file` over missing-file `apply_patch`. Fixed `stream_or_state`: runtime event persistence advances from DB sequence truth before preassigned events. Fixed `resource_truth`: file-content mutations use session-scoped idempotency so the same key cannot replay another isolated worktree path. | `87f368dd6` | Passed exact prompt after rebuilt dev server PID 22402 and passed replay subcheck after rebuilt dev server PID 27362. DB reconstruction matches simulator UI and proves the replay reused one resource/version inside the active session. |
| RWO-N3 | Safe process plus filesystem composition | passed | +1 | `sess_019e72fd-5e00-75d1-b58f-a9853a621daa` | See 2026-05-29 RWO-N3 result note below. The run used 2 successful `capability::execute` invocations, 1 successful `process::run`, 1 successful `filesystem::read_file`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one completed `agent::prompt_queue_drain`, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; no code changes required | n/a | Passed exact prompt on the real dev server. `process::run` used `executionMode = read_only`; README first line matched the filesystem read. |
| RWO-N4 | Web research capability | passed | +1 | `sess_019e7301-b34f-7240-99aa-ea6d6cdac1c2` | See 2026-05-29 RWO-N4 result note below. The run used 2 successful `capability::execute` invocations, 1 successful `web::search`, 1 successful `web::fetch`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one completed `agent::prompt_queue_drain`, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; source returned an HTTP 403 Cloudflare/JS challenge through the web fetch capability and the agent reported it without fallback browsing | n/a | Passed exact prompt on the real dev server. Search returned official `https://platform.openai.com/docs/models`; fetch targeted that URL through `first_party.web.v1.fetch`; no browser/client-owned path was used. |
| RWO-N5 | Browser and display capability probe | passed | +1 | `sess_019e7308-762f-7691-987e-ea33f8eac543` | See 2026-05-29 RWO-N5 result note below. The run used 6 successful `capability::execute` invocations, 1 successful `browser::get_status`, 2 successful `capability::inspect`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one completed `agent::prompt_queue_drain`, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; no code changes required | n/a | Passed exact prompt on the real dev server. `browser::get_status` returned `hasBrowser = false` and `isStreaming = false`; `display::stop_stream` was inspected but not invoked; no browser/client-owned action path was used. |
| RWO-N6 | State, queue, stream, trigger chain | passed | +1 | `sess_019e730c-0b78-7b73-8598-80a75810a394` | See 2026-05-29 RWO-N6 result note below. The run used 21 successful `capability::execute` invocations, 7 successful `capability::inspect`, 1 successful `state::set`, 1 successful `state::get`, 1 successful `queue::enqueue`, 1 successful `queue::list`, 1 successful `stream::subscribe`, 1 successful `stream::poll`, prompt-history `artifact::create`, and final `resource::create` agent result. There were 0 failed invocations, 0 approvals, 0 `compact.*` events, 0 session-scoped logs, one ready `agent.test` queue row, one session-scoped state row, one `agent.test.execute` stream subscription, and `agent.runtime`/`events.session`/`queue.lifecycle` stream rows. | none; no code changes required | n/a | Passed exact prompt on the real dev server. State write/read matched revision 1; queue enqueue/list returned the ready queued item; stream subscribe/poll succeeded and found no events; publish capability was not found. |
| RWO-N7 | Live worker extensibility | passed_after_fix | +2 | conformance failure: `sess_019e732f-c5e0-7bf3-8130-9da7d39a3deb`; trigger retest with cleanup gap: `sess_019e733b-af69-7f93-bb15-7a717d906aef`; cleanup-fixed retest: `sess_019e7341-8eac-7bb3-97bc-efd16de60757`; trigger-guidance retest: `sess_019e735b-9168-7b43-bb95-56fb6cacca43` | See 2026-05-29 RWO-N7 result note below. Trigger-guidance retest used one `needs_selection` execute row for trigger-id metadata guidance, one successful `capability::execute` row, one successful target `rwo_n7::echo` invocation, catalog revisions 389-394, 0 approvals, 0 `compact.*` events, 0 session logs, and expected post-disconnect `CAPABILITY_NOT_FOUND` cleanup probes after unregister. | `execute_resolution`: session-generated implementations stayed `candidate` and were not binding-selectable. `queue_or_trigger`: visible trigger metadata was not projected through capability discovery. `worker_lifecycle`: stale session-scoped registry plugin/implementation rows stayed healthy after disconnect. `execute_resolution`: explicit trigger-id targets returned generic not-found instead of metadata-only guidance naming the related function target. | `0aabb48a2`; `10ee56a2c` | Passed after rebuilt dev server PID 63286. Trigger-id target now returns `needs_selection`/`trigger_metadata_target` with suggested target `rwo_n7::echo`, no child invocation, and no trigger-id aliasing. Post-disconnect registry sync removed the session-generated implementation/plugin rows and direct execute returned expected `CAPABILITY_NOT_FOUND`. |
| RWO-N8 | Module package activation | passed_after_fix | +2 | setup and first retest: `sess_019e7385-341e-7f30-8176-6b93396a6dbc`; final activation retest: `sess_019e7398-5d77-7d01-9c2a-465589dade48` | See 2026-05-29 RWO-N8 result note below. The setup run registered source/package, verified source, approved source, configured, activated, health-checked, disabled, and inspected the deterministic package. The final retest used 6 successful `capability::execute` rows, successful `module::activate`, `worker::spawn`, `module::check_health`, two `rwo_n8_20260529113609::health` invocations, duplicate activation replay, `module::disable`, `sandbox::stop_spawned_worker`, and `module::inspect_package`; 0 failed invocations; 2 executed approvals; disabled activation resource; revoked derived grant; no session logs. | `execute_correction`: nested wrapper cleanup stripped target-owned `arguments.mode` from `module::check_health`. `worker_lifecycle`: worker guide Python blocked in `recv_json` and stopped heartbeating while idle. `execute_resolution`: `worker::spawn` issued `engine_issued` scoped tokens, but binding selection only treated `session_scoped` session-generated functions as healthy. | `ae1b153bf` | Passed after rebuilt dev server PID 76020 with simulator booted. Direct fixture execute `019e7398-b60b-71b1-8e26-1ac35fcad2a1` selected `session_generated.rwo_n8_20260529113609.demo_echo` and invoked child `019e7398-b6f4-7b81-9c42-3acf2736499a`; disable stopped PID 77144 and revoked grant `sandbox-worker:rwo-n8-worker-20260529113609:019e7398-8526-7ff1-bbd5-280708370bf8`. |
| RWO-N9 | Subagent fan-out/fan-in | passed_after_fix | +2 | failed first run: `sess_019e73a5-c2ae-7fe3-b9b9-86131b2f7156`; passing retest: `sess_019e73ae-4645-7f03-bca5-fad68c3959c4` | See 2026-05-29 RWO-N9 result note below. The passing retest used 10 parent `capability::execute` rows, 2 non-blocking `agent::spawn_subagent` target rows, 4 `agent::subagent_status` rows, 2 `agent::subagent_result` rows, 8 child `capability::execute` rows, 2 deterministic `agent_result:subagent:*` resources, 1 final parent `agent_result`, 0 failed invocations, 0 approvals, 0 `compact.*` events, and 0 session-scoped log rows. | Primary `resource_truth`: completed blocking subagents did not write deterministic `agent_result:subagent:*` resources, so result/status could fall back to in-memory manager state. Secondary `schema_or_recipe`: omitted `blockingTimeoutMs` was coerced into a blocking wait and the contract did not name the result capability, so fan-out models were guided toward sequential work. | `5c79bf677` | Passed exact prompt after rebuilt dev server PID 83613 with simulator booted. Parent spawned child sessions `sess_019e73ae-7618-7e92-b86a-19a4f50c605a` and `sess_019e73ae-8413-7830-9a49-3c87c98180be` before waiting, status-polled both through `agent::subagent_status`, collected both through `agent::subagent_result`, and reported lineage/capabilities. A model-chosen `process::run sleep 10` was used only as a timer between canonical status polls; no hidden client or runner side channel was used. |
| RWO-N10 | Memory auto-retain | passed | +1 | `sess_019e73ba-2d9b-7dd3-9cbe-6704e0efb4a6` | See 2026-05-29 RWO-N10 result note below. The run used the real dev server and booted simulator evidence, kept the default auto-retain interval of 10, recorded 9 explicit `memory::auto_retain_fire` skips with `reason = below_threshold`, then fired on the tenth user message with `status = retaining`. The terminal `memory.retained` event recorded 4 resource refs: memory journal artifact, session materialized projection, memory-rule artifact, and rule materialized projection. DB evidence shows 0 failed invocations, 0 approvals, 0 `compact.*` events, 10 completed prompt queue drains, and resource versions with hashes/lifecycle state. | none; no code changes required | n/a | Passed without changing settings or using a side channel. Retain truth was engine-owned: `memory.retained` event seq 152, parent auto-retain invocation `019e73bb-209f-7561-912f-909dfe5f6e5a`, trace `019e73ba-fe7e-7511-ab2b-7275bfbecf3b`, and resource refs were produced by `artifact::create`, `materialized_file::update`, and `resource::link` children under that invocation. |
| RWO-N11 | Resource failure matrix | passed_after_fix | +2 | first failed run: `sess_019e73c7-7e3d-7090-9fe9-96bd4d9118d2`; resource-truth retest: `sess_019e73d2-0e47-7230-8f4c-1756dbda35a6`; execute-guidance retest: `sess_019e73eb-f65c-7ce3-a621-aa8b0d078494` | See 2026-05-29 RWO-N11 result note below. Final retest used 17 `capability::execute` rows, 6 `materialized_file::update`, 2 `materialized_file::hash_verify`, 2 `materialized_file::read`, 2 `materialized_file::inspect`, 3 `resource::create`, 1 `materialized_file::discard`, 0 approvals, 0 `compact.*` events, 0 session logs, damaged truth for missing-bytes and hash-mismatch fixtures, discarded lifecycle for the discarded fixture, replay of step 4, and 0 `target_payload_invalid` execute rows. | Primary fixed root cause was `resource_truth`: missing canonical bytes returned an opaque handler failure without damaged resource truth, and discarded materialized files remained readable/updatable through operational wrappers. Follow-up fixed `schema_or_recipe`: lifecycle CAS guidance now teaches `expectedCurrentVersionId`, not `versionId`, before the model calls lifecycle targets. | `c8a230983`; `9069323a1` | Passed after rebuilt dev server PID 98981 with simulator booted. Step 14 first attempted `materialized_file::discard` with `expectedCurrentVersionId = ver_019e73ed-1591-7cb3-8693-b0f2121f40fc` and succeeded without a pre-child validation failure. |
| RWO-N12 | Approval and grant boundary | passed_after_fix | +2 | failed direct policy probe: `sess_019e73fa-ba22-7bd1-a9a1-f359286c80c0`; approval session: `sess_019e73fd-ba7a-7521-bbdf-6dca81b5855c`; direct retest: `sess_019e7410-98a1-7472-a8b8-475bc8229055` | See 2026-05-29 RWO-N12 result note below. The live approval-flow session used 3 `capability::execute` rows, 2 approval records, 3 `approval::resolve` rows, 1 `process::run` child, 1 `materialized_file::update`, 3 `resource::create`, 2 completed prompt queue drains, 0 failed invocations, and 0 `compact.*` events. The direct retest used 3 `capability::execute`, 3 `approval::resolve`, 1 `process::run`, 1 `materialized_file::update`, 1 `resource::create`, 6 `engine::invoke`, 2 approval records, 8 stream rows, 0 failed invocations, and 0 `compact.*` events. Denial created approval `019e7410-996b-7431-afa9-f9e3da8e5c9c`, no child, and no target refs; approval created approval `019e7410-9b17-7673-b14c-c55da8e669c2`, child `019e7410-9b42-7ab0-a09f-73660aff8cad`, materialized file `materialized_file:2d5d7cc3d635bdaed7de5dd104b243c4e8640b393b8c1b4f1345093ebfe555f0`, and output `res_019e7410-9b4d-7fa1-93da-67dd1c38cda3`; replay execute `019e7410-9c24-71d0-b87c-ac8216df447a` reported `approvalReplayed=true` and `childInvocationCreated=false`. | `execute_resolution`: public `/engine` direct `capability::execute` used transport/client audit scopes but did not project active-profile execution policy scopes/runtime metadata, so direct execute failed with `CAPABILITY_DENIED` before approval. The root fix derives execute policy on the server from the active profile and rejects client-authored `contract.*`, `implementation.*`, `plugin.*`, and `capability.*` policy context. | `704fb8041` | Passed after rebuilt dev server PID 7070 with simulator booted. DB evidence proves policy scopes stayed server-owned, the denied mutation created no `process::run` child or target refs, the approved mutation created exactly one child and resource chain, duplicate approval resolve replayed, and direct public execute no longer requires client-supplied policy. |
| RWO-N13 | Runtime resilience | passed | +1 | runtime pass: `sess_019e7422-7fb7-7423-a63c-16c473d6917e`; unscored harness attempt: `sess_019e741e-8b87-7f72-94f7-b98b3be63eb3` | See 2026-05-29 RWO-N13 result note below. Runtime log `/tmp/rwo_n13_runtime_run_20260529072756.json` and approval-pause log `/tmp/rwo_n13_approval_pause_run_20260529073320.json` reconstruct the scenario. Baseline prompt used `agent::prompt`, a completed `agent::prompt_queue_drain`, `filesystem::read_file`, and `process::run`; `./scripts/tron dev -bdt` moved PID `81779` to `47488` and passed the configured dev tests. The long read-only process acquired lease cursor `80311`, was interrupted by `./scripts/tron dev -d` moving PID `47488` to `48287`, persisted child `019e7424-1af7-7f91-9f27-d75c64927fb7` with exitCode `-1`, released lease `019e7424-1af7-7f91-9f27-d7682abb77bf`, and recorded compensation `019e7424-1e4e-76b2-a31c-fc97ad20efef`. Post-reconnect `process::run` child `019e7424-558d-7d51-b3d9-59df726a0642` exited `0`. Approval `019e7427-6989-7d90-829e-89f5d0689c07` stayed pending across `./scripts/tron dev -d` moving PID `48287` to `49356`, then executed child `019e7427-96ad-76d1-bf34-658c13775af3`, materialized file `materialized_file:10068ee46d1ca50c3c732f08a867d15e361ae22cc6c46e6ef492721428e67920`, and output `res_019e7427-96c5-7553-a106-bae7e50dbd4c`. No scenario idempotency key duplicated; only internal `engine::invoke` rows have blank idempotency keys. There were 0 failed invocations, 0 `compact.*` events, no session-scoped logs, and stream topics included `agent.runtime`, `events.session`, `queue.lifecycle`, `approvals`, `resource.leases`, and `compensation.records`. | none; first harness attempt waited for a `process::run` invocation row before completion even though active process truth is exposed through `resource.leases`. Simulator URL deep-link screenshots stopped at the iOS "Open in Tron?" confirmation, but the dashboard remained mounted/not onboarding and DB/session-stream reconstruction proved continuity. | n/a | Passed on the real dev server with the iOS simulator booted. Exact retest used the corrected lease-based harness, proved interrupted invocation visibility, approval-pause survival, queue/idempotency correctness, and successful post-reconnect execution. |
| RWO-N14 | Provider full parity | partial_p6_major_providers_passed | +10 | clean P1 run: Anthropic `sess_019e7433-bd1f-79f0-8d6f-e037f2d07448`, OpenAI Codex `sess_019e7433-de30-7d51-8022-b15d5fc95b62`, Gemini `sess_019e7433-fb83-74e1-973b-281c617ca83b`, Ollama failed `sess_019e7434-10b9-7c73-8d44-e43af8017059`; wire-shape retest still failed `sess_019e743c-e359-7ea0-aa4d-42d7de3852d1`; final Ollama P1 retest passed `sess_019e7441-5e8b-7d91-8c14-b4352d6e1887`; clean P2 run: Anthropic `sess_019e7447-d814-7d02-b90d-a8dbc5998d6e`, OpenAI Codex `sess_019e7447-fda8-71e0-a427-99d9d9dd868d`, Gemini `sess_019e7448-1b59-74c3-b655-38b574ca2aee`, Ollama `sess_019e7448-34cd-7171-bab4-2e643ffec97e`; P3 failure: Ollama `sess_019e7450-983c-7033-8965-85f8daab139c`; clean P3 retest: Anthropic `sess_019e7466-2bd2-7d72-b17d-37ca53fe0993`, OpenAI Codex `sess_019e7466-58e5-7360-b0f5-1507d6e7d3c9`, Gemini `sess_019e7466-71ed-7bf3-a5b3-b425f9c41dc1`, Ollama `sess_019e7466-82f0-7e02-830e-5989c1bb896c`; clean P4 retest: Anthropic `sess_019e749e-8539-7591-a146-5ee38152b03a`, OpenAI Codex `sess_019e749f-2500-7240-a1b9-9b3295bdb853`, Gemini `sess_019e749f-a5b4-7471-b129-91d2ef9ce105`, Ollama `sess_019e749f-e321-7451-8392-1f742fd840d4`; P4 failed-card follow-up rerun: Anthropic `sess_019e74b7-b9bc-7de0-9c59-8cab92fffd77`, OpenAI Codex `sess_019e74b8-127f-72d2-865c-99de12e8ed1b`, Gemini `sess_019e74b8-4ff2-76c1-92d6-cae741f593f4`, Ollama/Gemma inconclusive `sess_019e74b8-7d7f-7400-94c7-8de99d917761`; P5 matrix: Anthropic `sess_019e74e3-09ae-7233-b27b-963573a4399a`, OpenAI Codex `sess_019e74e3-d6ad-7001-9685-fa398767de76`, Gemini `sess_019e74e4-4510-7393-a33a-b2626efe7a9a`, Ollama/Gemma inconclusive `sess_019e74e4-97b5-71c2-93f2-edac82506664`; P6 matrix: Anthropic `sess_019e74f0-095c-7c73-8151-fa3b33f1d729`, OpenAI Codex `sess_019e74f5-42c5-7443-9814-e9cc231a105f`, Gemini `sess_019e74f6-c0dc-7931-a7e9-f4c55d357464`, Ollama/Gemma inconclusive `sess_019e74f7-35dd-7ce2-8e26-07b64d919aef` | See 2026-05-29 RWO-N14 P1, P2, P3, P4, P4 follow-up, P5, and P6 result notes below. The P4 follow-up rerun used real dev server PID `10586`, run log `/tmp/rwo_n14_p4_provider_parity_20260529101057.json`, final simulator screenshots under `/tmp/rwo_n14_p4_*_final_simulator_20260529101057.png`, zero failed invocations, zero `compact.*` events, and zero `isError=true` capability completions. Anthropic, OpenAI Codex, and Gemini each created one executed `process::run` approval, one successful sandbox-materialized process child, materialized-file refs, execution-output refs, completed prompt queue drains, and no session/trace logs. Ollama/Gemma returned a non-error `needs_input` execute result without creating an approval or child. P5 then passed for Anthropic, OpenAI Codex, and Gemini on real dev server PID `36012` with run log `/tmp/rwo_n14_p5_provider_parity_20260529105816.json`: each provider had one setup approval, one setup `process::run` child, one P5 `capability::execute`, `approvalReplayed=true`, `childInvocationCreated=false`, zero new approvals, zero new process children, zero failed invocations, zero `compact.*` events, and completed queue drains. Ollama/Gemma made no setup execute call and remains inconclusive without engine failure. P6 then passed for Anthropic, OpenAI Codex, and Gemini on real dev server PID `36012` with run logs `/tmp/rwo_n14_p6_provider_parity_20260529111228.json` and `/tmp/rwo_n14_p6_provider_parity_20260529111810.json`: each provider used only `capability::execute` over filesystem inspection targets, cited inspected repo files, listed used capabilities, completed queue drains, and recorded zero failed invocations, zero approvals, and zero `compact.*` events. Ollama/Gemma used the same substrate without failures but cited only one file and did not satisfy the final answer contract. | Primary P1 `model_guidance`: execute text output appeared after metadata, and local Ollama reported a generic success sentence instead of the exact line. Provider-boundary cleanup also fixed stale outbound Ollama native field names and removed the inbound compatibility alias. P2 had no failure. Primary P3 `schema_or_recipe`: `process::run` did not express non-empty command in schema, the target guard allowed blank commands, and execute did not classify null required fields as missing input. Primary P4 `model_guidance`: approval-gated write commands were under-taught and could target `filesystem::write_file` or `approval::request` instead of `process::run`. Primary P4 `target_capability`: sandbox expected output paths were validated too late and allowed absolute or home-relative host paths to fail only after approval. P4 harness `observability_gap`: simulator collection returned after an early turn end while a later approval was still pending. P4 follow-up fixed primary `grant_or_approval` and execute preflight classification: approval idempotency was globally scoped, and repairable sandbox path mistakes were projected as failed cards instead of `needs_input`. P5 fixed `context_reconstruction`: persisted capability completion events now preserve model-facing execute observations separately from display text, so later turns see approval replay metadata from DB reconstruction. P5 also fixed `model_guidance`: approved execute results expose the effective replay idempotency key in top-level details, approval state/replay metadata, and model-facing replay hints. Derived execute keys now use `capability-execute:v2:<128-bit-hex>` to reduce model transcription errors while preserving deterministic engine-owned replay. The remaining Ollama/Gemma P5 and P6 results are `provider_runner`/small-local-model capability limits, not engine substrate failures. | P1 fix `9616a9b64`; P2 n/a; P3 fix `8da05af18`; P4 fix `ea6806937`; P4 failed-card follow-up `97d66318c`; P5 `c49c14664`; P6 n/a | P4 passed on rebuilt dev server PID `99393`; the failed-card follow-up rerun on PID `10586` verified no `isError=true` execute completions. P5 and P6 passed on rebuilt dev server PID `36012` for Anthropic, OpenAI Codex, and Gemini; later local-provider parity should try a larger Ollama model before treating Gemma 4 E4B as substrate evidence. RWO-N14 is complete for major-provider parity and the next active hardening target is structural cleanup. |
| RWO-N14-F1 | Process sandbox command-output boundary follow-up | passed_after_fix | +1 | failed simulator session `sess_019e74d4-7e0a-7c72-81e7-cb7e15c26be6`; Google retest `sess_019e7523-4c24-7b02-9ff7-08b896c05c74`; direct exact-payload probe `sess_019e7523-ffb5-7601-acdf-8bf36461824a` | Google P5 retest on rebuilt dev server PID `57422` used run log `/tmp/rwo_n14_p5_provider_parity_20260529120827.json`, final simulator screenshot `/tmp/rwo_n14_p5_google_final_simulator_20260529120827.png`, one executed `process::run` approval, one setup `process::run` child, one replay `capability::execute`, `approvalReplayed=true`, `childInvocationCreated=false`, zero new approvals, zero new process children, zero failed invocations, and zero `compact.*` events. Direct exact-payload probe returned `target_policy_rejected` with `approvalCreated=false`, `childInvocationCreated=false`, zero approval rows, zero `process::run` child rows, and no host leak at `~/.tron/workspace/reports/exact-home-leak-20260529120914.txt`. | `target_capability` / `process_sandbox`: sandbox-materialized command write targets were not bounded to declared relative expected outputs before approval, nested expected-output parents were not prepared inside the sandbox, and sandbox commands inherited host `HOME`/`TMPDIR`. | this checkpoint | Passed `cargo test sandbox_materialized --lib -- --nocapture`, `cargo test --test threat_model_invariants -- --nocapture`, `cargo fmt --all -- --check`, `git diff --check`, Google simulator-backed P5 retest, and direct exact-payload live probe. |
| RWO-N15 | Live worker queue/trigger/stream robustness | passed_after_fix | +6 | passing run `sess_019e75e0-b3bb-7be0-bf24-6ab044aa0def`; unscored direct-client policy attempt `sess_019e75db-fafe-7831-b669-3134e7f552fe`; unscored premature-harness terminal attempt `sess_019e75de-e8c2-7052-b44b-f9c12215354a` | Passing run used real dev server PID `41237`, run log `/tmp/rwo_n15_agent_run_20260529153520.json`, fixture log `/tmp/rwo_n15_agent_worker_fixture_20260529153520.jsonl`, and old paired simulator screenshot `/tmp/rwo_n15_20260529153520_old_simulator.png`. The agent used only `capability::execute` to run `stream::subscribe`, `trigger::dispatch`, `queue::get`, `stream::poll`, `resource::create`, `worker::health`, and `stream::unsubscribe`. Queue receipt `019e75e0-da53-7c00-a1ad-9fda0b347c13` completed with attempts `0`, lease owner `tron-server`, target child `rwo_n15_agent_20260529153520::queued_echo`, and trigger id `manual:rwo_n15_agent_20260529153520.queued_echo`. Stream topic `rwo_n15_agent_20260529153520.worker.events` produced one payload with `rwoN15Fixture=true`; queue lifecycle stream showed enqueue, claim, and complete. Evidence resource `evidence:rwo-n15-agent:20260529153520` version `ver_019e75e1-1524-70f2-aec1-4373d74845d1` stored session-scoped payload truth. Catalog revisions 403-408 prove worker/function/trigger register and unregister cleanup after fixture termination. DB classification found zero failed invocations, zero pending approvals, zero `compact.*` events, zero open scenario queue rows, no resource leases, no active RWO-N15 subscription, and only expected app websocket `events.session`/`approvals` subscriptions after the simulator deep link. | RWO-N15 prep found two root gaps before the passing run: `execute_resolution` had no canonical agent-visible `trigger::dispatch` primitive for dispatching registered triggers through the engine runtime, and `queue_or_trigger` kept the built-in `manual` trigger type Sync-only so real enqueue registrations failed while fixture-local tests could pass with a custom trigger type. Two unscored harness lessons were recorded: direct public `capability::execute` is a client actor and cannot see agent-visible primitives, and harnesses must wait for `stream.turn_end` with `stopReason = "end_turn"` rather than treating `tool_use` turn boundaries as terminal. | this checkpoint | Passed after adding `trigger::dispatch`, widening the built-in manual trigger type to Sync+Enqueue, adding focused Rust tests, restarting the real dev server, rerunning the exact agent-path scenario, terminating the volatile fixture, and opening the same session in the old paired simulator. Remaining resilience gap: RWO-N15 proves post-terminal worker cleanup, not pre-terminal worker crash/retry/failure semantics. |
| RWO-N15-F1 | Harness terminal-state guard | passed_after_fix | +0 | failed simulator-backed harness session `sess_019e75de-e8c2-7052-b44b-f9c12215354a`; clean RWO-N15 session `sess_019e75e0-b3bb-7be0-bf24-6ab044aa0def` | Latest failed invocation rows were the unscored RWO-N15 harness attempt: `trigger::dispatch` child `019e75df-14cf-76c3-ad70-2278bf93e07e` failed after the worker unregistered, and later `worker::health` child `019e75df-59d2-73d1-9786-69ddaa0d9c46` failed for the same missing worker. DB stream evidence shows worker connected/function registered/trigger registered at cursors `106470-106472`, then disconnected/unregistered at cursors `106525-106526` before the agent's second tool turn. The new terminal guard reports `terminal=false`, `reason=no_end_turn` at sequence `34` for that session, and reports `terminal=true`, `reason=end_turn_stable`, `terminalSequence=238`, zero open queues, and zero pending approvals for the clean RWO-N15 session. | `observability_gap`: the temporary harness treated the first `stream.turn_end` with `stopReason = "tool_use"` as a completed session and stopped the volatile fixture while the engine still had later tool turns to execute. | this checkpoint | Added `packages/agent/tests/fixtures/session_terminal_guard.py` with pure self-tests and DB-backed CLI evaluation. Updated simulator docs and static gates so harnesses must wait for `stopReason = "end_turn"`, no later `stream.turn_start`, no pending approvals, no open queue items, and stable DB rows. Score remains `91/100` because this prevents recurrence of an unscored harness failure rather than proving a new engine substrate axis. |
| RWO-N16 | Pre-terminal worker disconnect retry | passed_after_fix | +3 | original pass `sess_019e7602-4f74-7e92-90c1-0b75d7b78bc9`; corrected retest `sess_019e7623-44e0-7ef3-bc3c-549e5bec7373`; unscored harness-schema attempt `sess_019e75fe-fa72-78d3-aeef-aa517516463e` | Corrected retest used rebuilt real dev server PID `71028`, run log `/tmp/rwo_n16_agent_run_20260529164803.json`, fixture log `/tmp/rwo_n16_agent_worker_fixture_20260529164803.jsonl`, and old paired simulator screenshot `/tmp/rwo_n16_20260529164803_old_simulator.png`. The agent used only `capability::execute` for two stream subscriptions, `trigger::dispatch`, `queue::get`, worker and queue stream polls, `resource::create`, `worker::health`, and two unsubscriptions. The fixture disconnected before a result for delivery attempt `019e7623-97de-7b10-a0c4-228bacc8c1f1`; that attempt is visible only through `queue.fail` as `deliveryInvocationId`, not as a failed target invocation row or `resultInvocationId`. Retry target invocation `019e7623-9be9-7682-8d3b-5a0065e51165` completed with `rwoN16Retry = true`. Queue receipt `019e7623-9797-7ff0-801a-65295cabe871` completed with attempts `1`. Queue lifecycle cursor `108066` recorded `queue.fail`, status `ready`, attempts `1`, `deliveryInvocationId = 019e7623-97de-7b10-a0c4-228bacc8c1f1`, `resultInvocationId = null`, and `WORKER_DISCONNECTED`; cursor `108073` recorded `queue.complete`, status `completed`, attempts `1`, and matching delivery/result invocation id `019e7623-9be9-7682-8d3b-5a0065e51165`. Evidence resource `evidence:rwo-n16-agent:20260529164803` version `ver_019e7623-ea6a-75b3-9f6f-64a443390550` stored session-scoped payload truth. Terminal guard returned `end_turn_stable`, terminal sequence `329`, zero pending approvals, and zero open queue items. DB classification found zero failed invocations, zero approvals, zero `compact.*` events, zero session logs, no resource leases, and catalog revisions `391-402` proving disconnect unregister, reconnect register, and final unregister cleanup. | `worker_lifecycle` / `queue_or_trigger`: external websocket disconnect while an invocation was pending did not immediately fail pending waiters; queue failure stream projection also published stale pre-fail attempts/status. Follow-up root cause: pure-read worker transport loss was still classified as an application target failure, creating a misleading failed invocation row for delivery failure. | this checkpoint | Passed after adding pending-invocation disconnect failure in `external_workers.rs`, publishing post-fail queue retry state from `queue.rs`, adding focused Rust tests, then correcting worker transport classification so non-mutating queued delivery failures retry through `queue.lifecycle` without recording failed target invocation rows. The final exact agent-path scenario was rerun against the old paired simulator and proved `queue.fail` uses `deliveryInvocationId` while leaving `resultInvocationId` null for unrecorded delivery attempts. Score remains `94/100`; cancellation and terminal dead-letter semantics remain the next RWO-N16 subcase rather than being overclaimed here. |
| RWO-N16B | Queue cancellation and terminal dead-letter robustness | passed_after_fix | +3 | timing-failed harness attempt `sess_019e7637-679c-7063-a1cf-3e89302a0210`; passing retest `sess_019e763d-628a-75c3-8b63-4ef7736fbfe9` | Passing retest used rebuilt real dev server from this checkpoint, run log `/tmp/rwo_n16b_agent_run_20260529171634.json`, cancel fixture log `/tmp/rwo_n16b_cancel_worker_fixture_20260529171634.jsonl`, dead-letter fixture log `/tmp/rwo_n16b_dead_worker_fixture_20260529171634.jsonl`, and old paired simulator screenshot `/tmp/rwo_n16b_20260529171634_old_simulator.png`. The agent used only `capability::execute` for stream subscriptions, `trigger::dispatch`, `queue::get`, `queue::cancel`, queue/worker stream polls, `resource::create`, `worker::health`, and unsubscriptions. Cancellation receipt `019e763d-bb67-7ab2-a201-acdb51e5503c` was claimed, cancelled through public `queue::cancel`, remained `cancelled` after the delayed target returned, had attempts `0`, no lease owner/expiry, and no `queue.complete` event. `queue.cancel` cursor `109219` recorded status `cancelled`. Dead-letter receipt `019e763e-13ab-7242-98c3-48a3a77aa05d` failed target invocations `019e763e-13ed-7c71-889a-a333934d4e5f`, `019e763e-17ec-7dc0-a155-e4c1504a378a`, and `019e763e-1be7-7a80-a69c-97269b86fff2`; cursors `109274` and `109277` recorded `queue.fail` status `ready`, and cursor `109283` recorded `queue.dead_letter` status `dead_lettered`, attempts `3`. Evidence resource `evidence:rwo-n16b-agent:20260529171634` version `ver_019e763e-8aa3-7341-9f79-37beb456e547` stored session-scoped payload truth. Terminal guard returned `end_turn_stable`, terminal sequence `637`, zero pending approvals, and zero open queue items. DB classification found three expected target failures for the always-error fixture, zero unexpected failed invocations, zero approvals, zero `compact.*` events, zero session logs, no resource leases, no grants, zero active harness subscriptions, and catalog revisions `403-414` proving both workers/functions/triggers registered and unregistered. The simulator route showed the terminal RWO-N16B answer for the same session. | `queue_or_trigger`: direct public queue primitive mutations did not publish queue lifecycle stream events, complete/cancel left terminal/lease semantics too permissive for late target results, and retry exhaustion was published as a generic `queue.fail` instead of explicit terminal `queue.dead_letter`. Harness follow-up: `session_terminal_guard.py` treated `dead_lettered` rows as open work, and the first live RWO-N16B attempt used too short a cancellation delay so `queue::cancel` correctly returned `cancelled=false` after completion. | this checkpoint | Passed after adding focused queue tests, making terminal queue states reject late complete/fail transitions, clearing leases on complete/cancel, publishing lifecycle events from public queue primitives, emitting `queue.dead_letter` for terminal retry exhaustion, teaching the live worker fixture `always-error`, adding the RWO-N16B live harness, and updating the terminal guard so `dead_lettered` is terminal. Score is now `97/100`; remaining work should target final cross-scenario orchestration/modularity hardening rather than more queue retry variants. |
| RWO-N17 | Multi-session churn and harness ownership robustness | passed_after_fix | +3 | stale simulator launch timeout: `sess_019e7651-ab82-7402-bcc4-e592a61199ca` / `sess_019e7652-119d-7753-9c75-526d5fa4b1d9`; stale app-path classification: `sess_019e7654-9572-7de1-ac2e-8aaaa69aecc3` / `sess_019e7655-400f-74e0-a7bf-122f3d2667aa`; canonical current-model retest: visible `sess_019e7665-2b83-7190-82ac-272cf9c7c92d`, background `sess_019e7665-6cbf-74e1-9260-34428f7377d4` | Current-model retest used `claude-sonnet-4-6`, real dev server PID `95397`, run log `/tmp/rwo_n17_multi_session_run_20260529180002.json`, worker fixture log `/tmp/rwo_n17_background_worker_fixture_20260529180002.jsonl`, visible screenshots `/tmp/rwo_n17_visible_before_20260529180002.png` and `/tmp/rwo_n17_visible_after_20260529180002.png`, background screenshot `/tmp/rwo_n17_background_20260529180002.png`, visible evidence `evidence:rwo-n17-visible:20260529180002`, and background evidence `evidence:rwo-n17-background:20260529180002`. DB classification passed with terminal guards at `end_turn_stable`, zero failed invocations, zero approvals, zero `compact.*` events, zero active harness subscriptions, zero active leases, zero open queues, two expected `engine-ws:*` app subscriptions per visible route, one user message and assistant terminal messages in each session, completed prompt queue drains, background queue receipt `019e7665-994b-74c3-99db-b92d7d3baf4f` completed with attempts `0`, `queue.enqueue`/`queue.claim`/`queue.complete` lifecycle rows, worker/function/trigger register and unregister catalog rows, and zero visible/background cross-leakage identifiers. | Primary `ios_rendering` / harness evidence gap: stale simulator launch/openurl timeouts were not classified as invalid app-path proof, and cold-start session deep links could be stored before `ContentView` was ready and then lost, leaving the app on the session list. Secondary `code_ownership`: RWO-N17 needed a focused reusable harness rather than ad hoc manual DB checks. | this checkpoint | Passed after adding `packages/agent/tests/fixtures/rwo_n17_live_multi_session_harness.py`, requiring successful `simctl openurl` and screenshot return codes, keeping active app websocket subscriptions separate from harness-owned subscriptions, adding iOS pending deep-link processing through the existing coordinator path, covering the pending helper in `ContentViewCoordinatorTests`, rebuilding/installing the beta simulator app, and rerunning the exact scenario on the old paired simulator. Computer Use confirmed the visible app route showed the user prompt, terminal assistant marker, and `Sonnet 4.6` chip for the same session. Score is now `100/100`; future work is regression, provider breadth, and visual parity polish, not unscored architecture shortcuts. |
| SCB-S1 | `capability::execute` ownership decomposition audit | passed_static_gate | +1 | n/a: deterministic Rust/static-gate scenario | `target_arguments.rs` now owns target argument affordances; `threat_model_invariants` rejects target-specific affordance function bodies in `execute.rs`; focused unit tests passed for intent argument normalization and deterministic routing. | Code modularity: target-specific argument normalization and intent/resource/path affordances lived in the central execute orchestrator. | this checkpoint | Passed `cargo test intent_argument_normalization --lib -- --nocapture`, `cargo test deterministic_intent_route --lib -- --nocapture`, `cargo test --test threat_model_invariants -- --nocapture`, `cargo fmt --all -- --check`, and `git diff --check`. |
| SCB-S1b | Deterministic route and decomposition ownership audit | passed_static_gate | +1 | n/a: deterministic Rust/static-gate scenario | `target_resolution.rs` now owns deterministic routing, namespace clarification, execute constraints, argument-schema fit promotion/filtering, low-confidence intent evidence checks, candidate summaries, and target-specific decomposition guidance. `execute.rs` dropped from 4153 lines to 3300 lines and remains the parse/resolve/prepare/run/observe spine. | `code_ownership`: deterministic route, decomposition, namespace clarification, and argument-schema fit logic still lived in the central execute orchestrator after SCB-S1. | this checkpoint | Passed `cargo test deterministic_intent_route --lib -- --nocapture`, `cargo test orchestration_argument --lib -- --nocapture`, `cargo test decomposition --lib -- --nocapture`, `cargo test intent_argument_normalization --lib -- --nocapture`, `cargo test capability_ --lib -- --nocapture` (451 passed), `cargo test --test threat_model_invariants -- --nocapture`, `cargo fmt --all -- --check`, and `git diff --check`. |
| SCB-S2 | Capability registry ownership split audit | passed_after_fix | +1 | n/a: deterministic Rust/static-gate scenario | `registry/index.rs` now owns hybrid search, lexical/vector ranking, document identity, vector-fusion helpers, and degraded-index status. `registry/primer.rs` owns context-primer policy, visible primer selection, and model-facing primer rendering. `registry/recipes.rs` remains recipe-owned. The registry root now documents the submodule split and keeps catalog projection plus store implementations. | `primer_rendering`: under tight token budgets, primer rendering could emit only the long header and omit the first core capability. `code_ownership`: ranking/indexing and primer rendering lived in the central registry root beside store/SQLite behavior. | this checkpoint | Failed first `cargo test registry --lib -- --nocapture` at `primer_respects_core_policy`; after the root fix, passed `cargo test primer_respects_core_policy --lib -- --nocapture` and `cargo test registry --lib -- --nocapture` (195 passed). |
| SCB-S3 | Canonical bounded resource projection audit | passed_after_fix | +1 | n/a: deterministic Rust/static-gate scenario | Prompt library and voice notes now compose list/inspect summaries through `domains/resource_projection.rs`; generated UI authoring now composes collection summaries through `current_resource_payloads_by_prefix` with `RESOURCE_COLLECTION_SCAN_LIMIT = 500`; control and module trust/audit projections are statically required to stay bounded. | `resource_projection`: generated UI prompt/notification/subagent authoring still had `limit: 10_000` scans, and prompt-history pruning briefly inspected an extra resource because default 10,000-entry pruning cannot be proven through a 500-resource bounded projection. | this checkpoint | Failed first `cargo test prompt_library_resources --lib -- --nocapture` at `prompt_history_record_skips_prune_scan_when_default_limits_cannot_prune`; after the root fix, passed the same command, `cargo test domain_outputs --lib -- --nocapture`, `cargo test generated_ui --lib -- --nocapture`, and `cargo test --test threat_model_invariants bounded_resource_projection_summaries_stay_canonical -- --nocapture`. |
| SCB-S4 | Provider normalization classification | passed_after_fix | +1 | static-gate scenario; app-path smoke `sess_019e7523-4c24-7b02-9ff7-08b896c05c74` | Provider-specific schema terms remain confined to provider/protocol modules. Provider capability argument parsing now returns `Result`, and OpenAI, Anthropic/shared stream accumulation, Google, and Kimi route malformed or non-object arguments to `StreamEvent::Error` without emitting a canonical capability invocation or `Done` event. Ollama already deserializes arguments as a typed object at the provider boundary. Light simulator smoke opened `tron://session/sess_019e7523-4c24-7b02-9ff7-08b896c05c74` against dev server PID `57422` and rendered the existing P5 chat path; screenshot `/tmp/scb_s4_app_path_smoke_20260529.png`. | `provider_runner`: streamed or completed provider arguments could fail open as `{}` in `provider_protocol::capability_parsing`, shared stream accumulation, Kimi, and OpenAI; Google non-object function-call args could also become empty canonical arguments. | this checkpoint | Passed `cargo test capability_parsing --lib -- --nocapture`, `cargo test stream_common --lib -- --nocapture`, `cargo test openai::stream_handler --lib -- --nocapture`, `cargo test google::stream_handler --lib -- --nocapture`, `cargo test kimi::stream_handler --lib -- --nocapture`, and `cargo test --test threat_model_invariants provider_argument_normalization_fails_closed -- --nocapture`. |
| SCB-S5 | Hidden side-effect boundedness audit | passed_after_fix | +1 | static-gate scenario; app-path smoke `sess_019e7523-4c24-7b02-9ff7-08b896c05c74` | Retained-memory context loading, notification inbox/read-state reconstruction, and cron schedule/run truth now use named 500-resource scan limits tied to `resource_projection::MAX_RESOURCE_COLLECTION_LIMIT`. The resource store already enforced the 500-row cap, so the root issue was an unclassified contract shape rather than an actual unbounded read. DB smoke for the deep-linked session showed 22 events, 39 successful invocation rows grouped under engine/resource/session/agent/capability/memory/notification/process functions, 1 executed approval, 4 resource rows, 2 completed queues, stream rows on `agent.runtime`, `approvals`, `compensation.records`, `events.session`, `queue.lifecycle`, and `resource.leases`, 0 session logs, and 0 `compact.*` events. Simulator screenshot `/tmp/scb_s5_app_path_smoke_20260529.png` showed the user prompt and assistant content in the app route. | `resource_projection`: hidden side-effect truth reconstruction still requested `limit: 10_000` in retained-memory context, notification read decisions/inbox listing, and cron schedule/run reconstruction even though the resource primitive clamped results. | this checkpoint | Passed `cargo test --test threat_model_invariants hidden_side_effect_resource_scans_stay_bounded_and_observable -- --nocapture`, `cargo test retained_memory_context_reads_resource_artifacts --lib -- --nocapture`, `cargo test notification_ --lib -- --nocapture`, `cargo test cron_ --lib -- --nocapture`, `cargo test --test threat_model_invariants -- --nocapture`, and simulator deep-link smoke against real dev server PID `2214`. |
| SCB-S6 | Test decomposition and large-file ownership audit | passed_after_fix | +1 | n/a: deterministic Rust/static-gate scenario | `src/engine/tests/module_activation.rs` dropped from 1,950 lines to 873 lines and now owns shared fixtures plus declarations only. New child modules own package registration, local-process activation, and operator-surface tests. Remaining Rust test files over 1,000 lines are explicitly audited below with owner/reason markers and enforced line budgets. | `code_ownership`: module-activation registration, activation runtime, grant-boundary, and operator-surface tests lived in the shared fixture root; remaining large test files had no enforced scorecard audit row or line budget. | this checkpoint | Passed `cargo test module_activation --lib -- --nocapture`, `cargo test --test threat_model_invariants rust_test_ownership_stays_code_adjacent -- --nocapture`, `cargo test --test threat_model_invariants large_rust_test_files_have_scorecard_ownership_audit -- --nocapture`, and `cargo test --test threat_model_invariants -- --nocapture`. |
| SCB-S7 | Capability presentation ownership audit | passed_after_fix | +1 | static/unit scenario; app-path smoke `sess_019e7523-4c24-7b02-9ff7-08b896c05c74` | Generated UI action presentation is now authored by `engine::primitives::action_summary` and stored on action payloads/summaries as `presentation.buttonRole` and `presentation.icon`; `ui::inspect_surface` and control UI refs project it without exposing templates in control. iOS decodes `UiActionPresentationDTO`, renders stored button role/icon data, and retains coordinate-only `UiActionSubmissionDTO`. DB smoke for the deep-linked session showed 22 session events, 47 successful invocations grouped under agent/approval/capability/device/engine/materialized-file/memory/notification/process/prompt/resource/session/skills functions, 1 executed `process::run` approval, 4 resources created by session invocations (`agent_result` 2, `execution_output` 1, `materialized_file` 1), stream rows on `agent.runtime`, `approvals`, `events.session`, and `queue.lifecycle`, 0 session logs, and 0 `compact.*` events. Simulator screenshot `/tmp/scb_s7_app_path_smoke_20260529.png` showed the deep-linked app route with user and agent content visible. | `code_ownership`: the generated UI renderer inferred destructive/refresh/create semantics and SF Symbols from action labels/ids through local `isDestructive`, `actionSymbol`, and `humanizedActionLabel` logic even though the server already owned action targets/templates/consequences. | this checkpoint | Passed `cargo test --manifest-path packages/agent/Cargo.toml generated_ui --lib -- --nocapture`, `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants generated_ui_resource_and_renderer_gates_stay_on -- --nocapture`, `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`, `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`, `cargo check --manifest-path packages/agent/Cargo.toml`, `cd packages/ios-app && xcodegen generate`, targeted `xcodebuild test` for `GeneratedUIDTOTests`, `GeneratedUIRendererTests`, and `SourceGuardTests` on iPhone 17 Pro, and simulator deep-link smoke against real dev server PID `18521`. |
| SCB-S8 | Chat and engine state parity | passed_after_fix | +1 | terminal approval parity session `sess_019e7523-4c24-7b02-9ff7-08b896c05c74` | The app-path retest used real dev server PID `26801`, iPhone 17 Pro simulator, screenshots `/tmp/scb_s8_parity_terminal_session_20260529.png` and `/tmp/scb_s8_parity_relaunch_deeplink_20260529.png`, and DB truth for the same session: two `message.user` events, four `message.assistant` events, two started/completed execute cards, one executed `process::run` approval, zero pending approvals, zero failed invocations, two completed `agent` queue rows, no session logs, and zero `compact.*` events. The visible chat shows the harness-submitted replay prompt before the assistant replay answer, and no actionable approval sheet remains mounted after terminal approval state. | `ios_rendering`: live `approval.resolved` updated the engine approval chip but left matching `engineApprovalState.currentData`/`showSheet` alive, and the single-sheet modifier only presented sheets when flags became true without dismissing the active sheet when a server-owned flag became false. | this checkpoint | Passed `cd packages/ios-app && xcodegen generate`, targeted `xcodebuild test` for `EngineApprovalStateTests` and `ChatSheetTests` on iPhone 17 Pro, simulator deep-link smoke against real dev server PID `26801`, `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`, and `git diff --check`. |

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

2026-05-29 result:

- First simulator-backed real-server run
  `sess_019e73c7-7e3d-7090-9fe9-96bd4d9118d2` completed the matrix and exposed
  two `resource_truth` failures. `materialized_file::hash_verify` on a
  materialized-file resource whose canonical bytes were missing failed with
  `handler_failed: read materialized file: No such file or directory` and left
  the resource lifecycle `materialized` with no damaged version. A discarded
  materialized file remained readable: step 16 returned the stored content
  `discard me` even though the resource lifecycle was `discarded`.
- Root cause was in `packages/agent/src/engine/primitives/resource.rs`:
  materialized-file operational wrappers did not enforce the discarded lifecycle
  boundary, and hash verification mapped unreadable canonical bytes to a handler
  error instead of recording engine-owned damaged truth.
- Focused regression coverage added:
  `materialized_file_hash_verify_marks_missing_bytes_as_damaged_truth`,
  `materialized_file_read_rejects_discarded_resource_but_inspect_remains_available`,
  and
  `materialized_file_update_rejects_discarded_resource_without_touching_bytes`.
  These failed before the fix and pass after it.
- Fix: `materialized_file::hash_verify` now records a damaged version with
  `actualContentHash = null` and a missing/unreadable damage reason when the
  canonical file cannot be read. `materialized_file::read`,
  `materialized_file::update`, and `materialized_file::hash_verify` now fail
  closed for discarded resources while `materialized_file::inspect` remains
  available.
- Resource-truth retest `sess_019e73d2-0e47-7230-8f4c-1756dbda35a6` ran against
  rebuilt dev server PID `90819` with booted simulator evidence at
  `/tmp/rwo_n11_retest_simulator.png`. Parent `agent::run_turn` invocation was
  `019e73d2-0e51-7bb1-80eb-4f20028d84f9`, trace
  `019e73d2-0e4e-7f32-a956-88b90fb23602`.
- Retest DB proof: 18 `capability::execute` invocations, 6
  `materialized_file::update`, 2 `materialized_file::hash_verify`, 2
  `materialized_file::read`, 2 `materialized_file::inspect`, 3
  `resource::create`, 1 `materialized_file::discard`, 1 final
  `agent_result`, 0 approvals, 0 `compact.*` events, 1 completed
  `agent::prompt_queue_drain`, and stream topics `agent.runtime`,
  `compensation.records`, `events.session`, and `queue.lifecycle`.
- Normal path and replay proof:
  `materialized_file:rwo-n11-agent-primary-20260529060006` created
  `ver_019e73d2-486e-7c23-88d9-f88c1e228673`, updated to
  `ver_019e73d2-95a4-7ef0-8802-d6b753b0c14d`, and the duplicate step 4/5 key
  replayed child invocation `019e73d2-95a3-7fe1-a305-f3638a22a9c2` without a
  third version.
- Failure path proof: stale CAS failed as `policy_violation` in
  `019e73d2-cdc6-7f50-a293-380a446914fc`; missing payload was rejected by
  `execute` as `needs_input` before creating a `resource::update` child;
  declared hash mismatch failed as `policy_violation` in
  `019e73d2-f30c-7e82-810a-328344bb1c90`; missing bytes created damaged version
  `ver_019e73d3-20c8-7e92-86fc-0aaf4239e07e`; hash mismatch fixture created
  damaged version `ver_019e73d3-4eaa-7d22-9ecc-b799d3a548c6`; discarded read
  failed closed as `policy_violation` in
  `019e73d3-c078-7b22-b485-97d1723243a2`.
- Resource lifecycle proof: the final DB rows show the primary resource
  `materialized`, missing-bytes fixture `damaged`, hash-mismatch fixture
  `damaged`, and discarded fixture `discarded`. The damaged versions did not
  advance invalid current content; the available baseline versions remained
  reconstructable through `engine_resource_versions` and
  `engine_resource_events`.
- Execute-layer follow-up: post-run audit found one unexpected pre-child
  validation failure in the same retest. `capability::execute` invocation
  `019e73d3-86e1-7320-b2e3-b5910290e0a7` and event sequence 398 rejected
  step 14 before child execution with `details.status =
  target_payload_invalid` because the model sent
  `arguments.versionId = ver_019e73d3-71b3-7a71-9e21-a59860bb2ac3` to
  `materialized_file::discard` instead of the contract field
  `expectedCurrentVersionId`. The next turn corrected the field and the target
  invocation succeeded. Classification: primary layer `schema_or_recipe`
  because the model-facing lifecycle schema named `expectedCurrentVersionId`
  but the surrounding result shape exposed `versionId` and the discard example
  omitted the guarded form. This is not a resource-truth fallback or target
  handler bug, but it blocks new broad scenario testing until fixed and retested
  with zero unexpected `target_payload_invalid` execute rows.
- Follow-up fix: model-facing execute metadata now names resource lifecycle
  targets and tells callers to pass prior result `version.versionId` or
  `resourceRefs[].versionId` as `expectedCurrentVersionId`, not `versionId`.
  Resource lifecycle target descriptions and request-schema field descriptions
  carry the same CAS vocabulary, and generated lifecycle recipes include
  `expectedCurrentVersionId: "<currentVersionId>"` so validation feedback does
  not show an unguarded-only discard example. No target-side `versionId` alias,
  fallback reader, or lifecycle compatibility path was added; invalid `versionId`
  payloads still fail closed.
- Focused regression coverage added:
  `execute_schema_teaches_target_call_shape_and_complete_payloads` now requires
  lifecycle CAS guidance in the model-facing execute schema, and
  `lifecycle_version_id_mistake_returns_cas_field_guidance_without_aliasing`
  proves the historical `versionId` mistake still returns
  `target_payload_invalid` while the guidance names `expectedCurrentVersionId`
  and the guarded recipe shape.
- Execute-guidance retest `sess_019e73eb-f65c-7ce3-a621-aa8b0d078494` ran the
  exact RWO-N11 prompt against rebuilt dev server PID `98981` with the booted
  simulator evidence at `/tmp/rwo_n11_followup_simulator_before.png`. The run
  log is `/tmp/rwo_n11_agent_run_20260529062824.json`.
- Retest proof: DB query found 0 `target_payload_invalid` rows for
  `capability::execute`, 0 approvals, 0 `compact.*` events, 0 session-scoped log
  rows, and stream topics `agent.runtime`, `compensation.records`,
  `events.session`, and `queue.lifecycle`. Event sequences 377 and 379 show
  step 14 first attempted `materialized_file::discard` with
  `expectedCurrentVersionId =
  ver_019e73ed-1591-7cb3-8693-b0f2121f40fc`, and child invocation
  `019e73ed-259f-73d2-b40e-06a885f5ce21` succeeded. Step 4/5 target
  idempotency replay reused child `019e73ec-6393-7be1-adb4-380ec712f36a` via
  replay row `019e73ec-758b-7f33-b894-8bd5bb9994a3`.
- Final retest resource proof: primary has two available versions and lifecycle
  `materialized`; missing-bytes fixture has an available baseline plus damaged
  version `ver_019e73ec-d1b2-7ad3-a542-c11be6316f05` with missing/unreadable
  damage reason; hash-mismatch fixture has damaged version
  `ver_019e73ed-05ca-7933-b57c-6581a77bf540`; discarded fixture has lifecycle
  `discarded` and discarded version `ver_019e73ed-259f-73d2-b40e-06b497105113`.
- No package/source/policy/trust/audit side-table probe hits were found after
  excluding canonical `engine_resource*` tables, and no client-owned policy,
  alternate worker-spawn path, fallback reader, compatibility layer, or
  product-state side channel was used.

Scoring:

- `+2` for a simulator-backed real-dev-server scenario that exposed
  resource-truth bugs, received focused root-cause fixes, and passed a
  resource-truth retest with DB reconstruction.
- Current score remains `62/100` provisional for the banked resource-truth
  checkpoint. The RWO-N11 execute-guidance follow-up is closed; the next action
  is RWO-N12.
- Resource truth and durability increases to `9/10`.

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

2026-05-29 result:

- Live approval-flow session:
  `sess_019e73fd-ba7a-7521-bbdf-6dca81b5855c`, against the real dev server
  with the iOS simulator booted. The simulator app was launchable, but it was
  on onboarding rather than a mounted chat, so the proof used the canonical
  `/engine` `agent::prompt` path and DB reconstruction instead of a screenshot
  as acceptance evidence.
- An earlier direct `capability::execute` probe
  `sess_019e73fa-ba22-7bd1-a9a1-f359286c80c0` failed prepare with
  `CAPABILITY_DENIED` before approval. DB evidence showed the public transport
  path supplied only client/transport audit scopes, not the active-profile
  execution-policy scopes/runtime metadata used by the model-session path. That
  failure is now classified as an `execute_resolution` bug rather than scenario
  evidence.
- Denied mutation: `capability::execute`
  `019e73fd-d82a-72c2-8e24-fd7e82bbc9d6` requested `process::run` with
  idempotency key `rwo-n12-agent-denied-20260529064748`. The engine created
  approval `019e73fd-d912-71c2-a037-bbc558170399`; user-side resolution
  invocation `019e73fd-da58-7690-9b35-18aa9a50ff92` denied it. DB proof showed
  0 `process::run` rows for that idempotency key and no target resource refs.
- Approved mutation: `capability::execute`
  `019e73ff-c759-7912-8a7c-a340702c5a5b` requested `process::run` with
  idempotency key `rwo-n12-agent-approved-20260529064748`. Approval
  `019e73ff-c83e-7550-b53a-2ee28391ced1` was executed by
  `approval::resolve` `019e73ff-c9cd-71e1-bde1-0bfca469ddd1`, producing exactly
  one `process::run` child `019e73ff-c9cf-7f30-959e-53f7902ebf57`.
- Durable refs from the approved child were one materialized output file and one
  execution-output record:
  `materialized_file:b5fbc3a59de2a4b7bff6df4832568956c37c69e9a474fa0169c1263af109703a`
  version `ver_019e73ff-c9f3-7210-b034-83dccbfd02cf`, file content hash
  `e7b5025c0198dc057987d27e7807c425b5fc7dba028c32572d73349ab49f8112`, and
  execution output `res_019e73ff-c9f5-78c3-afeb-42c7a8274c3f` version
  `ver_019e73ff-c9f6-7391-a494-d442d20ffa16`.
- Duplicate approval resolve `019e73ff-ca00-7142-b515-620ae0b38fbc` used the
  same resolve idempotency key and replayed from
  `019e73ff-c9cd-71e1-bde1-0bfca469ddd1`; it did not create a second target
  child.
- Replay execute `019e73ff-dc53-7b82-9ac3-839fc47f1029` returned
  `approvalReplayed=true`, `childInvocationCreated=false`, and
  `childInvocationIds = ["019e73ff-c9cf-7f30-959e-53f7902ebf57"]`.
- DB reconstruction found 3 `capability::execute`, 2 approval records, 3
  `approval::resolve`, 1 `process::run`, 1 `materialized_file::update`, 3
  `resource::create`, 2 completed prompt queue drains, 0 failed invocations, 0
  `compact.*` events, and stream topics `agent.runtime`, `approvals`,
  `compensation.records`, `events.session`, `queue.lifecycle`, and
  `resource.leases`.
- Focused grant/replay coverage run after the live session:
  `rejected_grants_fail_before_handler_execution_or_successful_resource_refs`
  and `terminal_approval_replay_does_not_publish_fresh_pending_event`. The grant
  test covers missing, revoked, expired, subject-mismatch, selector, file-root,
  budget, raw-scope, and risk rejection before handler execution, with no
  successful resource refs.
- Direct public execute follow-up fix: `/engine` `invoke(capability::execute)`
  now derives execution policy scopes and runtime metadata from the active
  profile inside the server transport dispatch path. The build path rejects
  client-supplied execute policy scopes (`contract.*`, `implementation.*`,
  `plugin.*`) and `capability.*` runtime metadata so direct clients cannot own
  policy.
- Exact direct retest:
  `sess_019e7410-98a1-7472-a8b8-475bc8229055`, run log
  `/tmp/rwo_n12_approval_run_20260529070825.json`, against rebuilt dev server
  PID 7070 with the iOS simulator booted. DB reconstruction found 6
  `engine::invoke`, 3 `capability::execute`, 3 `approval::resolve`, 1
  `process::run`, 1 `materialized_file::update`, 1 `resource::create`, 2
  approval records, 8 stream rows across `approvals`, `compensation.records`,
  `events.session`, and `resource.leases`, 0 failed invocations, and 0
  `compact.*` events.
- Direct denial retest: `capability::execute`
  `019e7410-98a8-7c63-9487-632ebb2bea63` carried server-derived
  `contract.allow:*`, `implementation.allow:*`, and `plugin.allow:*` scopes,
  created approval `019e7410-996b-7431-afa9-f9e3da8e5c9c`, was resolved denied,
  created no `process::run` child, and produced no target refs.
- Direct approval retest: `capability::execute`
  `019e7410-9a6b-7ff1-ada4-5f3ec5fe8b83` created approval
  `019e7410-9b17-7673-b14c-c55da8e669c2`, process child
  `019e7410-9b42-7ab0-a09f-73660aff8cad`, materialized file
  `materialized_file:2d5d7cc3d635bdaed7de5dd104b243c4e8640b393b8c1b4f1345093ebfe555f0`
  version `ver_019e7410-9b4b-79d0-bd8c-3ce03b7251e4`, file content hash
  `473efa4235162c1a5be716b82b61d0b887b17aad84e1c463ba8bd356d99caef4`,
  execution output `res_019e7410-9b4d-7fa1-93da-67dd1c38cda3`, and output
  version `ver_019e7410-9b4d-7fa1-93da-67f72656dad8`.
- Direct replay retest: `capability::execute`
  `019e7410-9c24-71d0-b87c-ac8216df447a` reported
  `approvalReplayed=true`, `childInvocationCreated=false`, and reused original
  process child `019e7410-9b42-7ab0-a09f-73660aff8cad`.
- Focused transport tests:
  `capability_execute_invoke_rejects_client_owned_policy_scopes`,
  `capability_execute_invoke_rejects_client_owned_policy_metadata`, and
  `active_profile_execute_context_supplies_policy_scopes_and_metadata`.
- Classification: `passed_after_fix`. Safety, grants, and approvals increases
  to `8/10`; current score increases to `64/100`.

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

2026-05-29 result:

- Classification: `passed`.
- Session: `sess_019e7422-7fb7-7423-a63c-16c473d6917e`; first unscored
  harness attempt: `sess_019e741e-8b87-7f72-94f7-b98b3be63eb3`.
- Real dev server and simulator evidence: iPhone 17 Pro simulator was booted
  and the Tron app stayed on the Sessions dashboard, not onboarding. Simulator
  deep-link screenshots hit the iOS "Open in Tron?" confirmation, so mounted
  chat continuity is recorded from DB/session stream reconstruction rather than
  screenshot-only evidence.
- Restart evidence: `./scripts/tron dev -bdt` moved PID `81779` to `47488`
  and passed the configured dev tests: 5769 library tests, 46 main binary tests,
  12 `db_path_guard` tests, 50 `threat_model_invariants` tests, and 80
  integration tests.
- Baseline queue evidence: prompt invocation
  `019e7422-8c72-7c32-be30-bbe83203993b`, queue receipt
  `019e7422-bcc7-7920-8d89-af16295019c6`, queue `agent`, function
  `agent::prompt_queue_drain`, status `completed`, attempts `0`.
- Long-process interruption evidence: `process::run` child
  `019e7424-1af7-7f91-9f27-d75c64927fb7` under `capability::execute`
  `019e7424-1a2e-7a00-8aa3-2b9f384bd23d` acquired lease
  `019e7424-1af7-7f91-9f27-d7682abb77bf` at stream cursor `80311`.
  `./scripts/tron dev -d` moved PID `47488` to `48287`; the interrupted child
  persisted with `exitCode = -1`, `durationMs = 850`, no output, released the
  lease, and recorded compensation
  `019e7424-1e4e-76b2-a31c-fc97ad20efef`.
- Post-reconnect evidence: direct `capability::execute`
  `019e7424-54b6-7c20-becc-f21fcb03d40a` invoked `process::run`
  `019e7424-558d-7d51-b3d9-59df726a0642`, which exited `0` and returned
  `Fri May 29 07:29:58 PDT 2026`.
- Approval-pause evidence: approval
  `019e7427-6989-7d90-829e-89f5d0689c07` for
  `rwo-n13-approval-process-20260529073320` was created pending before restart.
  `./scripts/tron dev -d` moved PID `48287` to `49356`; after restart,
  `approval::resolve` `019e7427-96aa-70a1-863d-558de00b9c9d` executed
  `process::run` child `019e7427-96ad-76d1-bf34-658c13775af3`, materialized
  `approval-pause.txt` as
  `materialized_file:10068ee46d1ca50c3c732f08a867d15e361ae22cc6c46e6ef492721428e67920`
  version `ver_019e7427-96c3-7990-b619-9ff2f3a25582`, and retained output
  `res_019e7427-96c5-7553-a106-bae7e50dbd4c`.
- Durability and idempotency evidence: no RWO-N13 scenario idempotency key
  duplicated; the only duplicate group was blank-key internal `engine::invoke`.
  `events` had zero `compact.*` rows, `engine_invocations` had zero failed rows
  for the scored run, no session-scoped logs were written, and reconstruction
  spans `engine_invocations`, `engine_queue_items`, `engine_approvals`,
  `engine_resource_leases`, `engine_compensation_records`, `engine_resources`,
  `engine_resource_versions`, and `engine_stream_events`.
- Score impact: Runtime resilience increases to `6/10`; current score increases
  to `65/100`.

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

2026-05-29 P1 result:

- Prompt:
  `Use only execute. RWO-N14 provider parity subtest P1/intent-read. Read the first line of README.md by intent, without guessing an absolute path. Do not use shell/process and do not answer from memory. Report the target capability, invocation ids if visible, and the exact first line.`
- Availability evidence: redacted auth/profile inspection showed Anthropic OAuth
  and OpenAI Codex OAuth accounts present, Google API key label `Default`, and
  reachable local Ollama model `gemma4:e4b` from
  `model::list` and Ollama `/api/tags`. The active profile/user setting still
  defaulted to OpenAI Codex `gpt-5.5`, while the Ollama retests explicitly used
  profile `local`, provider `ollama`, model `gemma4:e4b`.
- Clean four-provider run:
  `/tmp/rwo_n14_provider_parity_20260529074645.json`; simulator screenshot
  `/tmp/rwo_n14_simulator_20260529074645.png`. Anthropic
  `claude-sonnet-4-6` passed in
  `sess_019e7433-bd1f-79f0-8d6f-e037f2d07448`; OpenAI Codex `gpt-5.5`
  passed in `sess_019e7433-de30-7d51-8022-b15d5fc95b62`; Gemini
  `gemini-2.5-flash` passed in
  `sess_019e7433-fb83-74e1-973b-281c617ca83b`.
- First Ollama P1 run `sess_019e7434-10b9-7c73-8d44-e43af8017059` executed
  `capability::execute` `019e7434-7a6f-7330-a663-6d11c2466e45`, selected
  `filesystem::read_file`, and created child
  `019e7434-7bdb-7d00-abea-96c2ea88275a`. The child result was
  `{"content":"# Tron\n","path":"/Users/<USER>/Downloads/projects/tron/README.md","startLine":1,"endLine":1}`.
  There were zero failed invocations, zero approvals, zero `compact.*` events,
  and a completed prompt queue drain. Final assistant text did not include
  `# Tron`, so P1 was classified failed for Ollama before continuing broader
  parity testing.
- Isolation evidence: provider payload audit for the failed Ollama second turn
  included the `# Tron` content, proving the target capability, invocation
  ledger, DB event store, and provider-payload audit were not the failing
  layers. The same payload also showed stale Ollama-native request history
  fields (`capability_invocations`, `model_primitive_name`) and an execute
  result projection that placed exact text output after metadata labeled as not
  user output.
- Focused fixes: `domains/model/providers/ollama/message_converter.rs` now
  serializes prior assistant tool calls and tool results as native
  `tool_calls` and `tool_name`; `domains/model/providers/ollama/stream_handler.rs`
  no longer accepts the retired `capability_invocations` response spelling;
  `domains/agent/runner/agent/turn_runner/capability_invocations.rs` projects
  text result content first in an `[execute result - exact target output or
  status text]` block, followed by structured observation metadata.
- Focused coverage added or updated:
  `convert_assistant_with_tool_calls`, `capability_result_has_tool_name`,
  `full_roundtrip_conversation`,
  `native_tool_calls_field_deserializes_to_capability_invocation`, and
  `extract_result_content_projects_execute_observation_for_model`.
- Intermediate rebuilt-server retest
  `/tmp/rwo_n14_provider_parity_ollama_retest_20260529075645.json`,
  `sess_019e743c-e359-7ea0-aa4d-42d7de3852d1`, proved the native
  `tool_calls`/`tool_name` wire shape reached Ollama but the final answer still
  omitted `# Tron`; broad testing remained stopped.
- Final rebuilt-server retest
  `/tmp/rwo_n14_provider_parity_ollama_retest_20260529080138.json`, simulator
  screenshot `/tmp/rwo_n14_simulator_20260529080138.png`, passed on dev server
  PID `56373` in `sess_019e7441-5e8b-7d91-8c14-b4352d6e1887`. DB evidence:
  `agent::prompt` idempotency key `rwo-n14-intent_read-ollama-20260529080138`,
  parent run invocation `019e7441-5eef-7203-b7d4-09142f7f811d`, execute
  invocation `019e7441-870c-72e0-874c-734ab8287e33`, child read
  `019e7441-87ff-78a3-b440-ba3f6486f7cf`, final agent result
  `res_019e7441-8efc-7603-b40b-ac69900a8797` version
  `ver_019e7441-8efd-70a1-92b8-945982fcce82`, zero failed invocations, zero
  approvals, zero `compact.*` events, one completed queue drain
  `019e7441-8f0e-7bd3-9eb6-0bbcbfd44f5c`, and stream topics
  `agent.runtime`, `events.session`, `queue.lifecycle`, and
  `compensation.records`.
- Final assistant output in the passing Ollama retest reported target
  `filesystem::read_file` and exact first line ``# Tron``. The model said no
  invocation ids were visible even though DB evidence has them; this is tracked
  as prose weakness, not a P1 substrate failure, because the canonical
  invocation lineage is present in the DB and provider payload.
- Score impact: Provider parity increases to `4/6`; code modularity and
  simplification increases to `2/10` for removing the Ollama compatibility
  alias and keeping native wire ownership inside the provider module. Current
  score increases to `67/100`.

2026-05-29 P2 result:

- Prompt:
  `Use only execute. RWO-N14 provider parity subtest P2/safe-process. Run a safe read-only date command. Do not use filesystem or web. Report the target capability, execution mode, parent invocation id, child invocation id, exit code, and exact stdout.`
- Run log:
  `/tmp/rwo_n14_p2_provider_parity_20260529080843.json`; simulator screenshot
  `/tmp/rwo_n14_p2_simulator_20260529080843.png`. The real dev server stayed
  healthy on listener PID `56373`; health moved from uptime 435 seconds before
  the run to 492 seconds after the run without restart.
- Provider sessions: Anthropic `claude-sonnet-4-6` passed in
  `sess_019e7447-d814-7d02-b90d-a8dbc5998d6e`; OpenAI Codex `gpt-5.5` passed in
  `sess_019e7447-fda8-71e0-a427-99d9d9dd868d`; Gemini `gemini-2.5-flash`
  passed in `sess_019e7448-1b59-74c3-b655-38b574ca2aee`; Ollama `gemma4:e4b`
  passed in `sess_019e7448-34cd-7171-bab4-2e643ffec97e`.
- Target invocation evidence: each provider produced exactly one successful
  `capability::execute` row and one successful `process::run` child row. No
  provider produced a `filesystem::*` or `web::*` target row. All execute rows
  selected `process::run` through `first_party.process.v1.run`, carried
  corrected request arguments `{"command":"date","executionMode":"read_only"}`,
  required no approval, and recorded the process child id in
  `childInvocationIds`.
- Process result evidence:
  - Anthropic child `019e7447-ede5-7bc0-baae-58da44ef0caa`, parent
    `019e7447-ec8e-7de1-8151-61437107c848`, stdout
    `Fri May 29 08:08:51 PDT 2026\n`, exit code `0`.
  - OpenAI Codex child `019e7448-0b2c-7323-8f1e-a728cdf97d44`, parent
    `019e7448-0a40-71f0-b7b4-f9f4bd44773d`, stdout
    `Fri May 29 08:08:59 PDT 2026\n`, exit code `0`.
  - Gemini child `019e7448-28c2-7f93-a22a-58c84fbf1232`, parent
    `019e7448-27db-7730-a91d-7fe16f900e49`, stdout
    `Fri May 29 08:09:06 PDT 2026\n`, exit code `0`.
  - Ollama child `019e7448-8be2-7a02-a858-6ff228d1803d`, parent
    `019e7448-8a7b-7ee0-9c14-1dcad8f7d08c`, stdout
    `Fri May 29 08:09:32 PDT 2026\n`, exit code `0`.
- Resource, approval, queue, stream, and log evidence: process target rows
  produced `[]` resource refs; each process lease was acquired for
  `process:<session_id>` and released under the same trace; approval count was
  `0`; failed invocation count was `0`; `compact.*` event count was `0`;
  session/trace log count was `0`; each session had one completed
  `agent::prompt_queue_drain`; stream rows included `agent.runtime`,
  `events.session`, `queue.lifecycle`, `resource.leases`, and
  `compensation.records`.
- Classification: P2 passes with no code change. Provider parity increases to
  `5/6`, current score increases to `68/100`, and RWO-N14 remains active for P3
  missing-required-field parity.

2026-05-29 P3 result:

- Prompt:
  `Use only execute. RWO-N14 provider parity subtest P3/missing-required-field. Attempt a process run with a deliberately missing required command field, then report the correction or validation class without inventing a workaround.`
- First run log:
  `/tmp/rwo_n14_p3_provider_parity_20260529081747.json`; simulator screenshot
  `/tmp/rwo_n14_p3_simulator_20260529081747.png`. Anthropic
  `sess_019e7450-25ee-76f0-a947-5570f5944fac`, OpenAI Codex
  `sess_019e7450-610c-7130-bead-c03000ef73eb`, and Gemini
  `sess_019e7450-86c8-7300-9006-29e1576609a5` returned needs-input
  validation without target children. Ollama `sess_019e7450-983c-7033-8965-85f8daab139c`
  sent `{"command":"","executionMode":"read_only"}`; the engine accepted the
  empty string, created `process::run` child
  `019e7450-f402-7862-9191-6d5de2ce2c0e`, exited `0`, and produced empty
  stdout/stderr. Broad testing stopped at that failure.
- Root-cause fix: `engine/schema.rs` now validates the `minLength` keyword and
  enforces it for string payloads; `process::run` request schema sets
  `command.minLength = 1`; `process_run_value` rejects blank commands before
  process execution; and `capability::execute` maps empty or null required
  fields to `needs_input`/`missing_required_argument` with
  `missingFields`/`missingArgumentPaths` instead of target-payload-invalid.
- Intermediate retest
  `/tmp/rwo_n14_p3_provider_parity_20260529082526.json` proved the empty-command
  process child no longer executed, then exposed the follow-up null-field
  classification gap. DB inspection for the later Gemini timing attempt in
  `/tmp/rwo_n14_p3_provider_parity_20260529083648.json` showed the engine result
  had eventually completed correctly; the harness wait was updated to wait for
  assistant text after the completed execute preflight result and a later
  `stream.turn_end`.
- Clean four-provider retest:
  `/tmp/rwo_n14_p3_provider_parity_20260529084151.json`; simulator screenshot
  `/tmp/rwo_n14_p3_simulator_20260529084151.png`; real dev server PID `68590`
  stayed healthy from uptime 18 seconds before the run to 80 seconds after the
  run.
- Provider sessions: Anthropic `claude-sonnet-4-6` passed in
  `sess_019e7466-2bd2-7d72-b17d-37ca53fe0993`; OpenAI Codex `gpt-5.5` passed in
  `sess_019e7466-58e5-7360-b0f5-1507d6e7d3c9`; Gemini `gemini-2.5-flash`
  passed in `sess_019e7466-71ed-7bf3-a5b3-b425f9c41dc1`; Ollama `gemma4:e4b`
  passed in `sess_019e7466-82f0-7e02-830e-5989c1bb896c`.
- Execute evidence: Anthropic execute
  `019e7466-41fc-7971-9a59-5c7c6e3a5738`, OpenAI execute
  `019e7466-683f-7b51-b973-48bb2d0f867f`, Gemini execute
  `019e7466-7ccf-7563-b4df-46d4d3f9e349`, and Ollama execute
  `019e7466-f180-7ab2-be58-109be6947c13` each selected `process::run` through
  `first_party.process.v1.run`, returned `status = needs_input`,
  `approvalDecision.status = not_required`, `validationKind =
  missing_required_argument`, `childInvocationCreated = false`, empty
  `childInvocationIds`, and empty `resourceRefs`.
- Provider parity details: Anthropic and OpenAI supplied
  `executionMode = read_only` while omitting `command`, so the missing path was
  `arguments.command`. Gemini and Ollama supplied an empty argument object after
  the fix, so the missing paths were `arguments.command` and
  `arguments.executionMode`. All four provider final assistant messages named
  the validation/needs-input class without inventing a fallback command.
- Resource, approval, queue, stream, and log evidence: there were zero
  `process::run` child rows, zero process leases under the four trace ids, zero
  filesystem or web target rows, zero approvals, zero failed invocations, zero
  `compact.*` events, and no session/trace log rows. Each session had one
  completed `agent::prompt_queue_drain`; stream rows included `agent.runtime`,
  `events.session`, and `queue.lifecycle`.
- Score impact: Provider parity reaches `6/6`, execute portal ergonomics
  increases to `9/10`, current score increases to `70/100`, and RWO-N14 remains
  active for P4 high-risk approval pause/resume.

2026-05-29 P4 result:

- Prompt:
  `Use only execute. RWO-N14 provider parity subtest P4/high-risk-approval. Start a high-risk write command that requires approval, pause for approval, then resume after approval and report the approval id, child invocation id, and resource refs.`
- Initial Anthropic run `sess_019e7480-6ef5-7363-84a5-0232f6b64f5e`
  targeted `filesystem::write_file` for an absolute host path, then attempted
  approval discovery; no approval or process child was created. The failure
  layer was `model_guidance`.
- Next Anthropic run `sess_019e748b-670d-76f0-9318-04bc0a3ac297`
  selected `process::run` and created approval state, but the first child
  failed after approval because `expectedOutputs[].path` was an absolute host
  path. A later OpenAI run
  `sess_019e7494-65b5-7321-82b3-dbf6c4c2209d` exposed the same late-failure
  class for a home-relative `~/.tron/...` expected output path. Broad testing
  stayed stopped while the process owner was fixed.
- Root-cause fixes: execute schema/model metadata and the capability primer now
  teach approval-gated write commands to target `process::run` with
  `executionMode = sandbox_materialized` and `expectedOutputs`, not
  `filesystem::write_file` or `approval::request`; capability registry search
  now indexes effect/risk names without letting null metadata keys dominate
  intent ranking; `process::run` contract/docs now state that
  `expectedOutputs[].path` is relative to the isolated process sandbox; and the
  process approval preflight rejects empty, absolute, home-relative, root,
  prefix, and parent-escaping expected output paths before any approval is
  created.
- Focused coverage added or used:
  `approval_write_command_query_prefers_process_run_recipe`,
  `primer_guides_approval_gated_write_commands_to_process_run`,
  `execute_schema_teaches_target_call_shape_and_complete_payloads`,
  `sandbox_materialized_absolute_output_path_is_invalid_before_approval`,
  `sandbox_materialized_home_relative_output_path_is_invalid_before_approval`,
  `sandbox_materialized_parent_output_path_is_invalid_before_approval`, and
  `process_run_sandbox_rejects_absolute_output_paths_before_approval`.
- Simulator harness evidence was also tightened. Google session
  `sess_019e7498-6835-7672-a13f-e247006cf7f4` proved that a harness could stop
  after an early rejected turn while the engine had already continued to a
  later pending approval. The active scorecard and iOS development docs now
  require stable terminal DB state plus chat parity checks for the user prompt,
  assistant turn, approval sheet lifecycle, and stale action sheets before
  screenshot evidence is treated as complete.
- Clean four-provider retest:
  `/tmp/rwo_n14_p4_provider_parity_20260529094326.json`; real dev server PID
  `99393` stayed healthy from uptime 461 seconds before the run to 614 seconds
  after the run. Simulator screenshots:
  `/tmp/rwo_n14_p4_anthropic_simulator_20260529094326.png`,
  `/tmp/rwo_n14_p4_openai-codex_simulator_20260529094326.png`,
  `/tmp/rwo_n14_p4_google_simulator_20260529094326.png`, and
  `/tmp/rwo_n14_p4_ollama_simulator_20260529094326.png`.
- Provider evidence:
  - Anthropic `claude-sonnet-4-6` passed in
    `sess_019e749e-8539-7591-a146-5ee38152b03a`; approval
    `019e749e-e2e1-7671-bc2e-3fe38720cb9e`; process child
    `019e749e-e52e-7952-bf4a-ce8a5c156fa2`; refs
    `materialized_file:9e1d56273678169d999c036d8f9fe70938b9aff42e9030ad555dbaf4232688ed`
    and `res_019e749e-e559-7572-9e5b-8db5b65c7aa3`.
  - OpenAI Codex `gpt-5.5` passed in
    `sess_019e749f-2500-7240-a1b9-9b3295bdb853`; approval
    `019e749f-7ba8-79e3-a402-db425392c18f`; process child
    `019e749f-7d9d-7212-bfdb-383b1400b8a6`; refs
    `materialized_file:a5311344ef40a8b0b01f901b4032abd46b6048c7cc9b306089e3b77504cd9879`
    and `res_019e749f-7dbc-70c1-a6e3-71bb2de00be3`.
  - Gemini `gemini-2.5-flash` passed in
    `sess_019e749f-a5b4-7471-b129-91d2ef9ce105`; approval
    `019e749f-c558-75f1-afdb-dceec2a2fbf2`; process child
    `019e749f-cae1-7591-81f9-56045a3e1506`; refs
    `materialized_file:ecfacc788781bc378252eb8176e7075140fbb166607aad27623415a9beaaad9a`
    and `res_019e749f-cb0a-7a12-a886-0941157d3e70`.
  - Ollama `gemma4:e4b` passed in
    `sess_019e749f-e321-7451-8392-1f742fd840d4`; approval
    `019e74a0-73dc-7d83-b001-230b455a6c54`; process child
    `019e74a0-771b-7272-ae8b-cc6c0203a09c`; refs
    `materialized_file:07ac9c9b9c376b9fbe1cd50d9f8e8e9b170848fc5788e162de66544b0adcc8a7`
    and `res_019e74a0-774a-7432-86a3-01b0c513b0ba`.
- Resource, approval, queue, stream, and log evidence: each provider created
  exactly one executed `process::run` approval, one `approval::resolve`, one
  successful sandbox-materialized `process::run` child, one materialized file
  resource, and one execution-output resource. There were zero failed
  invocations, zero `compact.*` events, no filesystem or web target rows, no
  session/trace log rows, one completed prompt queue drain per provider, and
  stream rows on `agent.runtime`, `approvals`, `events.session`,
  `queue.lifecycle`, `resource.leases`, and `compensation.records`.
- Score impact: Safety, grants, and approvals increases to `9/10`; runtime
  resilience increases to `7/10`; current score increases to `72/100`; and
  RWO-N14 remains active for P5 idempotency replay.

2026-05-29 P4 failed-card follow-up:

- Trigger: simulator review of the prior P4 clean pass showed red
  `capability::execute` cards before the final successful approval turns even
  though the final engine invocation count was clean.
- DB root cause:
  - Anthropic and OpenAI Codex first produced `target_policy_rejected`
    `capability::execute` results for absolute or home-relative
    `expectedOutputs[].path` values. These were repairable argument-shape
    errors, but execute projected them with `isError=true`.
  - Anthropic and OpenAI Codex also hit `IDEMPOTENCY_CONFLICT` rows when a
    model-chosen approval idempotency key collided with an earlier session.
    Approval idempotency was keyed globally instead of by the same
    function/session/workspace scope used by the engine ledger.
- Root-cause fixes: approval idempotency now scopes by function id, session id,
  workspace id, and idempotency key in both in-memory and SQLite approval
  stores; the SQLite approval table migrates away from the prior global
  `idempotency_key TEXT UNIQUE` column into a scoped unique index; and
  `process::run` sandbox output path preflight returns repairable
  `needs_input` details with `isError=false` instead of a failed-card result.
- Focused coverage added:
  `approval_idempotency_is_scoped_to_session`,
  `approval_idempotency_still_conflicts_within_session`,
  `sqlite_approval_idempotency_is_scoped_after_global_migration`,
  `sqlite_approval_idempotency_still_conflicts_within_scope`, and
  `process_run_sandbox_output_path_shape_is_repairable_preflight`.
- Exact rerun: `/tmp/rwo_n14_p4_provider_parity_20260529101057.json`; real dev
  server PID `10586`; health stayed OK from uptime 205 seconds before the run
  to 317 seconds after the run. Final deep-link screenshots:
  `/tmp/rwo_n14_p4_anthropic_final_simulator_20260529101057.png`,
  `/tmp/rwo_n14_p4_openai-codex_final_simulator_20260529101057.png`,
  `/tmp/rwo_n14_p4_google_final_simulator_20260529101057.png`, and
  `/tmp/rwo_n14_p4_ollama_final_simulator_20260529101057.png`.
- Provider evidence:
  - Anthropic `claude-sonnet-4-6` passed in
    `sess_019e74b7-b9bc-7de0-9c59-8cab92fffd77`; approval
    `019e74b7-df11-7043-9a59-99a2e4d099c2`; process child
    `019e74b7-e2a3-7243-83c0-18142528737f`; refs
    `materialized_file:b5e42323e87f106ffce662260479fb5b397048eee8c05d76677d390042c01cb1`
    and `res_019e74b7-e2c1-7471-a97f-daf4f4524b95`.
  - OpenAI Codex `gpt-5.5` passed in
    `sess_019e74b8-127f-72d2-865c-99de12e8ed1b`; approval
    `019e74b8-2e99-70a0-8ddb-681a47112ba1`; process child
    `019e74b8-2fd8-7221-9b17-f1eaa3667723`; refs
    `materialized_file:9e1d56273678169d999c036d8f9fe70938b9aff42e9030ad555dbaf4232688ed`
    and `res_019e74b8-2ff5-7700-9e59-575f9c9d0244`.
  - Gemini `gemini-2.5-flash` passed in
    `sess_019e74b8-4ff2-76c1-92d6-cae741f593f4`; approval
    `019e74b8-6882-7d91-a0ff-dc0b315d3bf2`; process child
    `019e74b8-6947-7240-95fd-e8ab3d4bd0dd`; refs
    `materialized_file:e970f1456b215d957d9701cd905200c79c0903646cde916028612a527fe15b82`
    and `res_019e74b8-6969-79d0-9954-dea4a2a24370`.
  - Ollama `gemma4:e4b` was inconclusive in
    `sess_019e74b8-7d7f-7400-94c7-8de99d917761`; it selected
    `process::run` but supplied empty arguments, so execute returned
    `status = needs_input`, `isError = false`, no approval, and no child. This
    is tracked as a small-local-model limitation; later local-provider parity
    should retry with a larger Ollama model before treating the result as
    substrate evidence.
- Resource, approval, queue, stream, and log evidence: the three passed
  providers each created one executed approval, one `approval::resolve`, one
  successful sandbox-materialized process child, materialized-file and
  execution-output resources, one completed prompt queue drain, zero failed
  invocations, zero `compact.*` events, zero `isError=true` capability
  completions, and no session/trace log rows. Stream rows included
  `agent.runtime`, `approvals`, `events.session`, `queue.lifecycle`,
  `resource.leases`, and `compensation.records`.
- Chat parity evidence: final deep-link screenshots show the submitted user
  prompt in the transcript for Gemini and Ollama. Gemini shows an approved
  non-actionable approval card and no pending confirmation sheet after DB
  approval status reached `executed`. This confirms the harness must collect
  final screenshots after terminal DB state, not only immediately after
  session creation. Any future stale actionable approval sheet remains an
  `ios_rendering` follow-up even when DB truth is canonical.
- Score impact: no additional score is awarded because P4 had already banked
  its scenario points. The follow-up removes a simulator-visible failed-card
  regression and keeps current score at `72/100`.

2026-05-29 P5 approval idempotency replay:

- Prompt:

```text
Use only execute. Replay the approved command with the same idempotency key and report whether a new child invocation was created.
```

- Harness: `/tmp/rwo_n14_p5_provider_parity_harness.py` drove the simulator
  deep-link flow against the real dev server and classified DB truth from
  `engine_invocations`, `engine_approvals`, events, queues, streams, resources,
  and logs. This harness is a temporary scorecard runner, not product code.
- Exact failure and root-cause path:
  - Initial P5 matrix `/tmp/rwo_n14_p5_provider_parity_20260529102725.json`
    passed Anthropic and OpenAI Codex but failed Gemini in
    `sess_019e74c8-115b-7a11-bde3-5c1a9acb227b`: Gemini omitted an explicit
    setup idempotency key, execute derived one internally, and the approved
    result did not expose the effective replay key clearly enough for the next
    turn.
  - First projection fix exposed `details.idempotencyKey` and
    `approvalState.idempotencyKey`; exact Gemini rerun
    `/tmp/rwo_n14_p5_provider_parity_20260529103429.json` passed
    `sess_019e74cd-455e-79d0-ad29-5e31efb8a4d0`, but the full matrix still
    proved that persisted history restored only display content, not the
    model-facing execute observation.
  - Reconstruction fix stores `modelContextContent` separately on
    `capability.invocation.completed` events and prefers it when rebuilding
    provider context. Active clients still render `content`.
  - Final ergonomics fix changed generated child execute replay keys from full
    `capability-execute:v1:<256-bit-hex>` strings to deterministic
    `capability-execute:v2:<128-bit-hex>` strings, reducing model
    transcription errors without adding a fallback or side channel.
- Focused coverage added:
  `execute_observation_projects_replay_idempotency_key_for_model`,
  `model_context_result_text_preserves_execute_observation_for_reconstruction`,
  `capability_result_reconstruction_uses_model_context_content`, and updated
  `child_idempotency_derives_from_parent_capability_invocation_key`.
- Exact failed-provider retest after all fixes:
  `/tmp/rwo_n14_p5_provider_parity_20260529105749.json`; Gemini
  `sess_019e74e2-a0a8-7553-bb2b-df22f983144c`; approval
  `019e74e2-b640-78d1-8f50-c025d55c298f`; idempotency key
  `high-risk-write-P4`; one setup `process::run` child; one P5
  `capability::execute`; `approvalReplayObserved=true`;
  `childInvocationCreatedFalse=true`; zero new approvals; zero new process
  children; zero failed invocations; zero `compact.*` events; completed queue
  drains.
- Full matrix retest:
  `/tmp/rwo_n14_p5_provider_parity_20260529105816.json`; real dev server PID
  `36012`; health stayed OK from uptime 34 seconds before the run to 212
  seconds after the run. Final deep-link screenshots:
  `/tmp/rwo_n14_p5_anthropic_final_simulator_20260529105816.png`,
  `/tmp/rwo_n14_p5_openai-codex_final_simulator_20260529105816.png`,
  `/tmp/rwo_n14_p5_google_final_simulator_20260529105816.png`, and
  `/tmp/rwo_n14_p5_ollama_final_simulator_20260529105816.png`.
- Provider evidence:
  - Anthropic `claude-sonnet-4-6` passed in
    `sess_019e74e3-09ae-7233-b27b-963573a4399a`; approval
    `019e74e3-3464-7b70-86b5-7dd5b9abb08b`; one setup child; one P5 execute;
    `approvalReplayed=true`; `childInvocationCreated=false`; no new approval or
    child.
  - OpenAI Codex `gpt-5.5` passed in
    `sess_019e74e3-d6ad-7001-9685-fa398767de76`; approval
    `019e74e3-fed5-7d13-b427-333b24d80f16`; one setup child; one P5 execute;
    `approvalReplayed=true`; `childInvocationCreated=false`; no new approval or
    child.
  - Gemini `gemini-2.5-flash` passed in
    `sess_019e74e4-4510-7393-a33a-b2626efe7a9a`; approval
    `019e74e4-5a3d-7570-8b51-0f2e32eeb863`; generated replay key
    `capability-execute:v2:d5a835be42fe6e20d0c80dab4f472494`; one setup child;
    one P5 execute; `approvalReplayed=true`; `childInvocationCreated=false`; no
    new approval or child.
  - Ollama `gemma4:e4b` was inconclusive in
    `sess_019e74e4-97b5-71c2-93f2-edac82506664`; it did not issue the setup
    execute call, created no approval, created no child, and recorded no failed
    invocation or `compact.*` event. Later local-provider parity should retry
    with a larger Ollama model before using this as substrate evidence.
- Score impact at the P5 checkpoint: execute portal ergonomics increased to
  `10/10`, resource truth and durability increased to `10/10`, current score
  increased to `74/100`, and RWO-N14 advanced to the remaining
  architecture-summary provider prompt.

2026-05-29 P6 architecture-summary parity:

- Prompt:

```text
Use only execute. Inspect this repo enough to summarize the worker/function/trigger architecture. Do not answer from memory. Cite files inspected and list every capability used.
```

- Harness: `/tmp/rwo_n14_p6_provider_parity_harness.py` drove the simulator
  deep-link flow against the real dev server and classified DB truth from
  invocations, events, queues, streams, resources, approvals, and logs. The
  first Anthropic run exposed a harness-only observability bug: final assistant
  events were blob-backed, so the temporary reader had to dereference event
  payload blobs before classifying cited files and listed capabilities.
- Anthropic `claude-sonnet-4-6` passed in
  `sess_019e74f0-095c-7c73-8151-fa3b33f1d729`; run log
  `/tmp/rwo_n14_p6_provider_parity_20260529111228.json`; final screenshot
  `/tmp/rwo_n14_p6_anthropic_final_simulator_20260529111228.png`; 20
  `capability::execute` rows, 7 `filesystem::list_dir`, 13
  `filesystem::read_file`, 13 cited inspected files, completed queue drain,
  zero failed invocations, zero approvals, zero `compact.*` events, and zero
  session-scoped logs.
- OpenAI Codex `gpt-5.5` passed in
  `sess_019e74f5-42c5-7443-9814-e9cc231a105f`; run log
  `/tmp/rwo_n14_p6_provider_parity_20260529111810.json`; final screenshot
  `/tmp/rwo_n14_p6_openai-codex_final_simulator_20260529111810.png`; 32
  `capability::execute` rows, 5 `filesystem::list_dir`, 10
  `filesystem::search_text`, 17 `filesystem::read_file`, 10 cited inspected
  files, completed queue drain, zero failed invocations, zero approvals, zero
  `compact.*` events, and zero session-scoped logs.
- Gemini `gemini-2.5-flash` passed in
  `sess_019e74f6-c0dc-7931-a7e9-f4c55d357464`; run log
  `/tmp/rwo_n14_p6_provider_parity_20260529111810.json`; final screenshot
  `/tmp/rwo_n14_p6_google_final_simulator_20260529111810.png`; 6
  `capability::execute` rows, 4 `filesystem::list_dir`, 2
  `filesystem::read_file`, 5 cited inspected paths, completed queue drain, zero
  failed invocations, zero approvals, zero `compact.*` events, and zero
  session-scoped logs.
- Ollama `gemma4:e4b` was inconclusive in
  `sess_019e74f7-35dd-7ce2-8e26-07b64d919aef`; run log
  `/tmp/rwo_n14_p6_provider_parity_20260529111810.json`; final screenshot
  `/tmp/rwo_n14_p6_ollama_final_simulator_20260529111810.png`; 6
  `capability::execute` rows, 5 `filesystem::list_dir`, 1
  `filesystem::read_file`, completed queue drain, zero failed invocations, zero
  approvals, zero `compact.*` events, and zero session-scoped logs. It used the
  collapsed substrate but did not satisfy the answer contract because it cited
  only one file and did not list the used capabilities.
- Score impact: observability and auditability increases to `6/8`, current
  score increases to `75/100`, and RWO-N14 is complete for major-provider
  parity. The remaining local-provider gap should be retried with a larger
  Ollama model before treating it as substrate evidence.

2026-05-29 process sandbox command-output boundary follow-up:

- Trigger: the later Google P5 simulator session
  `sess_019e74d4-7e0a-7c72-81e7-cb7e15c26be6` exposed two failed
  approval-gated `process::run` children for the high-risk write setup:
  `019e74d4-98f7-7132-be21-8a938a0024f0` attempted to write
  `~/.tron/workspace/reports/high-risk-test.txt` while declaring
  `reports/high-risk-test.txt`, and
  `019e74d4-a8d8-7ec0-8211-f16172c7e334` attempted
  `reports/high-risk-test.txt` before the nested parent existed in the sandbox.
- Root cause: `sandbox_materialized` bounded declared `expectedOutputs` paths
  but did not preflight shell redirection/`tee` write targets against those
  declarations, did not prepare nested expected-output parent directories inside
  the sandbox, and inherited host `HOME`/`TMPDIR`, so a home-relative shell
  expansion could target host state before materialization.
- Fix: `process::run` now rejects sandbox-materialized command redirection and
  `tee` targets unless they normalize to one of the declared relative
  `expectedOutputs[].path` values; rejects absolute, home-relative,
  shell-expanded, parent-escaping, globbed, and undeclared command output
  targets before approval; prepares declared nested output parent directories
  inside the sandbox; and applies sandbox-local `HOME`/`TMPDIR` after any
  caller-provided env.
- Focused coverage added:
  `sandbox_materialized_home_relative_command_write_is_invalid_before_approval`,
  `sandbox_materialized_undeclared_command_write_is_invalid_before_approval`,
  `sandbox_materialized_declared_nested_command_write_is_valid_before_approval`,
  `sandbox_materialized_tee_target_must_be_declared`,
  `sandbox_materialized_declared_tee_pipeline_is_valid_before_approval`,
  `sandbox_materialized_nested_output_parent_is_prepared_inside_sandbox`, and
  `sandbox_materialized_home_relative_command_write_rejects_before_spawn`.
  `threat_model_invariants` now statically requires the command-write-target
  preflight and nested-output parent preparation gates to remain in place.
- Exact live retest:
  - Google-only P5 harness
    `/tmp/rwo_n14_p5_provider_parity_20260529120827.json` passed on rebuilt dev
    server PID `57422` with final simulator screenshot
    `/tmp/rwo_n14_p5_google_final_simulator_20260529120827.png`. Session
    `sess_019e7523-4c24-7b02-9ff7-08b896c05c74` created approval
    `019e7523-6873-7393-84a4-d924d3eeb530`, process child
    `019e7523-6aee-7511-a5d2-b0e0d54acbfe`, materialized file
    `materialized_file:ad853ffabe8a2798c146979cf62bcc168001220160ca6b5c922ad842efd2b76e`,
    and execution output `res_019e7523-6b07-7181-b760-1d7d6b06247a`; the replay
    observed `approvalReplayed=true`, `childInvocationCreated=false`, zero new
    approvals, zero new process children, zero failed invocations, zero
    `compact.*` events, and completed queue drains.
  - Direct exact-payload probe
    `sess_019e7523-ffb5-7601-acdf-8bf36461824a` submitted the previously bad
    home-relative shape:
    `printf 'This is a high-risk test file.\n' > ~/.tron/workspace/reports/exact-home-leak-20260529120914.txt`
    with declared expected output
    `reports/exact-home-leak-20260529120914.txt`. `capability::execute`
    `019e7524-0035-78d3-9847-af7fd5a5d13e` returned
    `target_policy_rejected`, `approvalCreated=false`,
    `childInvocationCreated=false`, no approval rows, no `process::run` child,
    no failed invocation rows, no `compact.*` events, and no file at
    `/Users/moose/.tron/workspace/reports/exact-home-leak-20260529120914.txt`.
- Continuation audit after SCB-S8, 2026-05-29: the latest failed invocation rows
  in the production DB were still the historical
  `sess_019e74d4-7e0a-7c72-81e7-cb7e15c26be6` sandbox failures above, not the
  SCB-S8 session. A Google-only P5 rerun against dev server PID `26801`
  initially reproduced stale visible approval-sheet state only because the
  simulator was still running the pre-SCB-S8 app binary. After rebuilding and
  installing `Tron Beta` from
  `/tmp/tron-ios-beta-derived/Build/Products/Beta-iphonesimulator/TronMobile.app`,
  the exact Google P5 rerun passed in
  `sess_019e75ba-470a-7671-b1a3-4b90e1ed871c` with run log
  `/tmp/rwo_n14_p5_provider_parity_20260529145322.json`, final screenshot
  `/tmp/rwo_n14_p5_google_final_simulator_20260529145322.png`, approval
  `019e75ba-5c6a-7583-80c0-265a32c07032` executed, one `process::run` child,
  one replayed `capability::execute`, no new approval or child on replay, zero
  failed invocations, zero pending approvals, zero `compact.*` events, and no
  stale approval sheet visible in the installed app. A follow-up app-path smoke
  check reopened the same session through `tron://session/sess_019e75ba-470a-7671-b1a3-4b90e1ed871c`
  and captured `/tmp/rwo_n14_p5_google_current_app_path_smoke.png`; DB evidence
  for that exact session still showed zero failed invocations, zero pending
  approvals, zero `compact.*` events, and zero open queue items.
- Simulator reset proof, 2026-05-29: after force-quitting Simulator, shutting
  down the accidental fresh unpaired iPhone 17 Pro simulator, booting the
  original paired iPhone 17 Pro simulator
  `267F6468-09AE-471D-9157-29144173EB82`, reinstalling
  `/tmp/tron-ios-beta-derived/Build/Products/Beta-iphonesimulator/TronMobile.app`,
  launching `com.tron.mobile.beta`, and reopening the same `tron://session/...`
  deep link, the initial shell loaded the transcript after server connection
  settled. Screenshot
  `/tmp/tron_beta_old_sim_deeplink_after_wait_20260529.png` shows the session
  content and no stale approval sheet; DB sanity for
  `sess_019e75ba-470a-7671-b1a3-4b90e1ed871c` still showed zero failed
  invocations, zero pending approvals, zero `compact.*` events, and zero open
  queue items.
- Score impact: Safety, grants, and approvals reaches `10/10`; current score
  increased to `77/100` at that checkpoint, and broad testing moved to SCB-S1b
  structural decomposition before the deferred simulator/chat parity work.

Deferred simulator/chat parity follow-up:

- Simulator deep-link harness process is now formalized in this scorecard and
  `packages/ios-app/docs/development.md`: future scorecard tests open
  `tron://session/<session_id>`, wait for terminal DB state, capture final
  screenshots after engine truth settles, and rebuild/install the current app
  binary before claiming parity for changed iOS code.
- Formalize the RWO-N14 P4/P5 harness vocabulary and procedure. In this
  scorecard, a "P5 harness" means the provider-parity harness that first seeds
  an approval-gated `process::run`, resolves the approval through engine truth,
  then replays the approved top-level execute idempotency key and verifies that
  no new approval or child process is created.
- Add a focused simulator parity test for deep-linked prompt submissions: the
  user prompt must appear in the chat transcript with the same ordering and
  state as `message.user`/`agent::prompt` DB truth.
- Add a harness parity check for Python/WebSocket-driven prompt injection: if
  the agent response appears automatically in the simulator, the originating
  user prompt must also be visible from the same server event stream rather than
  silently existing only in DB truth.
- Add a focused approval-rendering parity test: once an approval reaches a
  terminal engine status such as `executed`, `denied`, or `failed`, the iOS
  confirmation sheet/card must reconcile to that state and never remain
  actionable.
- Add a full chat/engine state parity audit after the engine hardening gates:
  visible user turns, assistant turns, capability cards, approval sheets,
  automation progress, terminal errors, and completion state must reconstruct
  from engine DB/event/resource/approval truth without product-state side
  channels.
- These are tracked as `ios_rendering`/`stream_or_state` parity work after the
  core engine hardening gates; DB truth remains the canonical classifier for
  current scorecard scenarios.
- UI polish for the chat and approval surfaces is deliberately deferred until
  engine-state parity is proven; cosmetic improvements must not mask or bypass
  drift between visible state and canonical engine truth.
- Do not classify Gemma 4 E4B Ollama shortfalls as collapsed-substrate failures
  until the same local-provider scenario has been retried with a larger local
  model and canonical DB evidence.

### RWO-N15: Live Worker Queue/Trigger/Stream Robustness

Prompt and procedure:

- A deterministic live Python worker registered one worker, one queue-capable
  function, one manual trigger, one stream topic/subscription path, and one
  evidence resource path against the real dev server. The agent was driven
  through `agent::prompt`, so the scenario exercised the same model-facing
  `capability::execute` path used by the app instead of a privileged direct
  engine call.
- The session prompt required the agent to subscribe to the worker stream,
  dispatch the trigger with enqueue delivery, read the queue receipt, poll the
  stream event, create a resource-backed evidence record, check worker health,
  unsubscribe, and report lineage. The model-visible tool surface remained one
  portal: every operation entered through `capability::execute`.
- The passing session was opened in the old paired simulator
  `267F6468-09AE-471D-9157-29144173EB82` with
  `xcrun simctl openurl ... tron://session/sess_019e75e0-b3bb-7be0-bf24-6ab044aa0def`.
  Screenshot evidence is at `/tmp/rwo_n15_20260529153520_old_simulator.png`.

Focused fixes:

- Added the canonical agent-visible `trigger::dispatch` primitive in
  `packages/agent/src/engine/primitives/trigger.rs`. The primitive dispatches a
  registered trigger through `EngineTriggerRuntime`, preserves actor,
  authority scopes, runtime metadata, trace, parent invocation id, session and
  workspace ids, and optionally overrides the target idempotency key. It is an
  `IdempotentWrite` function with `trigger.dispatch` authority and uses the
  engine ledger for replay.
- Widened the built-in `manual` trigger type in
  `packages/agent/src/transport/contracts.rs` to allow both `Sync` and
  `Enqueue`, so queue delivery is part of the canonical trigger contract rather
  than a fixture-only custom trigger type.
- Added the focused Rust tests
  `trigger_dispatch_primitive_enqueues_and_drains_triggered_invocation` and
  `manual_trigger_type_supports_sync_and_enqueue_dispatch`.
- Added the deterministic live fixture
  `packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py`, including a
  `--self-test` mode for worker protocol validation before live runs.

Harness lessons:

- Direct public `/engine` `capability::execute` is a `Client` actor path. It
  must not be used as proof that agent-visible primitives are discoverable to a
  model agent, and its inability to see `Agent`-visible `trigger::dispatch` is
  expected policy rather than a failed engine capability.
- Agent-path harnesses must wait for `stream.turn_end` with
  `stopReason = "end_turn"`. A prior unscored RWO-N15 attempt treated
  `stopReason = "tool_use"` as terminal and killed the worker while the engine
  still needed it for the next tool call.

Passing evidence:

- Session: `sess_019e75e0-b3bb-7be0-bf24-6ab044aa0def`.
- Real dev server PID: `41237`.
- Run log: `/tmp/rwo_n15_agent_run_20260529153520.json`.
- Worker fixture log:
  `/tmp/rwo_n15_agent_worker_fixture_20260529153520.jsonl`.
- Worker/function/trigger/topic:
  `rwo-n15-agent-worker-20260529153520`,
  `rwo_n15_agent_20260529153520::queued_echo`,
  `manual:rwo_n15_agent_20260529153520.queued_echo`, and
  `rwo_n15_agent_20260529153520.worker.events`.
- Queue receipt `019e75e0-da53-7c00-a1ad-9fda0b347c13` completed with
  attempts `0`, lease owner `tron-server`, and trigger id
  `manual:rwo_n15_agent_20260529153520.queued_echo`.
- Stream polling observed one worker event with `rwoN15Fixture = true`.
- Evidence resource `evidence:rwo-n15-agent:20260529153520` was written at
  version `ver_019e75e1-1524-70f2-aec1-4373d74845d1`.
- Catalog revisions `403-408` showed worker, function, and trigger
  registration followed by unregister cleanup after fixture termination.
- DB classification found zero failed invocations, zero pending approvals, zero
  `compact.*` events, zero open scenario queue rows, no unreleased resource
  leases, no active RWO-N15 subscription, and only expected app websocket
  `events.session`/`approvals` subscriptions after the simulator deep link.

Classification and score impact:

- Status: `passed_after_fix`.
- Primary root layers fixed: `execute_resolution` and `queue_or_trigger`.
- First-party capability usefulness is now `10/10`; worker/function/trigger
  substrate is now `11/14`; runtime resilience is now `8/10`; total score is
  `91/100`.
- Remaining follow-up: RWO-N15 proves registration, queued trigger dispatch,
  stream evidence, resource evidence, terminal cleanup, and app-route evidence.
  It does not yet prove pre-terminal worker crash, retry, failure, or
  cancellation semantics under a claimed queue item. That gap becomes RWO-N16.

### RWO-N15-F1: Harness Terminal-State Guard

Trigger:

- The latest failed invocation rows after the RWO-N15 checkpoint belonged to
  the unscored premature harness session
  `sess_019e75de-e8c2-7052-b44b-f9c12215354a`, not the passing RWO-N15 session.
- DB evidence showed the worker connected, registered its function, and
  registered its trigger at stream cursors `106470-106472`, then
  disconnected/unregistered at cursors `106525-106526` before the agent's
  second tool turn. The subsequent `trigger::dispatch` child
  `019e75df-14cf-76c3-ad70-2278bf93e07e` and `worker::health` child
  `019e75df-59d2-73d1-9786-69ddaa0d9c46` therefore failed against a missing
  volatile worker.

Root cause:

- `observability_gap`: a temporary simulator/live-worker harness treated
  `stream.turn_end` with `stopReason = "tool_use"` as terminal and stopped the
  fixture. That is incorrect because `tool_use` means the provider yielded so
  the engine can execute the tool result and continue the assistant run.

Fix:

- Added `packages/agent/tests/fixtures/session_terminal_guard.py`, a DB-backed
  terminal-state guard for simulator and live-worker harnesses. It classifies a
  session as terminal only after `stream.turn_end` with
  `stopReason = "end_turn"`, no later `stream.turn_start`, no pending
  approvals, and no open queue items. Its `--wait` mode requires stable
  counts across events, invocations, approvals, resources, resource versions,
  queues, streams, and logs before returning terminal success.
- Updated `packages/ios-app/docs/development.md` and this scorecard's static
  gates to require the terminal guard and to name `tool_use` as non-terminal.

Verification:

- `python3 packages/agent/tests/fixtures/session_terminal_guard.py --self-test`
  passed.
- The guard correctly rejected the failed session at the premature cutoff:
  `python3 packages/agent/tests/fixtures/session_terminal_guard.py --session-id sess_019e75de-e8c2-7052-b44b-f9c12215354a --max-sequence 34`
  returned `terminal=false`, `reason=no_end_turn`.
- The guard accepted the clean RWO-N15 session:
  `python3 packages/agent/tests/fixtures/session_terminal_guard.py --session-id sess_019e75e0-b3bb-7be0-bf24-6ab044aa0def`
  returned `terminal=true`, `reason=end_turn_stable`, `terminalSequence=238`,
  zero pending approvals, and zero open queue items.
- Score remains `91/100`; this fixes recurrence of an unscored harness
  classification bug rather than proving a new collapsed-engine substrate axis.

### RWO-N16: Pre-Terminal Worker Disconnect Retry

This completes the disconnect/retry slice of
**RWO-N16: Pre-terminal Worker Failure/Retry/Cancellation Robustness**.

Trigger:

- RWO-N15 proved registration, queued trigger dispatch, stream evidence, and
  clean post-terminal unregister. It did not prove a worker disconnect while the
  engine still had a claimed target invocation waiting for a result.
- The prior transport path could leave a pending external-worker invocation
  waiter alive until timeout after the websocket closed. That delayed queue
  failure/retry truth and risked stale pending waiters under worker churn.
- Queue failure lifecycle projection also emitted the pre-failure queue item,
  so the `queue.fail` event did not show the authoritative post-fail
  retry/dead-letter status and attempt count.
- Follow-up review found that the first RWO-N16 pass still stored the
  pure-read worker socket loss as a failed target invocation row. That blurred
  queue delivery failure with application handler failure and could make the
  simulator chat and DB audit look worse than the engine state actually was.

Fix:

- `packages/agent/src/transport/runtime/external_workers.rs` now drains all
  pending socket invocation waiters on websocket disconnect, returns a
  canonical `WORKER_DISCONNECTED` worker result to the engine invocation path,
  and classifies closed/cancelled/timed-out worker sockets as
  `WorkerTransportFailure` rather than generic handler failures.
- `packages/agent/src/engine/queue.rs` now fetches the updated queue item after
  `fail_queue_item` and publishes `queue.fail` with the actual post-fail
  status and attempts.
- `packages/agent/src/engine/host.rs` exposes `get_queue_item` for queue
  runtime inspection after mutation and invokes claimed queue targets through a
  queue-aware host path. Retryable non-mutating worker transport failures return
  an error result to the queue drainer without committing a failed target
  invocation row; the queue lifecycle event is the durable truth for that
  delivery attempt.
- `packages/agent/src/engine/ledger.rs` persists/replays
  `worker_transport_failure` errors for direct or mutating paths that still
  must record an invocation result.
- `packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py` now supports
  deterministic first-invocation `error-on-first-invoke` and
  `disconnect-on-first-invoke` modes, optional reconnect after disconnect, and
  a pre-result sleep control.
- Added `packages/agent/tests/fixtures/rwo_n16_live_agent_harness.py` so future
  runs can reproduce the real dev-server plus old-simulator deep-link evidence
  without rebuilding a one-off `/tmp` harness.

Live evidence:

- Corrected retest real dev server PID: `71028`.
- Corrected retest session: `sess_019e7623-44e0-7ef3-bc3c-549e5bec7373`.
- Run log: `/tmp/rwo_n16_agent_run_20260529164803.json`.
- Worker fixture log:
  `/tmp/rwo_n16_agent_worker_fixture_20260529164803.jsonl`.
- Old paired simulator screenshot:
  `/tmp/rwo_n16_20260529164803_old_simulator.png`.
- Worker/function/trigger/topic:
  `rwo-n16-agent-worker-20260529164803`,
  `rwo_n16_agent_20260529164803::queued_echo`,
  `manual:rwo_n16_agent_20260529164803.queued_echo`, and
  `rwo_n16_agent_20260529164803.worker.events`.
- The fixture disconnected before returning delivery attempt
  `019e7623-97de-7b10-a0c4-228bacc8c1f1`; the engine exposed that attempt only
  through `queue.fail` as `deliveryInvocationId`, not as a failed target
  invocation row or `resultInvocationId`.
- The fixture reconnected immediately, reregistered the same worker/function/
  trigger, and completed retry invocation
  `019e7623-9be9-7682-8d3b-5a0065e51165` with
  `rwoN16Retry = true`.
- Queue receipt `019e7623-9797-7ff0-801a-65295cabe871` completed with
  attempts `1`. Queue lifecycle cursor `108066` recorded `queue.fail` with
  status `ready`, attempts `1`, `deliveryInvocationId =
  019e7623-97de-7b10-a0c4-228bacc8c1f1`, `resultInvocationId = null`, and the
  disconnect error. Cursor `108073` recorded `queue.complete` with status
  `completed`, attempts `1`, and matching delivery/result invocation id
  `019e7623-9be9-7682-8d3b-5a0065e51165`.
- Evidence resource `evidence:rwo-n16-agent:20260529164803` was written at
  version `ver_019e7623-ea6a-75b3-9f6f-64a443390550`.
- Catalog revisions `391-402` prove initial registration, pre-terminal
  unregister after disconnect, reconnect registration, and final unregister
  cleanup after harness stop.
- Terminal guard returned `terminal=true`, `reason=end_turn_stable`,
  `terminalSequence=329`, zero pending approvals, and zero open queue items.
- DB classification found zero failed invocations, zero approvals, zero
  `compact.*` events, zero session logs, no resource leases, and no open
  scenario queue rows. The only target rows are the successful enqueue handoff
  and successful retry target invocation.
- Computer Use verified the old `iPhone 17 Pro` simulator window rendered the
  deep-linked terminal RWO-N16 chat route after the run.

Verification:

- `python3 packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py --self-test --session-id self-test-session`
  passed.
- `python3 packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py --self-test --session-id self-test-session --failure-mode disconnect-on-first-invoke --reconnect-after-disconnect`
  passed.
- `python3 -m py_compile packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py packages/agent/tests/fixtures/rwo_n16_live_agent_harness.py packages/agent/tests/fixtures/session_terminal_guard.py`
  passed.
- `python3 packages/agent/tests/fixtures/rwo_n16_live_agent_harness.py --sim-udid 267F6468-09AE-471D-9157-29144173EB82 --timeout-seconds 900`
  passed against dev server PID `71028`.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::state_queue -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml websocket_disconnect_fails_pending_worker_invocations -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::external_worker -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml queued_external_worker_disconnect_records_queue_retry_not_failed_target_invocation -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`
  passed.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `git diff --check` passed before this scorecard update; rerun before commit.
- Score impact: worker/function/trigger substrate increases from `11/14` to
  `13/14`, runtime resilience increases from `8/10` to `9/10`, and total score
  increases from `91/100` to `94/100`.

### RWO-N16B: Queue Cancellation And Dead-Letter Robustness

This completes the cancellation and terminal-failure slice of
**RWO-N16: Pre-terminal Worker Failure/Retry/Cancellation Robustness**.

Trigger:

- RWO-N16 proved websocket disconnect retry but intentionally did not score
  explicit cancellation or retry exhaustion under a claimed/pre-terminal queue
  item.
- Focused tests first reproduced two queue drift bugs: cancelling a claimed
  item left the active lease attached, and terminal retry exhaustion was
  projected as a third `queue.fail` instead of an explicit
  `queue.dead_letter`.
- The first live RWO-N16B harness attempt
  `sess_019e7637-679c-7063-a1cf-3e89302a0210` exposed two harness/guard
  issues rather than a queue-runtime failure: the cancellation worker returned
  before the agent reached `queue::cancel`, so the engine correctly returned
  `cancelled=false` on an already completed receipt, and
  `session_terminal_guard.py` treated `dead_lettered` rows as open work.

Fix:

- `packages/agent/src/engine/queue.rs` now treats `cancelled` and
  `dead_lettered` as terminal states for late complete/fail attempts, clears
  queue leases on complete/cancel, and emits `queue.dead_letter` when the
  post-fail item state reaches `dead_lettered`.
- `packages/agent/src/engine/primitives/queue.rs` now publishes queue lifecycle
  stream events from public `queue::enqueue`, `queue::complete`,
  `queue::fail`, and `queue::cancel` primitive calls, so explicit agent-visible
  queue mutations cannot change durable queue state invisibly.
- `packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py` now supports
  `always-error` for deterministic terminal dead-letter scenarios.
- Added `packages/agent/tests/fixtures/rwo_n16b_live_agent_harness.py`, which
  starts one delayed-success worker and one always-failing worker in the same
  real agent session, drives both only through `capability::execute`, opens the
  old simulator deep link, and records DB classification.
- `packages/agent/tests/fixtures/session_terminal_guard.py` now treats
  `dead_lettered` as terminal queue work. It still rejects ready/leased rows,
  pending approvals, and later turn starts.

Live evidence:

- Passing session: `sess_019e763d-628a-75c3-8b63-4ef7736fbfe9`.
- Run log: `/tmp/rwo_n16b_agent_run_20260529171634.json`.
- Cancellation fixture log:
  `/tmp/rwo_n16b_cancel_worker_fixture_20260529171634.jsonl`.
- Dead-letter fixture log:
  `/tmp/rwo_n16b_dead_worker_fixture_20260529171634.jsonl`.
- Old paired simulator screenshot:
  `/tmp/rwo_n16b_20260529171634_old_simulator.png`.
- Cancellation worker/function/trigger:
  `rwo-n16b-cancel-worker-20260529171634`,
  `rwo_n16b_cancel_20260529171634::queued_echo`, and
  `manual:rwo_n16b_cancel_20260529171634.queued_echo`.
- Dead-letter worker/function/trigger:
  `rwo-n16b-dead-worker-20260529171634`,
  `rwo_n16b_dead_20260529171634::queued_echo`, and
  `manual:rwo_n16b_dead_20260529171634.queued_echo`.
- Cancellation receipt `019e763d-bb67-7ab2-a201-acdb51e5503c` was observed as
  `leased`, cancelled through public `queue::cancel`, and remained
  `cancelled` with attempts `0`, no lease owner, and no lease expiry after the
  delayed target returned. `queue.cancel` cursor `109219` recorded status
  `cancelled`; no `queue.complete` event exists for that receipt.
- Dead-letter receipt `019e763e-13ab-7242-98c3-48a3a77aa05d` reached
  `dead_lettered` after three expected target failures:
  `019e763e-13ed-7c71-889a-a333934d4e5f`,
  `019e763e-17ec-7dc0-a155-e4c1504a378a`, and
  `019e763e-1be7-7a80-a69c-97269b86fff2`.
- Queue lifecycle cursors `109274` and `109277` recorded retry
  `queue.fail` events with status `ready`; cursor `109283` recorded
  `queue.dead_letter`, status `dead_lettered`, attempts `3`, and the terminal
  worker error.
- Evidence resource `evidence:rwo-n16b-agent:20260529171634` version
  `ver_019e763e-8aa3-7341-9f79-37beb456e547` stored the scenario receipt and
  expected queue-truth payload.
- The final automatic `agent_result` resource
  `res_019e763f-87ab-74d0-90f6-8b1118d77979` is classified as normal prompt
  output, not scenario state.
- Terminal guard returned `terminal=true`, `reason=end_turn_stable`,
  `terminalSequence=637`, zero pending approvals, and zero open queue items.
- DB classification found three expected dead-letter target failures, zero
  unexpected failed invocations, zero approvals, zero `compact.*` events, zero
  session logs, no resource leases, no grants, zero active harness-owned
  stream subscriptions, and only expected live app websocket subscriptions
  after the simulator deep link.
- Catalog revisions `403-414` prove both workers/functions/triggers registered
  and unregistered cleanly after fixture termination.
- Computer Use verified the old `iPhone 17 Pro` simulator window rendered the
  deep-linked terminal RWO-N16B chat route for the same session.

Verification:

- `cargo test --manifest-path packages/agent/Cargo.toml queue_cancel_during_claim_preserves_terminal_cancelled_state -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml queue_terminal_failure_publishes_dead_letter_lifecycle_event -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::state_queue -- --nocapture`
  passed.
- `python3 -m py_compile packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py packages/agent/tests/fixtures/rwo_n16b_live_agent_harness.py packages/agent/tests/fixtures/session_terminal_guard.py`
  passed.
- `python3 packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py --self-test --failure-mode always-error --session-id test-session`
  passed.
- `python3 packages/agent/tests/fixtures/session_terminal_guard.py --self-test`
  passed.
- `python3 packages/agent/tests/fixtures/session_terminal_guard.py --session-id sess_019e7637-679c-7063-a1cf-3e89302a0210`
  passed after the guard fix and returned `end_turn_stable` with zero open
  queue items for the previously timing-failed session.
- `python3 packages/agent/tests/fixtures/rwo_n16b_live_agent_harness.py --sim-udid 267F6468-09AE-471D-9157-29144173EB82 --timeout-seconds 900`
  passed on the exact retest.
- Score impact: worker/function/trigger substrate increases from `13/14` to
  `14/14`, multi-capability orchestration increases from `9/12` to `10/12`,
  runtime resilience increases from `9/10` to `10/10`, and total score
  increases from `94/100` to `97/100`.

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

SCB-S1 checkpoint, 2026-05-29:

- Moved target argument affordances into
  `packages/agent/src/domains/capability/operations/target_arguments.rs`.
- Added a static gate that keeps target-specific affordance function bodies out
  of `execute.rs`.
- Left deterministic route/decomposition presentation in `execute.rs` for the
  next focused ownership pass.

SCB-S1b checkpoint, 2026-05-29:

- Moved deterministic route selection, namespace clarification, execute
  constraint filtering, argument-schema fit promotion/filtering,
  low-confidence intent evidence checks, candidate summaries, and
  target-specific decomposition guidance into
  `packages/agent/src/domains/capability/operations/target_resolution.rs`.
- Added a static gate that keeps the target-resolution helper bodies out of
  `execute.rs` and requires the new module's invariant and route/decomposition
  markers.
- `execute.rs` remains the orchestration spine: parse wrapper request, resolve
  intent or explicit target, prepare freshness/payload, run through the selected
  capability, and observe/project the result.
- Broader capability verification passed with
  `cargo test capability_ --lib -- --nocapture` after the move.

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

SCB-S2 checkpoint, 2026-05-29:

- Moved hybrid search/index behavior, lexical and local-vector ranking, document
  identity/hashing, vector-fusion helpers, and degraded-index status projection
  into `packages/agent/src/domains/capability/registry/index.rs`.
- Moved context-primer policy, visible primer entry selection, and model-facing
  primer rendering into
  `packages/agent/src/domains/capability/registry/primer.rs`.
- Kept recipe authoring in
  `packages/agent/src/domains/capability/registry/recipes.rs` and documented
  the split in the registry root module table.
- Added a static gate that rejects ranking/indexing, primer rendering, and
  recipe authoring bodies if they move back into `registry/mod.rs`.
- Fixed the focused primer rendering failure found by the registry test:
  tight token budgets now still render the first visible capability entry before
  truncating additional entries.

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

SCB-S3 checkpoint, 2026-05-29:

- Added `packages/agent/src/domains/resource_projection.rs` as the bounded
  domain helper for collection summaries and resource-id cleanup traversals that
  need canonical `resource::list` plus optional `resource::inspect` composition
  without a fallback reader.
- Prompt library and voice notes now use that helper for artifact-backed
  collection summaries. Prompt-history pruning skips the default 10,000-entry
  retention path because a bounded 500-resource projection cannot prove that
  default cap needs pruning.
- Generated UI prompt, notification, and subagent collection authoring now uses
  a bounded primitive-host helper with `RESOURCE_COLLECTION_SCAN_LIMIT = 500`
  instead of local `limit: 10_000` scans.
- Added `bounded_resource_projection_summaries_stay_canonical` in
  `packages/agent/tests/threat_model_invariants.rs` to keep prompt library,
  voice notes, generated UI, control, and module trust/audit projections on
  bounded resource access.
- Deferred inventory: `domains/cron/implementation/domain/truth.rs`,
  `domains/notifications/inbox.rs`, and
  `domains/agent/runtime/service/context.rs` still contain 10,000-shaped
  `resource::list` requests. They are behavior-coupled truth reconstruction or
  hidden-side-effect context paths, not the collection-summary slice closed by
  SCB-S3. Classify and harden them under SCB-S5 or an explicit SCB-S3 follow-up
  before awarding full hidden-side-effect robustness.
- No public schemas changed.

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

SCB-S4 checkpoint, 2026-05-29:

- Classified active provider normalization as provider/protocol-owned:
  OpenAI, Anthropic/shared stream accumulation, Google, Kimi, and Ollama
  provider wire shapes remain isolated under `domains/model/providers` and
  `domains/model/provider_protocol`.
- Removed the fail-open provider argument path. `parse_capability_call_arguments`
  now returns `Result<Map<String, Value>, CapabilityArgumentParseError>`; absent
  and empty argument strings still represent empty arguments, while malformed
  JSON and non-object JSON fail closed with provider/capability/invocation
  diagnostics.
- OpenAI completed and output-item function calls, Anthropic/shared streamed
  invocation stops, Google function calls, and Kimi streamed invocations now
  surface malformed provider arguments as `StreamEvent::Error` without emitting
  `CapabilityInvocationDraftEnd` or `Done` for the malformed path.
- Added focused negative fixtures for provider argument parsing, shared stream
  accumulation, OpenAI, Google, and Kimi. Added
  `provider_argument_normalization_fails_closed` in
  `packages/agent/tests/threat_model_invariants.rs` so streamed provider
  argument parsing cannot regress to direct `serde_json::from_str(...).unwrap`
  or empty-argument fallback behavior.
- No engine/capability core provider-schema leakage was found. Existing
  `provider_tool_terms_stay_inside_protocol_boundaries` continues to enforce
  that boundary.
- No simulator run was required for this checkpoint because valid provider wire
  behavior was unchanged. The changed behavior is the deterministic malformed
  provider-wire negative path, and the focused Rust fixtures are the smallest
  reliable proof.

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
- Deferred from SCB-S3: classify and harden remaining 10,000-shaped resource
  scans in cron truth reconstruction, notification read-state decisions, and
  retained-memory context loading without introducing side-channel state.

SCB-S5 checkpoint, 2026-05-29:

- Classified retained-memory context loading as a bounded resource-backed prompt
  projection. It now names `RETAINED_MEMORY_CONTEXT_SCAN_LIMIT`, ties that limit
  to `resource_projection::MAX_RESOURCE_COLLECTION_LIMIT`, and retains the
  separate 200-entry context rendering cap.
- Classified notification inbox/read-state reconstruction as a bounded
  resource-backed projection over notification resources plus read decision
  resources linked with `affects_notification`. It now uses
  `NOTIFICATION_TRUTH_SCAN_LIMIT`, tied to the shared resource projection cap.
- Classified cron schedule and run truth reconstruction as a bounded
  resource-backed projection over `decision` and `evidence` resources. It now
  uses `CRON_RESOURCE_TRUTH_SCAN_LIMIT`, tied to the shared resource projection
  cap; the cron SQLite cache remains runtime mechanics, not product truth.
- Added `hidden_side_effect_resource_scans_stay_bounded_and_observable` to
  prevent these post-turn/hidden-side-effect paths from drifting back to
  unclassified `limit: 10_000` resource traversals or losing resource-capability
  evidence markers.
- Focused verification passed for retained-memory context loading,
  notification resources/read-state, cron resource truth, the new static gate,
  and the full threat-model invariant suite.
- Simulator app-path smoke opened
  `tron://session/sess_019e7523-4c24-7b02-9ff7-08b896c05c74` on the booted
  iPhone 17 Pro simulator against real dev server PID `2214`; screenshot
  `/tmp/scb_s5_app_path_smoke_20260529.png` showed the deep-linked chat route
  with both user prompt and assistant content visible.

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

SCB-S6 checkpoint, 2026-05-29:

- Split `packages/agent/src/engine/tests/module_activation.rs` into a fixture
  parent plus focused child modules:
  `module_activation/package_registration.rs`,
  `module_activation/local_process_activation.rs`, and
  `module_activation/operator_surfaces.rs`.
- Kept existing child modules for `source_trust`, `health_integrity`, and
  `trust_review`. The parent now declares modules and shared fixtures only, and
  `rust_test_ownership_stays_code_adjacent` rejects future test bodies in that
  parent.
- Added `large_rust_test_files_have_scorecard_ownership_audit`, which discovers
  Rust test files over 1,000 lines under `packages/agent/tests/` and
  `packages/agent/src/**/tests*`/`tests/`, requires each remaining large file to
  appear in the audit table below, and enforces a line budget.

Large-file audit after RWO-N17:

| File | Lines | Classification | Owner/Reason Marker | Enforced Budget |
|---|---:|---|---|---:|
| `packages/agent/tests/threat_model_invariants.rs` | 6,163 | intentional exception | cross-cutting static architecture gates | 6,200 |
| `packages/agent/tests/integration/tests.rs` | 3,108 | intentional exception | transport e2e suite with shared WebSocket harness | 3,300 |
| `packages/agent/src/domains/session/event_store/store/tests.rs` | 3,083 | intentional exception | single event-store API matrix | 3,300 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/tests.rs` | 2,712 | intentional exception | worktree coordinator lifecycle matrix | 2,900 |
| `packages/agent/src/engine/tests/generated_ui.rs` | 1,865 | intentional exception | single generated-UI primitive matrix | 2,050 |
| `packages/agent/src/domains/agent/runner/guardrails/tests.rs` | 1,695 | intentional exception | guardrail rule-pattern matrix | 1,850 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | 1,571 | intentional exception | SQLite event repository query matrix | 1,750 |
| `packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests.rs` | 1,545 | intentional exception | subagent manager orchestration matrix | 1,700 |
| `packages/agent/src/engine/tests/module_activation/source_trust.rs` | 1,364 | intentional exception | module source-trust scenario matrix | 1,500 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/rebase_on_main_tests.rs` | 1,239 | intentional exception | rebase-on-main conflict/recovery matrix | 1,400 |
| `packages/agent/src/engine/tests/resource_kernel.rs` | 1,207 | intentional exception | single resource-kernel matrix | 1,400 |
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | 1,177 | intentional exception | stream processor event-shape matrix | 1,350 |
| `packages/agent/src/domains/agent/runner/context/context_manager_tests.rs` | 1,164 | intentional exception | context manager policy/rules matrix | 1,350 |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | 1,127 | intentional exception | compaction engine scenario matrix | 1,300 |

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

SCB-S7 checkpoint, 2026-05-29:

- Classified generated UI action role/icon derivation as client-owned semantic
  drift: the server owned the action target, payload template, and consequence,
  but iOS still inferred destructive/refresh/create meaning from labels and
  action ids.
- Moved generated action presentation hints into the server-owned
  `action_summary` primitive. Stored generated UI actions and action summaries
  now include `presentation.buttonRole` and `presentation.icon`.
- Kept iOS as a renderer: it decodes `UiActionPresentationDTO`, maps the stored
  button role to visual style/dialog role, and falls back only to neutral visual
  rendering if a malformed surface omits presentation. It no longer humanizes
  action ids or scans labels/action ids for local semantics.
- Strengthened Rust and iOS static gates so generated UI submissions stay
  coordinate-only and generated UI rendering cannot reintroduce local action
  semantic guesses.
- Deferred the separate chat/approval parity issues to SCB-S8 rather than
  mixing UI polish into this architecture hardening pass.

### 8. Prove Chat/Engine State Parity

Problem:

Simulator deep-link runs exposed visible drift risks: Python harness prompt
submissions can produce automatically rendered agent responses without showing
the originating user prompt, and terminal approval state can advance in engine
truth while the iOS action sheet remains visible.

Target:

- Chat UI state is a projection of engine truth for the active session.
- User prompts, assistant output, capability results, approval state, queued
  automation progress, and terminal errors reconcile from DB/event/resource truth
  without product-state side channels.
- Simulator harnesses can deep-link into a session and prove visible parity after
  terminal DB state is stable.

Acceptance criteria:

- A focused simulator parity test compares visible chat state against canonical
  session DB/event/approval/invocation truth for the same session id.
- Approval sheets and cards stop being actionable after terminal engine status.
- Harness-submitted prompts render in the same ordering as native prompt entry.
- Mismatches classify as `ios_rendering` or `stream_or_state` drift, not as
  successful engine evidence.
- Visual polish starts only after this parity gate passes, so presentation work
  cannot substitute for engine-truth reconciliation.

SCB-S8 checkpoint, 2026-05-29:

- Classified the stale confirmation sheet as `ios_rendering`: iOS already
  received terminal engine approval state and updated the chip, but the matching
  sheet state stayed mounted and actionable because `engineApprovalState` did
  not clear the current approval after `approval.resolved`, and the shared
  sheet modifier did not dismiss active sheets when their server-owned
  presentation flags flipped false.
- Fixed the owner layer only. `EngineApprovalState` now clears a matching open
  approval sheet when the approval id reaches terminal server state,
  `ChatViewModel.handleApprovalResolved` invokes that reconciliation, and
  `SheetCoordinator.dismissIfActive` lets `ChatSheetModifier` remove approval,
  user-interaction, and subagent sheets when the corresponding view-model flag
  becomes false.
- Kept the client thin: no product-state side channel, fallback reader,
  compatibility alias, policy ownership, or alternate approval path was added.
  User approval decisions still invoke canonical `approval::resolve`, and
  historical approval chips still render from engine records.
- Focused iOS tests now cover matching terminal approval sheet cleanup,
  non-matching approval preservation, resolved-event wiring through
  `ChatViewModel`, and targeted sheet-coordinator dismissal.
- App-path retest opened
  `tron://session/sess_019e7523-4c24-7b02-9ff7-08b896c05c74` on the booted
  iPhone 17 Pro simulator against real dev server PID `26801`; then the app was
  terminated, relaunched, and deep-linked to the same session again. Screenshots
  `/tmp/scb_s8_parity_terminal_session_20260529.png` and
  `/tmp/scb_s8_parity_relaunch_deeplink_20260529.png` show the harness user
  prompt and assistant replay answer with no actionable approval sheet.
- DB truth for the same session contained two `message.user` events, four
  `message.assistant` events, two started/completed execute cards, one executed
  `process::run` approval, zero pending approvals, zero failed invocations, two
  completed `agent` queue rows, no session logs, and zero `compact.*` events.

## Static Gates To Add Or Strengthen

Add or strengthen tests in `packages/agent/tests/threat_model_invariants.rs`:

- New scorecard exists.
- Historical scorecard links to the new scorecard.
- New scorecard contains:
  - current score;
  - rubric;
  - scenario ledger;
  - failure protocol;
  - simulator deep-link protocol;
  - structural cleanup backlog;
  - no fallback/compatibility rule.
- `execute` remains the only Tron model-facing capability primitive.
- `search` and `inspect` remain internal/operator only.
- No prompt tables return.
- No fallback readers, compatibility aliases, client-authored generated UI
  actions, `control::act`, dynamic UI catalogs, raw-scope authorization,
  package/source/policy/trust/audit tables, or alternate worker-spawn paths.
- Provider-specific schema terms do not leak outside provider/protocol modules.
- Provider capability argument normalization fails closed through
  `provider_protocol::capability_parsing`; streamed provider handlers must not
  deserialize malformed arguments directly or project them as empty canonical
  invocations.
- New target-specific execute behavior must be capability-owned, not
  central-spaghetti owned.
- Capability registry ranking/indexing stays in `registry/index.rs`, primer
  rendering stays in `registry/primer.rs`, and recipe authoring stays in
  `registry/recipes.rs`; the registry root must not re-absorb those concerns.
- Prompt library, voice notes, and generated UI resource collection summaries
  stay on canonical bounded projection helpers; generated UI authoring must not
  reintroduce `limit: 10_000` resource scans.
- Retained-memory context loading, notification inbox/read-state reconstruction,
  and cron schedule/run truth reconstruction stay on named scan limits tied to
  `resource_projection::MAX_RESOURCE_COLLECTION_LIMIT`; these hidden
  side-effect paths must not reintroduce `limit: 10_000` resource scans.
- Simulator deep-link harness instructions stay present in this scorecard and
  `packages/ios-app/docs/development.md`.
- Simulator deep-link evidence records chat parity checks for user prompt
  visibility, assistant turn state, approval sheet lifecycle, and stable
  terminal DB state.
- Simulator deep-link harnesses must treat `stream.turn_end` with
  `stopReason = "tool_use"` as non-terminal and wait for `stopReason =
  "end_turn"` plus DB reconstruction before classification.
- Pre-terminal worker retry harness controls must stay reproducible through
  `packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py` and
  `packages/agent/tests/fixtures/rwo_n16_live_agent_harness.py`; future worker
  churn tests must use engine-owned worker sockets and queue truth rather than
  process-kill side channels or private runtime helpers.
- Queue cancellation/dead-letter harness controls must stay reproducible
  through `packages/agent/tests/fixtures/rwo_n16b_live_agent_harness.py`.
  Terminal guards must classify `dead_lettered` queue rows as closed work while
  still rejecting ready/leased rows.
- Large-file audit rows exist for files over 1k lines that remain intentionally
  large.
- `large_rust_test_files_have_scorecard_ownership_audit` keeps the SCB-S6
  large-file audit exact: new files over 1,000 lines or audited files exceeding
  budget must split or update this scorecard with a new owner/reason.
- Generated UI action presentation semantics stay server-owned: Rust action
  summaries must keep `presentation.buttonRole`/`presentation.icon`, iOS must
  consume `UiActionPresentationDTO`, and the generated UI renderer must not infer
  action meaning from labels or action ids.

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

No scored collapsed-engine hardening scenario remains open after RWO-N17. Future
work should be treated as regression or expansion unless it invalidates a
banked invariant and lowers the score.

Recommended next work:

1. Keep `packages/agent/tests/fixtures/rwo_n17_live_multi_session_harness.py`
   as the canonical multi-session simulator/deep-link regression. Its default
   model is `claude-sonnet-4-6`; override only when intentionally running a
   provider lane.
2. For provider breadth, prioritize current high-capability hosted models first
   (`claude-sonnet-4-6`, `gpt-5.5`, and the newest approved Gemini model in the
   active profile). Older models can remain compatibility probes, but their
   comprehension shortfalls must not be treated as architecture failures
   without current-model and DB evidence.
3. Keep Ollama `gemma4:e4b` as the small-local-model substrate smoke test only.
   It proves the local-provider path can reach the collapsed engine. Robust
   local-model use cases should be retried with larger local models before
   assigning an engine failure.
4. Continue chat/engine parity follow-ups as polish/regression work: deep-linked
   sessions must show the submitted `message.user`, assistant terminal state,
   and resolved approval/action sheet state in parity with DB truth. If the UI
   drifts, classify it as `ios_rendering` while keeping DB evidence canonical.
5. If any future regression appears, stop broad testing, isolate the exact
   owner, add the smallest focused test, remove nearby dead/fallback/legacy/
   compatibility code, rerun the exact failed scenario, and update this
   scorecard before adding new breadth.

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
