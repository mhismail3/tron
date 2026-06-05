# Worker-First Tron Product Scorecard

Created: **2026-06-05**
Initial score: **0/100**
Current score: **73/100**
Status: **active; JARVIS-2, JARVIS-3, JARVIS-4, JARVIS-5, JARVIS-6, JARVIS-7, JARVIS-8, and JARVIS-9 passed; JARVIS-0 visual baseline, JARVIS-1 primary UI vocabulary gates, JARVIS-10 cleanup gates, and JARVIS-11 soak remain open**
Evidence manifest: [`worker-first-product-evidence-manifest.md`](worker-first-product-evidence-manifest.md)

## Scope

North star: Tron presents itself as a worker-led autonomous agent product. The
default user model is Work, Workers, Worker Packs, Autonomy, Guardrails, and
Audit. Capabilities, plugins, bindings, policies, traces, schema digests,
primer inputs, raw ids, grants, and substrate counts remain server-owned audit
substrate, not the primary product surface.

This is a successor campaign to the completed self-extending productization
scorecard. That earlier campaign proved the engine substrate and local
self-extension loop. This campaign changes the product language and default
interaction model from capability-led inspection to worker-led work
orchestration.

## Product Contracts

- Default autonomy means run-unless-blocked, not ask-first.
- Interactive approval prompts are disabled by default and exist only in
  explicit testing/QA mode.
- Guardrail blocks remain fail-closed and visible.
- Approval records remain audit evidence even when default mode uses audited
  auto-decisions instead of user prompts.
- The server owns the Work snapshot projection. iOS must not stitch together
  product truth from registry, catalog, audit, control, policy, and approval
  internals.
- Product vocabulary is **Work**, **Workers**, **Worker Packs**,
  **Autonomy**, **Guardrails**, and **Audit**.
- Technical vocabulary such as substrate, primer, bindings, schema digests,
  traces, grants, raw ids, and policy internals is audit-only.
- Remote package discovery, push, merge, release, deploy, and production
  rollout stay out of scope.

## Evidence Contracts

Each row must record:

- Commands and return codes.
- Exact source files, tests, docs, fixtures, database rows, resource refs,
  invocation ids, catalog revisions, screenshots, logs, or soak summaries as
  relevant.
- A status of `pending`, `running`, `passed`, `passed_after_fix`, `blocked`,
  or `failed_unfixed`.
- Open loops and the next test before moving to the next row.

Stop on failed evidence. Fix the owning layer, remove stale fallback, legacy,
dead, compatibility, or primary-UI internal jargon nearby, rerun the failed
scenario, update this scorecard plus the evidence manifest, and commit a
coherent checkpoint.

## Scorecard

