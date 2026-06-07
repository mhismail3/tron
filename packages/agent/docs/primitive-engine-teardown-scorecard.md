# Primitive Engine Teardown Scorecard

Created: 2026-06-06

Initial score: **0/100**

Current score: **92/100**

Status: **active execution artifact**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`primitive-engine-teardown-evidence-manifest.md`](primitive-engine-teardown-evidence-manifest.md)

Scope:
- Strip Tron to the smallest useful primitive agent harness: process
  bootstrap, provider/auth configuration, durable session state, event/ledger
  truth, one model-facing `execute` tool, a minimal agent-owned state
  workspace, and the iOS shell needed to send prompts and render dynamic
  runtime output.
- Remove hard-coded first-party capabilities, capability recipes, policies,
  worker packs, skills, rules, product dashboards, and typed UI modes unless a
  row proves they are true loop infrastructure that the agent cannot bootstrap
  itself.
- Keep hardened engine lessons where they are primitives: idempotent
  invocation records, traceable events, resource/version truth, provider
  accounting, first-class trace records, crash recovery, and
  simulator-verified UI behavior.
- Treat this as a clean-break branch. There are no users and no compatibility
  obligations.

There are no users and no compatibility obligations.

Out of scope:
- Designing the full self-adapting agent after the teardown. This scorecard
  stops when the branch cannot delete more hard-coded harness surface without
  breaking the primitive loop.
- Production migration, old database compatibility, release packaging, app
  store behavior, or preserving old capability names.
- Rebuilding every removed feature as agent-authored runtime state. A successor
  scorecard owns the self-construction phase after this branch proves the bare
  harness.

## Summary

This campaign turns the current worker-first product branch into a bare-metal
agent-engine experiment. The durable truth owner remains the Rust server and its
engine/session/event stores. The iOS app becomes a transport and rendering shell.
Everything else must justify itself against the primitive model below. If a
feature is a product capability, a policy opinion, a fixed workflow, a typed
dashboard, a hard-coded skill, a capability recipe, a compatibility bridge, or a
shortcut around the loop, it is deleted or moved behind the agent-owned state
workspace.

## Non-Negotiable Direction

- No backward compatibility: no aliases for retired capabilities, no old DTO
  adapters, no migrations for old product surfaces, no soft-deprecated paths,
  and no compatibility fallbacks.
- No prompt-expanded toolbox: the model receives one initial tool, `execute`.
- No hard-coded product skills or rules: the only static instruction is the
  agent soul.
- No fixed iOS product modes: iOS keeps connection, prompt input, session
  navigation, settings needed to reach the server/provider, and generic dynamic
  rendering.
- No hidden policy plane: safety, trust, and access constraints are either
  hard infrastructure invariants or agent-owned state. Middle-layer product
  policies are deletion candidates.
- No runtime approval prompt plane: the host defines an upfront authority
  envelope; work outside that envelope is blocked and recorded as evidence
  instead of asking for permission mid-loop.
- No invisible agent authorship: from the primitive loop onward, agent actions
  that produce durable changes must create trace records the agent and humans
  can inspect.
- No "planned" pass credit: every point requires code, docs, tests, and
  evidence.

## Primitive And Plane Budget

Retain a component only when it fits one of these primitive classes:

| Class | Retention test | Current likely examples |
|-------|----------------|-------------------------|
| Boot infrastructure | Required before the first agent turn can run. | `main_runtime`, health endpoint, profile/home resolution, provider/auth loading, database open/migration for the retained stores. |
| Provider loop | Required to call a model and feed back tool results. | Provider clients, model routing, token usage/cost capture, streaming assembly, turn retry/recovery. |
| Session truth | Required to preserve user prompts, assistant output, state reconstruction, and crash-safe turn progress. | Session event store, message/event DTOs needed by the loop, queue entries for in-flight turns. |
| Execution primitive | Required to let the agent act and later create its own capabilities. | One `execute` host primitive with trace, idempotency, resource refs, output capture, and bounded host access. |
| Agent-owned state workspace | Required so the agent can store its soul, memory, learned rules, generated capabilities, and UI descriptions as data. | A minimal resource/file state root plus typed refs in events. |
| Observability | Required to prove what happened and debug the loop. | Invocation ledger, trace ids, agent trace records, compact logs, failure records, simulator screenshots. |
| Client shell | Required for the user to talk to the loop and inspect generic runtime output. | iOS WebSocket client, prompt composer, message list, generic surface renderer, minimal settings/onboarding. |

