# iOS Self-Adapting Agent Cockpit Baseline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Current implementation branch:
`codex/ios-agent-cockpit-baseline-current`.
Baseline:
`6aa395fddf8ad8cca8f485c6a96fa0e78862e653`
(`Add self-updating worker runtime foundation`).

Scope quarantine: this slice adds an iOS-first cockpit for existing
self-updating worker lifecycle state, generic `ui_surface` runtime surfaces,
and neutral glass theme tokens. It does not add a new server primitive, provider
tool, public `/engine` transport route, hardcoded capability panel, production
deploy path, auth setting, database table, scheduler, MCP surface, skill
runtime, memory feature, or successor worker capability.

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| IOSAC-0 | Baseline and scope | 5 | passed | Branch, baseline commit, predecessor lineage, and no-feature-expansion quarantine are recorded. |
| IOSAC-1 | Lifecycle protocol bridge | 10 | passed | iOS decodes live catalog worker/function/trigger definitions with catalog decode degradation diagnostics and calls existing `catalog::watch_snapshot`, `resource::*`, and `worker_lifecycle::*` functions through a thin client/repository boundary. |
| IOSAC-2 | Cockpit projection model | 10 | passed | Pure projection state derives status, worker rows, function rows, trigger rows, package rows, activity, confirmations, and runtime surfaces from server facts without inventing local truth; refresh failures render as degraded while preserving the last good overview. |
| IOSAC-3 | Lifecycle actions and confirmations | 10 | passed | Install, enable, disable, launch, stop, and retire actions are state-gated, confirmation-backed, idempotent, and refresh from server state after mutation. |
| IOSAC-4 | Dynamic runtime surfaces | 10 | passed | The cockpit lists `ui_surface` resources, inspects current versions, decodes `UiSurfaceDTO`, and renders through `GeneratedRuntimeSurfaceView` with resource/version refs instead of a hardcoded panel. |
| IOSAC-5 | Diagnostics placement | 10 | passed | The cockpit remains a compact diagnostics surface opened from Servers -> Diagnostics -> Runtime Cockpit with standard liquid-glass sheet chrome and shared segmented tabs; passive chat placement is removed. |
| IOSAC-6 | Neutral glass visual baseline | 8 | passed | Theme tokens now resolve to neutral glass backgrounds with an emerald primary accent, separate semantic status colors, and tests for light/dark values. |
| IOSAC-7 | Focused Swift tests | 12 | passed | DTO, client, state-projection, view-model, generated UI renderer, and theme tests cover the new user-facing surface, including malformed catalog decode degradation and refresh-failure truthfulness. |
| IOSAC-8 | Static gates | 10 | passed | `ios_self_adapting_agent_cockpit_baseline_invariants` enforces artifacts, source contracts, dynamic-surface rendering, theme tokens, and CI/local target wiring. |
| IOSAC-9 | Docs and inventory | 8 | passed | README, iOS architecture docs, scorecard, evidence manifest, inventory docs/TSV, and primitive cleanup inventory rows describe current behavior. |
| IOSAC-10 | Closeout validation | 7 | passed | Full Rust CI, personal-info guard, XcodeGen drift, Swift focused/full checks, simulator validation, whitespace checks, ignored-file scan, and clean commit evidence are recorded. |

## Closure Verdict

iOS now has a first-class self-adapting agent cockpit baseline. The app exposes
the engine's live worker catalog, resource-backed worker package lifecycle,
approval/action state, activity stream, and agent-authored runtime surfaces in
one coherent diagnostics surface. The UI remains generic: workers and runtime surfaces
come from server-owned catalog/resources, and future capabilities should appear
through worker-owned functions, triggers, lifecycle evidence, and generated UI
surfaces rather than fixed iOS product screens.
Malformed catalog entries are surfaced as degraded diagnostics instead of being
silently omitted, and failed refreshes no longer fabricate an empty healthy
runtime state.

Placement cleanup amendment, 2026-06-18: the original IOSAC proof placed a
compact cockpit capsule in `ChatView` so users could open the new worker
lifecycle shell during the proof slice. Current product review found passive
`Idle` worker-runtime diagnostics too prominent for the primary conversation,
so the cockpit is retained under Servers diagnostics and chat-level signals are
deferred until they represent attention-worthy, session-relevant states.
