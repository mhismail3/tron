# Performance / Resource Governance Scorecard

Status: **complete**

Current score: **100/100**

Passing threshold: **100/100**

Branch: `codex/performance-resource-governance-current`

Baseline commit: `c99a5439d9538dfc88de2883bf6b4383c8e1c037` (`Harden provider model boundaries`)

Stale branch quarantine: `codex/performance-resource-governance` and `codex/performance-resource-governance-recovery` are reference-only quarry. They are not merged, cherry-picked, copied wholesale, or accepted as completion evidence for this current-lineage slice.

| Row | Name | Points | Status | Evidence |
| --- | --- | ---: | --- | --- |
| PERF-0 | Baseline, lineage, and stale-branch quarantine | 5 | passed | `git merge-base --is-ancestor c99a5439d9538dfc88de2883bf6b4383c8e1c037 HEAD` succeeded before edits; stale performance branches are quarantined as reference-only quarry. |
| PERF-1 | Whole resource-governance inventory | 8 | passed | `performance-resource-governance-inventory.md` and `.tsv` cover queues, tasks, streams, payloads, audit rows, retries, cancellation, timeouts, logs, storage, retention, diagnostics, dev lifecycle, transport, and tests. |
| PERF-2 | Queue and concurrency backpressure | 12 | passed | Queue stores reject oversized payloads and per-queue active-depth overflow; outbound WebSocket queues, external-worker invocation waiters, trigger depth/path budgets, shutdown task handles, and provider retry attempts have owned bounds or synchronous ownership. |
| PERF-3 | Stream, frame, and payload bounds | 12 | passed | Provider SSE/NDJSON frames, stream text/thinking accumulators, tool-call argument buffers, active streamed tool invocations, queue payloads, WebSocket frames, log ingest, and storage blob retention are capped at owner boundaries. |
| PERF-4 | Cancellation, timeout, and shutdown semantics | 12 | passed | Provider retry waits observe `CancellationToken`; stream parse failures are surfaced as provider errors; shutdown has callback and abort-drain deadlines; external-worker disconnects resolve waiters so queue retries do not wait for invocation timeouts. |
| PERF-5 | Memory, log, file, and blob retention | 10 | passed | Client log ingest/message sizes are capped, recent log reads are limited, SQLite WAL checkpoint/size-budget/retention helpers exist, blobs have retention cleanup, and archives are explicit file moves. |
| PERF-6 | Startup, restart, and dev-server predictability | 8 | passed | Startup registers runtime services through owned lifecycle handles; `tron dev` manages port 9847 with LaunchAgent takeover, PID/log files, bounded waits, and explicit stop paths; production deploy was not run. |
| PERF-7 | Load/soak regression harness | 10 | passed | `performance_resource_governance_invariants` includes synthetic queue burst and oversized payload rejection plus static guards for frame, accumulator, retry, shutdown, retention, docs, README, CI, and predecessor inventory coverage. |
| PERF-8 | Server/iOS/runtime boundary behavior | 8 | passed | New limits are server-side owner checks that surface as existing engine/provider/worker errors; no public protocol DTO or Swift decoder schema changed, so iOS simulator tests are not required beyond generated-project drift verification. |
| PERF-9 | Docs, README, predecessor inventories, and CI wiring | 8 | passed | PERF artifacts, README entries, predecessor inventory markers, local `scripts/tron.d/quality.sh`, and GitHub Rust static-gates workflow are wired to the new invariant target. |
| PERF-10 | Verification, adversarial self-audit, and clean commit | 7 | passed | Focused tests, full `scripts/tron ci fmt check clippy test`, personal-info guard, iOS project drift check, hygiene checks, and clean commit are required closeout evidence in the evidence manifest. |
