# Self-Adapting Agent Worker Schedule Capacity Scorecard

Status: **complete**

Current score: **100/100**

Baseline commit: `9e9393acde1284b0c684a5c15d9bf331133c9928`

This scorecard adds Self-Adapting Agent Worker Schedule Capacity (SAAWSC): bounded, resumable schedule scanning over the completed SAAWSD wall-clock dispatch path. The scheduler no longer treats a single fixed list result as the whole reviewed schedule set. It pages reviewed `worker_schedule_plan` resources in deterministic order, persists a safe singleton scan-state resource, resumes from its cursor across polls or runtime recreation, wraps when the tail is reached, and observes cancellation without inventing a public schedule API.

SAAWSC deliberately does not add provider-visible scheduling tools, public `/engine` schedule methods, iOS settings, deployment flow changes, cron/RRULE/local-time semantics, restart policy, retry policy beyond existing queue mechanics, worker launch paths, activation issuance paths, vault consumption, process supervision, or repo-managed skills.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAAWSC-0 | Harness and Baseline | 5 | passed_after_fix | Started from completed SAAWSD commit `9e9393acde1284b0c684a5c15d9bf331133c9928`; added scorecard, evidence, inventory docs/TSV, static invariant target, README links, and CI wiring. |
| SAAWSC-1 | Source Inventory | 5 | passed_after_fix | Inventory covers resource pagination, memory/SQLite stores, host substrate forwarding, scheduler scan state, cancellation, trigger dispatch inheritance, and forbidden surfaces. |
| SAAWSC-2 | Paged Resource Listing Contract | 10 | passed_after_fix | Added internal `ListResourcesPageRequest`, `ListResourcesPage`, and `ResourceListCursor` types while preserving the existing public `ListResources` call shape. |
| SAAWSC-3 | Deterministic Cursor Ordering | 8 | passed_after_fix | Memory and SQLite stores order by `updated_at DESC, resource_id DESC`, validate cursor ids, cap pages at 500, and resume strictly after the last returned cursor. |
| SAAWSC-4 | Scanner State Resource | 10 | passed_after_fix | Added `worker_schedule_scan_state` schema and namespace claim for a safe singleton cursor/summary/status record with no activation, vault, stdin, provider, or secret material. |
| SAAWSC-5 | Bounded Poll Budget | 10 | passed_after_fix | Scheduler scans pages of 100 and at most 500 reviewed plans per poll, preventing one cadence tick from monopolizing the engine under large schedule sets. |
| SAAWSC-6 | Fair Resume and Wrap | 12 | passed_after_fix | Runtime loads the persisted cursor on every poll, resumes past the last scanned plan, clears the cursor when the filtered tail is reached, and wraps back to the head on the next full pass. |
| SAAWSC-7 | Cancellation Persistence | 8 | passed_after_fix | The scheduler observes the service cancellation token between pages and items, exits without enqueueing when cancelled before item dispatch, and records `cancelled` scan state. |
| SAAWSC-8 | Safe Scan-State Payload | 8 | passed_after_fix | Scan state records only scanner id, cursor, budget flags, poll timestamps, aggregate summary, trace id, generic redacted error, and safe metadata. |
| SAAWSC-9 | Restart Recovery | 8 | passed_after_fix | Focused runtime test recreates `EngineWorkerScheduleRuntime` after a budgeted first pass and proves it resumes from persisted cursor to reach an older due schedule. |
| SAAWSC-10 | Boundary Hardening | 8 | passed_after_fix | Static gates assert SAAWSC does not add provider/public/deploy/iOS/launchd/SMAppService/repo-skill/restart/retry/payload-replay surfaces or direct activation/launch calls. |
| SAAWSC-11 | Regression and Closeout | 8 | passed_after_fix | Closeout requires focused capacity tests, store pagination tests, SAAWSC/SAAWSD/SAAWTL/SAAWBH/SAAWO/SAAWA invariants, formatting, check, and clean committed evidence. |

## Closeout Targets

- `packages/agent/src/engine/durability/resources/types.rs`
- `packages/agent/src/engine/durability/resources/validation.rs`
- `packages/agent/src/engine/durability/resources/store/memory.rs`
- `packages/agent/src/engine/durability/resources/store/mod.rs`
- `packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs`
- `packages/agent/src/engine/primitives/stores.rs`
- `packages/agent/src/engine/invocation/host/substrate_handle.rs`
- `packages/agent/src/engine/runtime/worker_schedule/mod.rs`
- `packages/agent/src/engine/runtime/worker_schedule/scan_state.rs`
- `packages/agent/src/transport/runtime/worker_schedule.rs`
- `packages/agent/src/engine/tests/runtime/worker_schedule_dispatch.rs`
- `packages/agent/src/engine/durability/resources/store/tests.rs`
- `packages/agent/tests/self_adapting_agent_worker_schedule_capacity_invariants.rs`

## Residual Risks

- Scan state is a singleton for the current v1 scheduler. Multi-shard or per-scope schedule scans require a successor scorecard before rollout.
- Resource pagination is internal substrate behavior. Public API pagination remains out of scope and must be designed separately if exposed later.
- The scheduler still validates every scanned reviewed plan before due calculation. That is deliberately fail-closed but may require a future index or partitioning slice for very large schedule populations.