Delete or prove primitive status for these current planes:

| Plane | Default action | Why |
|-------|----------------|-----|
| Domain capability catalog (`filesystem`, `git`, `worktree`, `browser`, `display`, `notifications`, `plan`, `process`, `program`, `prompt_library`, `cron`, `voice_notes`, `transcription`, `mcp`, `sandbox`, `self_extension`, `module`, and similar) | Delete as registered first-party capabilities. | They are product/tool opinions. The agent should build or install equivalents as state/capabilities after bootstrap. |
| Capability registry, recipes, bindings, conformance, vector search, policy profiles | Delete or collapse into minimal execute observation. | This is a hard-coded harness for a catalog that should no longer exist upfront. |
| Rules, skills, hooks, guardrails, core rules, worker guide, prompt library | Delete as built-in context planes. | The soul plus agent-owned state should produce future behavior. |
| Approval prompts, trust tiers, worker pack policy, source trust workflows | Delete unless reduced to host integrity invariants. | There are no users and no compatibility obligations; policy should not be product-coded. |
| iOS Work, Audit Details, Source Control, Prompt Library, Voice Notes, Skills, Agent Control, typed capability clients | Delete from primary branch UI unless converted into generic dynamic rendering. | Fixed product surfaces encode hard-coded capabilities. |
| README/product docs for removed features | Rewrite or delete. | Documentation must describe only runnable branch behavior. |

Infrastructure invariants that may remain hard-coded:

- transport authentication and local profile secrets handling;
- database/event/ledger integrity;
- provider API framing and token/cost accounting;
- process lifecycle cleanup and crash recovery;
- resource version/idempotency semantics;
- iOS connection safety, pairing, local cache integrity, and accessibility
  basics.

These are not product rules. They protect the loop itself.

## First-Class Traceability Primitive

Traceability is part of the bare loop, not a later observability feature. The
branch should follow the useful primitives from the Agent Trace RFC
(`https://agent-trace.dev/`): trace data is a data specification rather than a
product surface, storage is implementation-defined, records are human- and
agent-readable, and records link contributors, conversations, VCS revisions,
files, line ranges, content hashes, tools, and extensible metadata.

Tron's primitive trace record must be durable and queryable by the agent. At
minimum, the retained loop must be able to link:

- session id, turn id, invocation id, parent/root invocation id, and trace id;
- provider, model id, tool/runtime name, and authority envelope snapshot;
- VCS revision when a workspace is versioned;
- files/resources touched, before/after content hashes, optional line ranges,
  and blob refs for larger payloads;
- prompt/result/error/log refs needed to reconstruct why the change happened;
- status, timestamps, and implementation-specific metadata.

The iOS shell may render trace references generically, but Rust storage and the
`execute` observation path own the truth so the agent can inspect its own
history during self-improvement.

## Target Bare Loop

1. User sends a prompt through iOS or another `/engine` client.
2. Server appends the user event and reconstructs minimal context.
3. Context contains the agent soul, current session history, compact
   agent-owned state summary, and nothing else unless the agent created it.
4. Provider receives one tool: `execute`.
5. The model calls `execute` to act, inspect/write its own state, create or run
   self-authored helpers, and record outputs.
6. The engine records invocation, first-class trace records, resources, state
   updates, logs, and assistant-visible observations.
7. The loop repeats until terminal assistant output or explicit blocked state.
8. iOS renders chat plus generic dynamic surfaces emitted as runtime data.

## Agent Soul Seed

This scorecard does not design the whole self-adapting agent, but it must leave
one seed instruction in place. The seed should be short enough to audit and
stable enough to act as activation energy:

- learn from the environment;
- preserve useful memory as agent-owned state;
- improve your own tools and rules when doing so helps the user's objective;
- prefer small tested changes;
- keep evidence for what you changed and why;
- recover from failure by inspecting state and revising the approach;
- ask the user only when blocked by missing intent; unavailable authority is
  recorded as blocked evidence inside the upfront authority envelope.

