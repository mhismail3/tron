# Performance / Resource Governance Evidence Manifest

Status: **complete**

This manifest records source-owned evidence for the Performance / Resource Governance original hardening slice on `codex/performance-resource-governance-current`.

| Evidence ID | Scorecard Rows | Evidence | Status |
| --- | --- | --- | --- |
| PERF-EV-001 | PERF-0 | Baseline ancestry: `git merge-base --is-ancestor c99a5439d9538dfc88de2883bf6b4383c8e1c037 HEAD` returned success before branch creation. | captured |
| PERF-EV-002 | PERF-0 | Stale branch quarantine recorded for `codex/performance-resource-governance` and `codex/performance-resource-governance-recovery`. | captured |
| PERF-EV-003 | PERF-1 | Whole resource-governance inventory in `performance-resource-governance-inventory.md` and `.tsv` with at least 30 tracked rows across all required surface classes. | captured |
| PERF-EV-004 | PERF-2, PERF-7 | Queue backpressure and burst rejection tests/static guards in `performance_resource_governance_invariants`; queue stores enforce `MAX_ACTIVE_QUEUE_ITEMS_PER_QUEUE` and `MAX_QUEUE_PAYLOAD_BYTES`. | captured |
| PERF-EV-005 | PERF-3, PERF-7 | Provider SSE/NDJSON frame caps, stream accumulator caps, active streamed capability fan-out caps, WebSocket frame caps, payload bounds, and JSON parse guards live at owner boundaries. | captured |
| PERF-EV-006 | PERF-4 | Provider retry cancellation, stream error propagation, external-worker disconnect waiter resolution, and app shutdown callback/abort deadlines are source-guarded. | captured |
| PERF-EV-007 | PERF-5 | Client log ingest/message caps, bounded recent log reads, SQLite checkpoint/size budget helpers, blob retention, and archive behavior are source-guarded. | captured |
| PERF-EV-008 | PERF-6 | Startup/restart/dev-server lifecycle proof is recorded against `scripts/tron.d/dev.sh`, app lifecycle startup/shutdown, runtime service handles, port 9847 ownership, LaunchAgent takeover, PID/log paths, and explicit stop behavior. | captured |
| PERF-EV-009 | PERF-8 | Limits use existing engine/provider/worker error surfaces and do not change public protocol or Swift DTOs; iOS 26.5 simulator tests are not required unless the closeout drift check reveals generated project changes. | captured |
| PERF-EV-010 | PERF-9 | README, predecessor inventories, local `scripts/tron.d/quality.sh`, and `.github/workflows/ci.yml` run and describe `performance_resource_governance_invariants`. | captured |
| PERF-EV-011 | PERF-10 | Focused tests, full CI, personal-info guard, iOS drift check, `git diff --check`, ignored-file scan, clean status, and commit hash are recorded in the final handoff after command execution. | captured |

## Verification Log

Final verification was run from `codex/performance-resource-governance-current`
after staging the file move and predecessor inventory updates required by the
index-based static gates.

| Command | Result | Notes |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | passed | PERF invariant covers scorecard math, artifact wiring, inventory coverage, synthetic queue burst rejection, source-owned bounds, cancellation/shutdown anchors, and predecessor markers. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::durability --lib -- --nocapture` | passed | Focused durability resource tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml queue --lib -- --nocapture` | passed | Queue lifecycle, queue inspection, external-worker queued disconnect, and large SQLite queue blob tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::invocation --lib -- --nocapture` | passed | Invocation-focused tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::authority --lib -- --nocapture` | passed | No matching authority unit tests; PERF static guard covers authority/resource anchors. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store --lib -- --nocapture` | passed | Session event-store focused suite passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers --lib -- --nocapture` | passed | Provider suite passed after stream bounds and stream-common test split. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::model::responder --lib -- --nocapture` | passed | Responder focused suite passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::engine::socket --lib -- --nocapture` | passed | Engine WebSocket focused suite passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::runtime::external_workers --lib -- --nocapture` | passed | External worker transport focused suite passed. |
| PMBD, PPACD, DSEMD, CSD, ODA, FSC, SACB, TPC, HRA, PCC, and off-plan cleanup invariant targets | passed | Predecessor gates passed after adding PERF rows, stream module-layout rows, and historical off-plan cleanup residue classifications. |
| `scripts/tron ci fmt check clippy test` | passed | Full local CI passed after predecessor inventory reconciliation. |
| `scripts/personal-info-guard.sh` | passed | Full source scan found no personal-info leaks. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | No Swift, protocol DTO, generated project source, or iOS decoder changes were made; iOS 26.5 simulator tests were not required. |
| `git diff --check && git diff --cached --check` | passed | No whitespace errors in unstaged or staged diffs. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked files reported. |
