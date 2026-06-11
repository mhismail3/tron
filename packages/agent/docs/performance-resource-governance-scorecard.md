# Performance / Resource Governance Scorecard

Status: **closed**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/performance-resource-governance-recovery`
Base commit: `b114493199703a045636c1b3b46250f1af2f6a11`

Evidence manifest:
[`performance-resource-governance-evidence-manifest.md`](performance-resource-governance-evidence-manifest.md)

Inventory:
[`performance-resource-governance-inventory.md`](performance-resource-governance-inventory.md)
and
[`performance-resource-governance-inventory.tsv`](performance-resource-governance-inventory.tsv)

Invariant target:
[`../tests/performance_resource_governance_invariants.rs`](../tests/performance_resource_governance_invariants.rs)

## Scope

This slice makes resource ownership and bounds explicit for provider parsers,
provider stream accumulation, agent-side stream state, per-turn crash journals,
`/engine` slow-consumer delivery, logs, diagnostics, storage retention,
startup/shutdown lifecycle, provider retry loops, and closeout static guards.

It does not add new providers, model features, public API methods, iOS settings,
repo-managed skills, scheduler/autostart behavior, successor-agent behavior, or
worker orchestration surfaces.

## Scenario Ledger

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| PRG-0 | Harness | 5 | passed | PRG scorecard/evidence/inventory docs, TSV, invariant target, README links, local `scripts/tron ci test`, GitHub `rust-static-gates`, and predecessor preservation checks are wired. |
| PRG-1 | Resource Boundary Inventory | 10 | passed | Provider parsers, stream accumulators, agent state, journals, engine queues, logs, diagnostics, startup/shutdown, storage retention, retry loops, and runtime services are inventoried with owner, dimension, current proof, risk, proof target, and action. |
| PRG-2 | Memory and Payload Bounds | 12 | passed | Provider SSE/NDJSON lines, provider text/thinking/signature/tool arguments, agent stream state, streaming journals, log messages, diagnostic payloads, and storage payloads have explicit byte/item ceilings or documented retained proofs. |
| PRG-3 | Queue/Stream/Backpressure | 12 | passed | `/engine` poll pages and outbound queues remain bounded, async push delivery fails closed on slow consumers with overload metrics, and stream cursor pagination does not accumulate unbounded work. |
| PRG-4 | Logs/Diagnostics/Audit Volume | 8 | passed | Server and CLI log readers share the 1,000-row ceiling, client log ingest/message bounds remain guarded, and structured diagnostic/audit data flows through bounded or blob-backed retention paths. |
| PRG-5 | Startup/Shutdown/Task Lifecycle | 10 | passed | Startup retention and storage budget enforcement remain explicit, runtime services register with the shutdown coordinator, and shutdown callback/task drains have timeout and abort governance. |
| PRG-6 | Storage Retention/Disk Governance | 10 | passed | Storage inline payload thresholds, verbose retention days, retention runs, unowned/expired blob cleanup, checkpoints, exports, and size-budget enforcement remain owner-local and guarded. |
| PRG-7 | Provider/Model Retry/Stream Resource Discipline | 8 | passed | Provider retry loops retain max attempts, max delay, cancellation, and redacted failure semantics while provider stream limit violations surface through canonical `StreamEvent::Error`. |
| PRG-8 | Load/Soak/Regression Harnesses | 8 | passed | Focused tests cover oversized parser lines, provider accumulators, Kimi/Ollama local streams, agent stream state, streaming journal budget, engine slow-consumer shutdown, and CLI log limit validation. |
| PRG-9 | Static Guards/Cross-Slice Preservation | 10 | passed | PRG static guards verify resource constants, source failure paths, docs/gate wiring, predecessor invariant targets, OPSTC successor cleanup, and absence of repo-managed first-party skills. |
| PRG-10 | Docs/README/Evidence/Closeout | 7 | passed | Progressive module docs, README, scorecard, evidence manifest, inventory docs/TSV, exact verification commands, targeted iOS-test rationale, clean status, and commit are recorded. |

Total weight: **100**

## Source Findings And Fixes

- The shared SSE parser now rejects provider lines above
  `DEFAULT_MAX_SSE_LINE_BYTES` and forwards parser resource failures as
  canonical stream errors.
- Shared provider stream accumulation now has owner-local byte ceilings for
  text, thinking, signatures, tool arguments, and active capability drafts.
  Anthropic, OpenAI, Google, Kimi, and Ollama streaming paths call those bounded
  helpers or equivalent checks before retaining provider deltas.
- Ollama NDJSON streaming now uses the same line ceiling discipline as provider
  SSE streams.
- Agent stream state now caps per-turn text, thinking, and capability argument
  accumulation before writing to journal or mutating in-memory state.
- Per-turn streaming journals now cap WAL bytes and recovered text, thinking,
  and capability invocation counts before startup recovery accumulates content.
- `/engine` async push delivery now waits only a bounded timeout for a full
  outbound queue, increments `engine_ws_overload_total`, and closes slow
  consumers instead of parking the push task indefinitely.
- `tron logs --limit` now rejects values above the server-owned 1,000-row cap.

## Residual Risk

No PRG-specific residual risk is accepted. Existing Rust dead-code warnings
remain outside this slice and are tracked by the broader codebase lint posture.