The soul is not a toolbox, recipe pack, policy profile, or product guide. Rows
PET-4 and PET-6 must fail if it grows into those shapes.

## Operating Loop

1. Pick the highest-value pending row.
2. Audit the current code paths and mark every touched subsystem as retain,
   delete, or successor.
3. Write or strengthen the smallest covering absence/behavior test first.
4. Delete hard-coded planes aggressively.
5. Restore the primitive loop using the fewest retained abstractions.
6. Remove fallback, compatibility, legacy, and dead code around the edit.
7. Run focused tests, then simulator UI proof for every iOS-facing row.
8. Update this scorecard and the evidence manifest with exact commands, return
   codes, artifacts, open loops, and the next row.
9. Commit each coherent checkpoint.
10. Stop only when all rows are passed and an adversarial final audit finds no
    removable non-primitive plane.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence contract | Residual risk | Checkpoint |
|----|------|--------|--------|-------|-------------------|---------------|------------|
| PET-0 | Branch, baseline, and plan formalization | 5 | passed_after_fix | docs_or_scorecard | New branch exists from the worker-first checkpoint; scorecard, evidence manifest, README link, static plan gate, and current branch status are recorded. | None for planning. PET-1 owns the first source inventory before behavior deletion. | this checkpoint |
| PET-1 | Primitive taxonomy and deletion inventory | 8 | passed_after_fix | engine_architecture | Added [`primitive-engine-teardown-inventory.md`](primitive-engine-teardown-inventory.md), a source-audited deletion map covering every current Rust domain, primitive worker, runner context plane, first-party managed skill, agent doc, iOS source/view root, and settings surface as retain/delete/successor. The covering invariant was added first and failed red on the missing inventory before the artifact was created. | Classification mistakes can preserve product code; PET-2 through PET-10 must execute against this map and PET-11 must adversarially revisit every `retain` and `successor` classification. | PET-1 inventory checkpoint |
| PET-2 | Server domain registration teardown | 12 | passed_after_fix | engine_architecture | `domains::registration` narrowed startup to loop infrastructure domains and model providers; later PET-10 cleanup physically deleted the public `context::*` capability plane as well. The red startup-catalog test proved retired namespaces were still registered; the green rerun proves product/tool domains and deleted `agent::*` product routes are absent while `capability::execute` remains. README capability docs were rewritten for the branch surface. | Historical checkpoint source still referenced some product modules until later rows removed them. PET-11 owns only retained/successor re-audit, not known registered product namespaces. | PET-2/PET-3 backend checkpoint |
| PET-3 | Single execute primitive | 12 | passed_after_fix | engine_architecture | Provider tool export now exposes exactly one function named `execute`, never hosted `tool_search`/`defer_loading`. `capability::execute` uses direct primitive operations (`observe`, `state_get`, `state_set`, `state_list`, `file_read`, `file_write`, `process_run`) instead of registry recipes, plugin/binding/conformance/policy tables, vector search, or target routing. Direct engine proof covers `observe`; run-loop proof shows a mock provider calls `execute`, receives the observation as a capability result in the next turn context, and continues to final text. | Startup/server context still wires product managers and dead source modules. PET-6/PET-7/PET-10 own deleting those planes; they are not model-facing tools after this row. | PET-2/PET-3 backend checkpoint |
| PET-4 | Soul and agent-owned state workspace | 10 | passed_after_fix | agent_runtime | Context assembly now contains the static agent soul, compact agent-owned state, environment metadata, and session history/results. Provider `Context` exposes `agent_state_context` and no longer carries hard-coded rules, memory docs, skill index/context, hooks, job results, dynamic rules, or capability primers. `execute` state tests prove agent-owned state persists and is projected back into context. | Self-adapting behavior beyond state persistence is successor work. Startup still exposes old registries/managers outside the prompt context and remains PET-6/PET-10 work. | PET-4 context/soul checkpoint |
| PET-5 | Session, event, ledger, and resource collapse | 8 | passed_after_fix | storage | Fresh session storage now starts from a single primitive `v001_schema.sql` with only `schema_version`, `workspaces`, `sessions`, `events`, `blobs`, and `logs`; product tables and old product follow-up migrations were deleted. Session rows no longer carry origin/source/profile/worktree/subagent spawn fields. Typed session events collapsed from the old product catalog to 23 loop-owned variants, and the prompt queue/config/rules/preload event write paths were removed rather than aliased. README schema/event docs describe only the retained fresh-storage surface. | Dead unregistered source and cfg-test fixtures still mention old product events/tables; PET-10 owns physical deletion and warning cleanup. iOS still expects some old reconstruction fields until PET-8. Old local databases remain disposable. | PET-5 storage/event checkpoint |
| PET-6 | Rules, skills, hooks, guardrails, approvals, and policy deletion | 8 | passed_after_fix | agent_runtime | Prompt-loop internals, startup/server context, retained domain registration context, retained contracts, and engine registration policy no longer carry rules, skills, hooks, guardrails, subagent managers, process/job/output managers, profile-derived execute policy metadata, approval-required contract metadata, or high-risk approval exceptions. Removed root settings for hooks/skills/prompt library/MCP/guardrails; obsolete guardrail and prompt-library settings are rejected rather than accepted silently. Dev, CI, release, Mac bundle, backup, restore, and rollback scripts now build/package the single `tron` helper binary only. | PET-10 owns physical deletion of unregistered product source and warning cleanup; PET-7 owns remaining self-authored substrate teardown. | PET-6 startup/policy checkpoint |
| PET-7 | Self-authored worker/capability substrate | 8 | passed_after_fix | engine_architecture | Deleted the first-party module worker, worker package/config/activation resource kinds, module runtime jobs, worker protocol guide template, module activation tests, capability registry/recipe/conformance source, and generated UI/control action projections for module lifecycles. The retained worker protocol is host infrastructure only, and model-facing docs now describe `execute` as the only primitive surface. Static gates prove `module::*`, worker-pack launch guide strings, and retired capability registry phrases are absent from the retained source/docs checked by PET-7. | Historical checkpoint compile still reported warning backlog; PET-10 later cleared it. PET-11 owns only the final retained-worker-substrate audit. | PET-7 worker/capability substrate checkpoint |
| PET-8 | iOS primitive shell | 10 | passed_after_fix | ios | Deleted the fixed Work/Audit Details/Source Control/Prompt Library/Voice Notes/Skills/Agent Control/Subagents/Worktree/interactive approval product surfaces, related state objects, stale protocol files, product clients, plugins, orphan tests, and stale docs from the iOS primary tree. The retained app keeps the chat/session/input/onboarding/settings shell, local event reconstruction, generic capability evidence, and `GeneratedRuntimeSurfaceView`. SourceGuard now rejects the deleted product roots, deleted approval plane, and deleted clients, and clean iPhone/iPad simulator screenshots prove the empty shell is readable with no modal overlap. | Some retained domain clients/views for non-PET-8 surfaces still need PET-10/PET-11 adversarial audit against the final one-capability model. Dynamic UI sophistication after the shell is successor work. | PET-8 iOS primitive shell checkpoint |
| PET-9 | Documentation and managed asset rewrite | 5 | passed_after_fix | docs_or_scorecard | Active branch docs now describe only the primitive loop or deletion evidence: `packages/agent/docs/` contains only the active teardown scorecard, evidence manifest, and inventory; `packages/agent/skills/` is physically absent; relay/APNs docs and stale product scorecards/guides are deleted; README, iOS docs, Mac docs, and project guidance were rewritten around the retained shell, traceability, and deleted planes. | PET-11 still audits retained code-level surfaces and any doc mention that claims runnable behavior. Historical deleted feature names may remain only in absence gates or teardown evidence. | PET-9/PET-10 context-relay-typed-client cleanup checkpoint |
| PET-10 | Absence gates, traceability gates, and dead-code cleanup | 6 | passed_after_fix | test_harness | First-class traceability slice is implemented: `execute` writes durable Agent Trace-style `trace_records`, exposes `trace_list`/`trace_get`, and static/integration gates prove invocation/session/model/authority/file/content-hash linkage. Follow-up absence work physically deleted the public `context::*` capability plane, capability-policy settings, push relay/APNs/device-token path, stale typed iOS domain clients, notification inbox/delivery surfaces, workspace validation/file browser, and the remaining Rust warning wrappers. Fresh Rust checks now pass with no `cargo check` warnings, full `cargo test --lib` passes, and iOS SourceGuard passes after project regeneration. | PET-11 owns the adversarial "cannot remove more" pass over retained/successor surfaces such as retained generic iOS capability rendering and remaining DTOs; no known PET-10 warning/test blocker remains. | PET-9/PET-10 context-relay-typed-client cleanup checkpoint |
| PET-11 | End-to-end closeout and "cannot remove more" audit | 8 | running | test_harness | Interim adversarial passes deleted retained hosted OpenAI `tool_search`/`computer_use` DTO and stream support, catalog support flags, stale iOS capability catalog DTOs/renderers, Mac Screen Recording/Accessibility onboarding gates, stale capability identity/rendering vocabulary, server resolved-catalog identity projections, iOS draft skill/spell residue, the iOS/Rust user-interaction pause/submit-answer plane, unreferenced iOS repo/task DTOs, fixed iOS process and SessionTree projections, the top-level Rust `capability_support` abstraction, the product update-check surface, the legacy prompt `images` API, fixed `system::get_diagnostics`, the generic `LogStore` query abstraction, inert observability payload-capture settings, the one-case iOS diagnostics settings section, server-owned dynamic UI target authoring/catalog/refresh surfaces, queue/trigger/prompt pre-execution catalog pins, public invoke/promote expected function revision tokens, and the stale function revision error path. Retained capability events and runtime stream adapters now carry only primitive name, operation, trace/root ids, theme color, presentation hints, status/result/duration, and runtime details. Dynamic UI is now a schema-versioned runtime resource renderer and action-submission recorder, not a target/function authoring framework. Queue, trigger, and prompt envelopes no longer store target revisions, expected function revisions, target function ids, or catalog revisions before execution; public `engine::invoke`, `engine::promote`, external worker invocation, and the capability executor no longer require expected function revisions before execution; current function/catalog revisions remain only in host integrity checks and invocation/trace evidence. Draft persistence stores only text, attachment metadata, and update time; prompt media flows through unified attachments; session fork lineage remains only in session/event truth; provider primitive surface resolution lives in the agent runner; retained logs are bounded evidence storage and are agent-visible only through `execute.log_recent` beside `trace_list`/`trace_get`. Fresh Rust/OpenAI, iOS SourceGuard, iOS capability/event reconstruction, iOS generated-UI DTO/renderer, iOS draft repository/store, Mac permission/wizard/menu/path, server event/projection, prompt-plane absence, engine-protocol model/settings, process-dashboard absence, unified-attachment, session lineage/reconstruction, moved primitive-surface, product-update absence, primitive trace/log execution, diagnostics/logging absence, dynamic-surface absence, queue/trigger/prompt envelope absence, and engine invocation/transport expected-revision absence tests pass for these slices. Final row still requires fresh server run, provider-loop fixture, DB/event/ledger/trace inspection, iPhone/iPad screenshots, final `git diff --check`, and a full retained-surface audit. | Remaining PET-11 audit targets include public engine/meta/control/transport catalog readouts that are not true primitive resource/version metadata. Successor scorecard starts only after this row passes. | PET-11 invocation transport flattening checkpoint |

