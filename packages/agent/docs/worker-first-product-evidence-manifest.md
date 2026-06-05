# Worker-First Tron Product Evidence Manifest

Created: **2026-06-05**
Scorecard: [`worker-first-product-scorecard.md`](worker-first-product-scorecard.md)
Current score: **0/100**

This manifest records evidence for the active worker-first product scorecard.
Update it at each checkpoint with commands, return codes, exact source refs,
screenshots, runtime ids, open loops, and the next test.

## Boundaries

- Remote package discovery, push, merge, release, deploy, notarization, and
  production rollout are outside this campaign.
- iOS, Mac, and CLI must remain thin clients. They do not own approval truth,
  policy, source trust, generated action targets, model routing, worker routing,
  or capability binding.
- Engine substrate remains server-owned and audit-complete. The campaign moves
  that substrate out of the primary product mental model; it does not delete
  audit evidence.
- Default autonomy must be no-prompt unless a fail-closed guardrail blocks the
  work or the explicit QA/testing setting is enabled.

## Evidence Index

| Row | Status | Evidence |
|---|---|---|
| JARVIS-0 | running | Scorecard, manifest, README links, and static guard added. Source baseline is recorded below. Visual baseline screenshots remain open. |
| JARVIS-1 | pending | Not started. |
| JARVIS-2 | pending | Not started. |
| JARVIS-3 | pending | Not started. |
| JARVIS-4 | pending | Not started. |
| JARVIS-5 | pending | Not started. |
| JARVIS-6 | pending | Not started. |
| JARVIS-7 | pending | Not started. |
| JARVIS-8 | pending | Not started. |
| JARVIS-9 | pending | Not started. |
| JARVIS-10 | pending | Not started. |
| JARVIS-11 | pending | Not started. |

## JARVIS-0 Evidence

### Inputs

- User supplied an external plan file titled `Worker-First Tron Product
  Scorecard`.
- The plan requires a product model centered on Work, Workers, Worker Packs,
  Autonomy, Guardrails, and Audit.

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `git status --short --branch` | 0 | Confirmed branch `next/modular-capability-engine` was clean before edits. |
| `sed -n '1,260p' README.md` | 0 | Audited root architecture and living-doc map. |
| `sed -n '1,260p' packages/ios-app/docs/architecture.md` | 0 | Audited current iOS thin-client, Engine Console, capability-native chat, and approval baseline docs. |
| `sed -n '1,260p' '/Users/.../PLAN (1).md'` | 0 | Read the external worker-first plan. |
| `rg -n "Engine Console\\|NavigationMode\\.engine\\|NavigationMode\\|capability\\|approval\\|work_snapshot\\|Autonomy\\|Worker" packages/agent/src packages/agent/tests packages/ios-app/Sources packages/ios-app/Tests packages/agent/docs README.md` | 0 | Located current product vocabulary, Engine Console, approval, worker, and missing work snapshot surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test worker_first_product_scorecard_invariants -- --nocapture` | 101 | Red proof: failed because the worker-first scorecard docs did not exist yet. |

### Source Evidence

- [`README.md`](../../../README.md): current root product wording still says
  the iOS app provides a chat and Engine Console harness over server-owned
  substrate.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md):
  current iOS architecture lists `NavigationMode.engine`, Engine Console
  projections, live substrate search suggestions, workers/policies/traces/
  primer/program-runs/substrate sections, and server-owned approval resolving.
- [`packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift`](../../ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift):
  current primary technical inspection surface.
- [`packages/ios-app/Sources/ViewModels/State/EngineConsoleState.swift`](../../ios-app/Sources/ViewModels/State/EngineConsoleState.swift):
  current iOS state stitching across status, registry, catalog, control, audit,
  generated UI, and program runs.
- [`packages/ios-app/Sources/Services/Network/Clients/ApprovalClient.swift`](../../ios-app/Sources/Services/Network/Clients/ApprovalClient.swift):
  current thin client for server-owned approval decisions.
- [`packages/ios-app/Sources/Services/Network/Clients/CapabilityClient.swift`](../../ios-app/Sources/Services/Network/Clients/CapabilityClient.swift):
  current Engine Console client surface for capability/admin/catalog/control
  functions.
- [`packages/agent/docs/tron-productization-scorecard.md`](tron-productization-scorecard.md):
  completed predecessor proving the capability/pack-centered baseline at
  100/100.

### Findings

- Current primary iOS source still includes `NavigationMode.engine` and Engine
  Console views.
- Current docs still present Engine Console as a top-level mode and mention
  substrate, primer, bindings, traces, policies, and raw registry details in
  product-adjacent contexts.
- Current approval UX remains prompt-capable and server-owned. The new default
  policy must preserve audit rows while removing default user prompts.
- No `agent::work_snapshot` projection exists in the audited source scan.
- The implementation should reuse the proven engine substrate rather than
  rebuild worker, generated UI, pack, approval, or resource primitives.

### Open Loops

- Visual baseline screenshots remain open.
- JARVIS-0 cannot receive points until current Engine Console, approval prompt,
  worker/capability-heavy UI, and source references are captured together.
- The next implementation checkpoint should start with red server tests for the
  autonomy setting and `agent::work_snapshot` DTO.
