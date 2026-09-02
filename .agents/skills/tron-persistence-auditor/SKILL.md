---
name: tron-persistence-auditor
description: Audit Tron's canonical session and Gateway stores, queries, transactions, consistency, bounds, and resource lifecycle. Use when data correctness, durability, or scalability is at risk, not for general tuning.
---

# Tron Persistence Auditor

Perform a read-only audit of persistence and data-heavy runtime paths. Connect
static candidates to concrete consistency, durability, query, bound, or resource
mechanisms. Do not claim performance impact without measurements.

## Tron persistence model

- Canonical Pi JSONL and runtime-owned settings, credentials, packages, resources,
  compaction, and retries remain authoritative.
- Gateway owns bounded mobile infrastructure state, command receipts, run markers,
  uploads/blobs, enrollment/device hashes, and notification admission/projections.
- iOS caches and Gateway snapshots are disposable projections, never mirrors.
- One live runtime owns a canonical session. Do not open the same session through
  another runtime or create a SQLite/session/event mirror as a diagnostic aid.
- Raw provider credentials remain in the Mac runtime store; mobile tokens remain
  in Keychain; only hashes belong in Gateway state.

## Safety boundary

- Read `AGENTS.md`, `packages/gateway/README.md`, schemas, stores, migrations, and
  owning tests before diagnostics.
- Never connect to production, mutate canonical data, create indexes, migrate,
  vacuum, rewrite state, alter pools, or run Gateway lifecycle operations.
- `EXPLAIN ANALYZE` executes a statement: use it only for a confirmed read-only
  query on an explicitly approved disposable/non-production target.
- Redact IDs, paths, prompts, credentials, tokens, and payload content from logs
  and reports. Disclose every generated diagnostic artifact.

## Workflow

1. **Map stores and authority.** Identify JSONL, files, Keychain, bounded JSON
   documents, caches, uploads, receipts, queues, schemas, migrations, locks,
   pools, dependency scopes, and runtime entrypoints. Record versions and bounds.
2. **Trace critical paths.** Follow session creation/open/delete, prompt claim,
   command receipt, upload ownership, notification admission, import/export, and
   shutdown/recovery from request to durable outcome and projection.
3. **Audit consistency.** Identify begin/commit/rollback/retry/disposal owners,
   atomic rename/fsync boundaries, command idempotency, unique constraints,
   duplicate delivery, partial success, crash windows, mixed-version behavior,
   and recovery after ambiguous outcomes.
4. **Audit access cost.** Find repeated scans/parses, query-in-loop or per-entry
   I/O, over-fetching, unbounded materialization, broad copies, missing pagination,
   cache invalidation errors, and user-amplified work. Separate query/file work,
   lock wait, serialization, network, and downstream latency.
5. **Audit bounds and lifecycle.** Verify count/byte/time limits before allocation
   and persistence; aggregate budgets across processes. Trace files, descriptors,
   streams, locks, subscriptions, temporary copies, and child processes through
   success, failure, timeout, cancellation, client disconnect, partial iteration,
   startup reconciliation, and repeated shutdown.
6. **Measure or label.** Prefer existing logs, tests, profiles, and safe repository
   diagnostics. Static evidence may prove correctness/lifecycle defects; label
   throughput/latency impact unmeasured when no representative runtime evidence exists.
7. **Validate findings.** Reproduce high-risk correctness defects with a focused
   test or complete failure trace. Filter bounded maintenance, fixtures, retained
   migration history, framework lifecycle, and documented tradeoffs.

## Finding gate and verdict

Every finding needs call path, store/resource, exact evidence, failure or cost
mechanism, affected bound/workload, confidence, and smallest safe remediation.
Reject hypothetical load, storage-style taste, and reasonable consistency choices.

Use `FAIL` for evidenced corruption, atomicity, confidentiality, outage,
resource-exhaustion, required failing gate, or P0/P1 risk; `CONCERNS` for material
non-blocking or explicitly unmeasured risk; `BLOCKED` when a critical semantic or
safe environment has no credible fallback; otherwise `PASS`.

## Report

Separate measured from static scope. Return authority/store map, diagnostics and
targets used, health summary for consistency/access cost/bounds/lifecycle,
deduplicated findings, remediation order, unavailable evidence, accepted
tradeoffs, and residual persistence risk.