Total weight: **100**

## Required Checkpoints

1. PET-0: commit the plan on `codex/primitive-engine-teardown`. **Closed in
   this checkpoint.**
2. PET-1: commit the inventory and deletion map before deleting code. **Closed
   in the PET-1 inventory checkpoint.**
3. PET-2/PET-3: commit the first backend slice where startup catalog and the
   single-tool provider loop agree. **Closed in the PET-2/PET-3 backend
   checkpoint.**
4. PET-4/PET-6: commit the context/soul/state slice only after rules, skills,
   hooks, and guardrails are actually absent from the model context. **PET-4
   is closed in the context/soul checkpoint; PET-6 is closed in the
   startup/policy checkpoint.**
5. PET-5/PET-7: PET-5 is closed in the storage/event checkpoint after fresh DB
   proof and no old product migration requirements remain. PET-7 is closed in
   the worker/capability substrate checkpoint.
6. PET-8: commit the iOS shell only after simulator screenshots and action-time
   checks on iPhone and iPad.
7. PET-9/PET-10: commit docs, static gates, and dead-source cleanup after
   warning-free Rust proof and focused iOS absence proof.
8. PET-11: commit final closeout evidence only after the adversarial "what
   else can be removed" audit and end-to-end primitive-loop proof.

## Evidence Requirements