| ID | Area | Weight | Status | Acceptance Evidence | Current Evidence | Open Loops |
|---|---:|---:|---|---|---|---|
| JARVIS-0 | Formalize scorecard and baseline | 5 | running | New scorecard + evidence manifest exist, README links them, current Engine Console/approval/workers/UI baseline is audited with screenshots and source references. | Added this active scorecard, companion manifest, README living-doc links, and `worker_first_product_scorecard_invariants`. Source baseline is recorded in the manifest. | Visual baseline screenshots are still open and block JARVIS-0 points. |
| JARVIS-1 | Primitive collapse | 8 | running | Product docs define one user model: orchestrator plus workers. Capabilities, packs, subagents, generated UI, and helper processes are represented as worker abilities or worker artifacts. Static gate blocks primary UI strings for `Substrate`, `Primer`, `Bindings`, and `Engine Console`. | Partial: model-visible context now renders `# Worker Guide`, the provider context block label is `Worker Guide`, README context/worker-loop docs describe worker abilities and Audit rather than a product primer, user/operator/example docs now define one orchestrator-plus-workers model, and tests reject the retired `# Capability Primer`, harness wording, and old capability-led product docs. | Remaining: add broad primary UI static gates after Engine Console cleanup. |
| JARVIS-2 | Default autonomy policy | 12 | passed_after_fix | Server setting defaults to no human approval prompts. Approval-required metadata becomes audited auto-decision records in default mode. Testing mode restores interactive approval prompts. Guardrail blocks remain fail-closed. Rust tests prove auto-run, testing prompt, and hard block paths. | Added `settings.agent.autonomy.approvalPromptMode` with default `disabled`, explicit `testing`, default profile TOML, iOS decode/update/state parity, default auto-decision execution, testing-mode prompt preservation, schema/policy preflight hard-block behavior, idempotent replay proof, and focused Rust/iOS tests. Fix during proof: terminal auto-decision replays are no-side-effect replays; denied and failed records do not retry child work. | Closed for server policy. JARVIS-8 later closed the settings UX around this policy. |
| JARVIS-3 | Worker-first orchestration | 10 | passed_after_fix | Main agent prompt, primer, and self-extend guidance default to delegating to workers for non-trivial work. Subagents and spawned helper capabilities share a product `Worker` projection while preserving distinct server primitives. Integration proof shows fan-out workers completing a local task without user approvals. | The Worker Guide and `execute` schema instruct non-trivial work delegation to workers/subagents, worker-guide resource docs are server-owned, provider-context tests prove the guide reaches hosted/local providers, `agent::work_snapshot` projects live subagent jobs as `workerType=agent` Worker cards, and a real integration test fans out two session workers, invokes both through `execute`, verifies `agent::work_snapshot` projects both helper workers, and proves `approval::list` remains empty. | Closed for server orchestration/projection. JARVIS-5/JARVIS-7 own iOS presentation of these Worker cards and detail sheets. |
| JARVIS-4 | Work snapshot API | 10 | passed_after_fix | `agent::work_snapshot` or equivalent server-owned projection powers the default dashboard without iOS stitching together registry/audit/control/policy details. DTO tests cover active work, idle state, worker health, recent milestones, blocked guardrails, and audit refs. | Added `agent::work_snapshot` contract/handler/projection over settings, catalog workers/functions, invocation ledger, approval audit records, catalog revision, active work, guardrails, milestones, and audit refs. Fix during proof: default worker cards filter infrastructure/system workers so idle snapshots are clean and product-facing. Focused `work_snapshot` tests pass. | Closed for server DTO. JARVIS-5 later closed the iOS Work dashboard replacement. |
| JARVIS-5 | iOS Work dashboard | 12 | passed_after_fix | The Engine dashboard is replaced by a minimal Work view: autonomy status, active work timeline, worker cards, recent results, guardrail alerts, and one Audit entry point. No grids of raw catalog/plugin/implementation/binding counts in the default path. iPhone/iPad screenshots prove the surface is understandable at a glance. | Replaced top-level `NavigationMode.engine` with `NavigationMode.work`, added typed iOS `agent::work_snapshot` DTOs/client/state, added a minimal `WorkDashboardView`, and kept the technical console behind one Audit Details entry point. Focused simulator tests cover navigation, client read behavior, state load/error/blocked paths, source vocabulary gates, and iPhone/iPad rendered screenshots. Fix during visual proof: wide section icons clipped on iPhone, so the dashboard now uses simpler stable section symbols. | Closed for the default dashboard. JARVIS-7 later closed worker detail state-matrix screenshots; JARVIS-10 owns deleting or renaming remaining audit-only Engine Console ownership. |
| JARVIS-6 | Chat noise reduction | 8 | passed_after_fix | Chat collapses repetitive capability chips into high-signal work events. Default details show what happened, why, worker, status, and result. Raw request/result/schema/trace/policy data moves behind Audit Details. Tests cover streamed and reconstructed sessions. | Added a first-class Work projection for invocation chips/action details, renamed generic `execute` display to Work, removed the unused capability-row display branch, moved raw approval state into Audit Details, changed the detail header from Plugin to Worker, and replaced reflective detail-card glass with solid readable surfaces. Red/green simulator proof covers the missing `workRows` projection, streamed start handling, reconstructed sessions, source gates for raw audit-only sections, the solid detail surface guard, and an iPhone hosted render screenshot. | Closed for chat/action detail projection. JARVIS-7 later closed worker detail sheets and state-matrix screenshots. |
| JARVIS-7 | Worker/detail sheets | 8 | passed_after_fix | Worker detail sheets show abilities, recent work, health, trust, generated controls, and audit history. Existing capability detail sheets become audit-backed action details, not the primary mental model. Layout tests and screenshots cover running, success, failure, and blocked guardrail states. | Extended `agent::work_snapshot` workers with server-owned `trust` and `generatedControls`, added typed iOS DTO/state filtering for selected-worker guardrails, and expanded `WorkWorkerDetailSheet` with Health, Trust, Generated Controls, Guardrails, Abilities, Recent Work, and Audit History. Red/green Rust and simulator tests cover snapshot projection, decode/state behavior, source vocabulary, and hosted iPhone screenshots for running, success, failure, and blocked guardrail states. | Closed for worker/detail sheets. JARVIS-10 owns broad static cleanup gates, and JARVIS-11 owns final soak. |
| JARVIS-8 | Guardrails and settings UX | 7 | passed_after_fix | Settings expose Autonomy Mode and Guardrails plainly. Default copy says Tron runs independently on this Mac; testing prompts are explicitly for QA. iOS settings parity tests cover the new server fields. | Agent settings expose Autonomy Mode with Independent/Testing prompt mode and plain Guardrails rows for Run Unless Blocked and Audit Trail. Default copy says Tron runs independently on this Mac and testing prompts are for QA. iOS parity/layout tests cover decode, state update/reset, page grouping, guardrail copy, and simulator-hosted settings render proof. | Closed for settings UX. JARVIS-11 owns final paired-server soak/action proof. |
| JARVIS-9 | Docs and examples | 6 | passed_after_fix | User/operator docs and local example packs are rewritten around workers and autonomous work loops. Productization docs stop selling registry/capability internals as the main product surface. No remote package discovery, push, merge, release, or deploy paths are introduced. | Rewrote the self-extending user, operator, troubleshooting, and product notes around worker-led autonomous work, the Work dashboard, Worker Packs, Generated Controls, run-unless-blocked autonomy, and Audit Details. Rewrote local example pack docs as Worker Packs, updated the managed `self-extend` skill and synced it to `~/.tron/skills/self-extend/`, and added `worker_first_docs_and_examples_center_workers_and_local_work_loops` to reject retired capability-led docs and remote/release paths. | Closed for docs/examples. JARVIS-10 owns broad primary UI/static cleanup gates; JARVIS-11 owns final soak and visual closeout. |
| JARVIS-10 | Cleanup and static gates | 7 | pending | Dead primary Engine Console code is deleted or renamed to audit-only ownership. Threat-model invariants enforce no primary UI dependence on registry/policy/primer jargon, no client-owned approval truth, and no default approval prompts. LOC gates stay under budget. | Not started. | Add absence gates only after the replacement surfaces exist. |
| JARVIS-11 | Soak, visual QA, and closeout | 7 | pending | End-to-end Tron session runs for an extended local workflow with workers, self-extension, tests, docs, generated UI, and audit refs without manual approvals. Evidence includes commands, DB rows, invocation/resource IDs, logs, screenshots, and final clean queue/approval/worker state. | Not started. | Requires all prior rows to pass and the final audit to prove no open rows remain. |

## Baseline Audit

Baseline source audit started on 2026-06-05 from branch
`next/modular-capability-engine` with a clean worktree before edits.

- Baseline iOS source included `NavigationMode.engine` and Engine Console views
  as the primary technical surface. That contradicted the final product target
  and became the JARVIS-5/JARVIS-10 migration surface.
- Baseline README described a native iOS Engine Console harness over
  server-owned substrate. JARVIS-5 changed that primary product description to
  Work plus Audit Details.
- The current server product model is capability and pack centered. The
  completed productization scorecard proves this baseline; this successor must
  migrate visible product language to workers without deleting the engine
  substrate.
- Approval records and `approval::resolve` are server-owned today. JARVIS-2
  changes the default decision policy while preserving audit evidence.
- Generated UI, local packs, subagents, sandbox workers, and helper processes
  already exist as distinct engine primitives. JARVIS-1/JARVIS-3 must project
  them as workers or worker artifacts at the product layer.

## Next Test

Continue with JARVIS-10 cleanup and static gates for audit-only Engine Console
ownership and primary-path vocabulary. Keep JARVIS-0 visual-baseline debt,
JARVIS-1 primary-path vocabulary gates, and the JARVIS-11 paired-server soak
open until each has direct evidence.
