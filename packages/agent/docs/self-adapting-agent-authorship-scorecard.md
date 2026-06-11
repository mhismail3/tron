# Self-Adapting Agent Authorship Scorecard

Branch: `codex/primitive-engine-teardown`
Baseline commit: `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7`
Status: **complete**
Current score: **100/100**

This successor scorecard closes the first Self-Adapting Agent Authorship (SAA)
slice after PET, SACB, and ODA. The slice proves self-adaptation through the
existing primitive substrate: the provider still sees only `execute`, while
durable authorship happens through `execute` operations, scoped state, typed
resources, trace/replay evidence, workspace files, generic UI surfaces, and
explicit host promotion boundaries.

Invariant target: `../tests/self_adapting_agent_authorship_invariants.rs`.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAA-0 | Harness | 7 | passed_after_fix | Added this scorecard, evidence manifest, source inventory, TSV inventory, focused invariant target, README links, and local/GitHub closeout wiring. |
| SAA-1 | Source Inventory | 9 | passed_after_fix | Inventory covers provider context, `execute`, state, typed resources, patch/materialized files, generated UI, trace/replay, worker protocol, iOS/Mac runtime rendering, scripts, docs, and static gates. |
| SAA-2 | Self-Authorship Contract | 10 | passed_after_fix | `execute` remains the only provider-visible primitive; resource authorship is an operation inside that primitive and static guards reject catalog routing, hidden prompt planes, managed skills, product routes, and additional provider tools. |
| SAA-3 | Durable Memory/Rule Substrate | 12 | passed_after_fix | Added `agent_memory` and `agent_rule` built-in typed resource kinds with status, scope, provenance, evidence refs, supersession, revocation, lifecycle states, and relation guards. |
| SAA-4 | Goal/Evidence/Decision Loop | 10 | passed_after_fix | Fixture creates goal, claim, evidence, decision, memory, and rule resources through `execute`, links them by resource refs, inspects the result, and verifies trace evidence without private payload markers. |
| SAA-5 | Patch Proposal And Materialization | 10 | passed_after_fix | Fixture creates `patch_proposal` and `materialized_file` resources with hashes and trace refs before workspace mutation, then links them as promotion-ready artifacts. |
| SAA-6 | Generated UI Authorship | 9 | passed_after_fix | Fixture creates a schema-validated `ui_surface`; static gates prove iOS renders generic `UiSurfaceDTO` payloads through `GeneratedRuntimeSurfaceView` without feature-name routing. |
| SAA-7 | Promotion Boundary | 10 | passed_after_fix | Runtime grants include only `execute`, internal resource/state operations, and SAA resource kinds; they exclude `engine::promote`, worker registration, trigger creation, and live worker authority. |
| SAA-8 | Autonomous Loop Safety | 8 | passed_after_fix | Static gates reject boot-time autonomous mutation loops, production deploy paths, restored managed skills, and auto-launch worker-pack paths in retained Rust/Swift source. |
| SAA-9 | Observability/Replay | 7 | passed_after_fix | SAA execute resource operations create trace records with stable operation names; inventory records replay/trace/log evidence and residual live-scale risks. |
| SAA-10 | Closeout | 8 | passed_after_fix | Scorecard is complete at 100/100; evidence rows cover every checkpoint; stale wording is rejected; focused and closeout verification are recorded in the evidence manifest. |

## Boundary Statement

SAA does not reintroduce a fixed skills directory, a provider-visible tool beyond
`execute`, a checked-in worker-pack lifecycle, a product panel, automatic
deployment, outbound analytics, or a boot-time self-mutation loop. Generated
workers remain promotion-ready artifacts in this slice. A live worker still
requires explicit host infrastructure, a valid worker token/grant, and existing
engine promotion/worker boundaries.

## Closeout Notes

The only new model-facing vocabulary is additional `operation` values inside the
existing `execute` schema. All durable SAA objects are typed resources or
scoped state with resource refs, trace ids, and evidence links. The remaining
live-scale risk is operator policy: future slices that promote generated
artifacts into live capabilities must add explicit decision/evidence checks at
the promotion entrypoint rather than treating SAA resource authorship as
permission to launch.