Every passed row must update
`primitive-engine-teardown-evidence-manifest.md` with:

- exact command and exit code;
- branch, commit hash, and diff summary;
- server mode, database path, port, PID, and cleanup behavior where relevant;
- test names and result summaries;
- catalog/tool export before/after when capabilities are removed;
- DB schema/table/resource/event evidence for storage rows;
- trace record evidence linking provider/model turn, invocation, VCS/resource
  evidence, content hashes, and the agent-visible query path;
- iOS simulator name, UDID, bundle id, launch/openurl return code, and
  screenshot paths for UI rows;
- failure owner and root cause for every red step;
- exact rerun proof after the fix;
- residual risk and successor owner.

## Static Gates To Add During Execution

- `primitive_engine_teardown_plan_stays_formalized`: this plan and README link
  stay present until closeout.
- `provider_surface_exports_only_execute`: model-facing tool export has exactly
  one function.
- `deleted_first_party_capabilities_are_absent`: retired namespaces are not
  registered or routable.
- `context_has_soul_not_rules_or_skills`: context assembly excludes hard-coded
  rules, skills, hooks, guardrails, and worker guides.
- `ios_primary_shell_has_no_fixed_product_modes`: iOS primary navigation has no
  fixed Work/Audit Details/Source Control/Prompt Library/Voice Notes/Skills
  product modes.
