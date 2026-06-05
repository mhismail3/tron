# Worker-First Tron Product Scorecard

Created: **2026-06-05**
Initial score: **0/100**
Current score: **22/100**
Status: **active; JARVIS-2 and JARVIS-4 server checkpoint passed; JARVIS-0 visual baseline and JARVIS-8 guardrail UX remain open**
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
| JARVIS-1 | Primitive collapse | 8 | pending | Product docs define one user model: orchestrator plus workers. Capabilities, packs, subagents, generated UI, and helper processes are represented as worker abilities or worker artifacts. Static gate blocks primary UI strings for `Substrate`, `Primer`, `Bindings`, and `Engine Console`. | Not started. | Start after JARVIS-0 baseline evidence is complete or when vocabulary migrations begin. |
| JARVIS-2 | Default autonomy policy | 12 | passed_after_fix | Server setting defaults to no human approval prompts. Approval-required metadata becomes audited auto-decision records in default mode. Testing mode restores interactive approval prompts. Guardrail blocks remain fail-closed. Rust tests prove auto-run, testing prompt, and hard block paths. | Added `settings.agent.autonomy.approvalPromptMode` with default `disabled`, explicit `testing`, default profile TOML, iOS decode/update/state parity, default auto-decision execution, testing-mode prompt preservation, schema/policy preflight hard-block behavior, idempotent replay proof, and focused Rust/iOS tests. Fix during proof: terminal auto-decision replays are no-side-effect replays; denied and failed records do not retry child work. | Closed for server policy. JARVIS-8 still owns the full Guardrails settings UX and simulator screenshots. |
| JARVIS-3 | Worker-first orchestration | 10 | pending | Main agent prompt, primer, and self-extend guidance default to delegating to workers for non-trivial work. Subagents and spawned helper capabilities share a product `Worker` projection while preserving distinct server primitives. Integration proof shows fan-out workers completing a local task without user approvals. | Not started. | Depends on JARVIS-2 policy and the worker projection vocabulary from JARVIS-4. |
| JARVIS-4 | Work snapshot API | 10 | passed_after_fix | `agent::work_snapshot` or equivalent server-owned projection powers the default dashboard without iOS stitching together registry/audit/control/policy details. DTO tests cover active work, idle state, worker health, recent milestones, blocked guardrails, and audit refs. | Added `agent::work_snapshot` contract/handler/projection over settings, catalog workers/functions, invocation ledger, approval audit records, catalog revision, active work, guardrails, milestones, and audit refs. Fix during proof: default worker cards filter infrastructure/system workers so idle snapshots are clean and product-facing. Focused `work_snapshot` tests pass. | Closed for server DTO. JARVIS-5 owns the iOS Work dashboard replacement. |
| JARVIS-5 | iOS Work dashboard | 12 | pending | The Engine dashboard is replaced by a minimal Work view: autonomy status, active work timeline, worker cards, recent results, guardrail alerts, and one Audit entry point. No grids of raw catalog/plugin/implementation/binding counts in the default path. iPhone/iPad screenshots prove the surface is understandable at a glance. | Not started. | Requires JARVIS-4 DTO and iOS navigation rename/removal work. |
| JARVIS-6 | Chat noise reduction | 8 | pending | Chat collapses repetitive capability chips into high-signal work events. Default details show what happened, why, worker, status, and result. Raw request/result/schema/trace/policy data moves behind Audit Details. Tests cover streamed and reconstructed sessions. | Not started. | Build from the Work event projection instead of client-side capability internals. |
| JARVIS-7 | Worker/detail sheets | 8 | pending | Worker detail sheets show abilities, recent work, health, trust, generated controls, and audit history. Existing capability detail sheets become audit-backed action details, not the primary mental model. Layout tests and screenshots cover running, success, failure, and blocked guardrail states. | Not started. | Depends on worker snapshot/detail DTOs. |
| JARVIS-8 | Guardrails and settings UX | 7 | running | Settings expose Autonomy Mode and Guardrails plainly. Default copy says Tron runs independently on this Mac; testing prompts are explicitly for QA. iOS settings parity tests cover the new server fields. | Partial: Agent settings now expose Autonomy Mode with Independent/Testing prompt mode, default copy says Tron runs independently on this Mac, iOS parity tests cover decode/state/update/page grouping, and a simulator-hosted render screenshot proves the Agent settings page is nonblank with the autonomy copy visible. | Remaining: add plain Guardrails UX and capture paired-server action checks before awarding points. |
| JARVIS-9 | Docs and examples | 6 | pending | User/operator docs and local example packs are rewritten around workers and autonomous work loops. Productization docs stop selling registry/capability internals as the main product surface. No remote package discovery, push, merge, release, or deploy paths are introduced. | Not started. | Update docs alongside the implementation rows they describe. |
| JARVIS-10 | Cleanup and static gates | 7 | pending | Dead primary Engine Console code is deleted or renamed to audit-only ownership. Threat-model invariants enforce no primary UI dependence on registry/policy/primer jargon, no client-owned approval truth, and no default approval prompts. LOC gates stay under budget. | Not started. | Add absence gates only after the replacement surfaces exist. |
| JARVIS-11 | Soak, visual QA, and closeout | 7 | pending | End-to-end Tron session runs for an extended local workflow with workers, self-extension, tests, docs, generated UI, and audit refs without manual approvals. Evidence includes commands, DB rows, invocation/resource IDs, logs, screenshots, and final clean queue/approval/worker state. | Not started. | Requires all prior rows to pass and the final audit to prove no open rows remain. |

## Baseline Audit

Baseline source audit started on 2026-06-05 from branch
`next/modular-capability-engine` with a clean worktree before edits.

- Current primary iOS source still includes `NavigationMode.engine` and Engine
  Console views. This contradicts the final product target and is the main
  JARVIS-5/JARVIS-10 migration surface.
- README still describes a native iOS Engine Console harness over server-owned
  substrate. That is accurate for the baseline but must change when the Work
  surface becomes primary.
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

Continue with JARVIS-1/JARVIS-3 vocabulary and orchestration collapse while
keeping JARVIS-0 visual baseline and JARVIS-8 Guardrails UX open. The next iOS
checkpoint should add plain Guardrails settings, use paired-server simulator
action checks when the surface is interactive, and remove primary-path Engine
Console/capability clutter rather than renaming it.
