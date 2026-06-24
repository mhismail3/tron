# Performance / Resource Governance Inventory

Status: **complete**

Scope: resource-governance surfaces for queues, task spawning, stream buffers, event payloads, provider audit payloads, retry/backoff, cancellation, timeouts, logs, SQLite/WAL/checkpoint behavior, blob/file retention, diagnostics, dev server lifecycle, transport/WebSocket payloads, and regression tests.

The machine-readable inventory is `performance-resource-governance-inventory.tsv`.

## Audit Notes

- Baseline branch was created from `c99a5439d9538dfc88de2883bf6b4383c8e1c037`.
- Stale performance branches are quarantined as reference-only quarry.
- The local `@self-inspect` skill requested by project guidance was not installed in this Codex session; direct source and local SQLite inspection are used instead.
- The inventory classifies each resource-governance owner by the enforced bound, the intentionally persistent owner, or the test/static gate that prevents silent drift.
- Server-side limits use existing error surfaces. No public protocol DTO or Swift decoder schema changed in this slice.
- Production deploy is out of scope; only dev-server lifecycle paths are documented.