- `no_legacy_fallback_compatibility_paths`: touched Rust/Swift/docs contain no
  compatibility shims for removed branch behavior.
- `agent_trace_records_are_first_class`: durable trace records link agent
  actions to invocation/session/model/VCS/resource evidence and are queryable
  by the agent.
- `prompt_media_uses_unified_attachment_primitive`: prompt media and documents
  flow through one attachment primitive; legacy image-only prompt fields are
  absent from the Rust/iOS transport path.
- `primitive_loop_end_to_end`: fresh bare session can call a model fixture,
  execute, persist state, reconstruct, and render on iOS.

## Open Decisions For Execution

These are execution decisions, not blockers for this plan:

- Whether bootstrap `execute` should expose raw process/filesystem primitives
  directly, or only a smaller in-process helper API that can write and run
  agent-authored code.
- Whether the soul is stored as a checked-in seed file, a seeded resource in the
  agent workspace, or both with one canonical source of truth.

## Resolved Execution Decisions

- The dynamic renderer now consumes the retained `ui_surface` resource schema
  as a schema-versioned runtime resource. Server-owned target authoring,
  catalog DTOs, action target templates, refresh policy, redaction policy, and
  UI bindings were deleted rather than moved behind compatibility adapters.

## Closeout Criteria

The score is 100/100 only when:

- every row is `passed` or `passed_after_fix`;
- the current score is 100/100 and status is completed;
- no row has pending, blocked, or stale active text;
- the evidence manifest names all final commands, return codes, screenshots,
  DB evidence, and commits;
- README and area docs describe only the bare branch behavior;
- fresh DB startup creates no removed product tables or capability registry
  truth;
- provider tool export contains only `execute`;
- trace records are durable, linked to invocation/session/model/VCS/resource
  evidence, and queryable by the agent;
- iOS simulator proof shows a minimal shell on iPhone and iPad;
- an adversarial source audit finds no hard-coded product capability, policy,
  rule, skill, worker pack, fixed UI mode, fallback, or compatibility layer
  that can be deleted without breaking the primitive loop.

## Successor Scorecard

After PET-11 passes, create a separate self-adapting-agent scorecard for:

- agent-authored capability creation and promotion;
- learned rule/memory systems;
- generated workers;
- generated UI sophistication;
- long-running autonomous improvement loops;
- optional human review surfaces that are generated by the agent rather than
  hard-coded by the harness.
