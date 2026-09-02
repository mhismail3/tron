---
name: tron-codebase-auditor
description: Audit Tron production code across security, delivery, maintainability, dependencies, diagnosability, concurrency, and lifecycle. Use for broad cross-cutting health reviews when no narrower audit owns the risk.
---

# Tron Codebase Auditor

Perform a broad, read-only audit of production code. Detector matches and style
preferences are candidates, not findings. Route documentation, test-portfolio,
architecture, persistence, and measured performance concerns to their narrower
Tron skill when that is the primary question.

## Non-negotiable context

- Read `AGENTS.md`, `CONTRIBUTING.md`, and the owning package documentation.
- Preserve one live Gateway runtime per canonical session, per-session mutation
  serialization, continuation after iOS disconnect, authoritative reconnect,
  bounded command-ID receipts, and no automatic replay after interruption.
- Pi runtime state remains canonical. Do not propose Engine/workers, event
  journals, SQLite session mirrors, duplicate settings/session models, or
  compatibility branches for retired architecture.
- Credentials stay in owned stores; mobile tokens stay in Keychain; only hashes
  persist in Gateway state. Never expose a suspected secret in the report.

## Safety boundary

- Keep the audit read-only. Build/test caches are acceptable when repository
  commands own them and they are disclosed.
- Never rebuild, update, rollback, promote, restart, or mutate a running Gateway;
  never invoke mutating `scripts/tron dev`, deployment, release, signing, archive,
  physical-device install, or production/data operations.
- Do not open one canonical session in another runtime client.
- For iOS execution or artifact claims, load `tron-ios` and use repository
  helpers. Start with the smallest owning test; do not repeatedly run full suites.

## Workflow

1. **Map risk.** Identify languages, entrypoints, deployment units, generated
   areas, trust boundaries, irreversible operations, and repository verification
   commands. Inspect Git status and separate user work from the baseline.
2. **Establish a focused baseline.** Run the narrowest safe build, type, lint,
   policy, or test checks that can answer the audit question. Record commands,
   environments, status, and generated artifacts.
3. **Trace security and delivery.** Follow untrusted input to SQL, shell, paths,
   URLs, HTML, decoding, credentials, authorization, and destructive actions.
   Check bounded input/output, default-deny behavior, redacted diagnostics, gate
   bypasses, packaging identity, and local/CI/artifact drift.
4. **Trace maintainability.** Confirm concrete costs behind duplication,
   wrappers, mixed ownership, dead paths, hard-coded policy, dependency risk,
   and custom mechanisms. Before deletion, inspect reflection, registration,
   configuration, code generation, scripts, and external entrypoints.
5. **Trace concurrency and lifecycle.** Examine shared state, operation identity,
   cancellation, retries, idempotency, timeout, bounded queues, startup, draining,
   cleanup, and every success/error/disconnect path. Treat Gateway projections as
   disposable and canonical stores as authority.
6. **Validate candidates.** Reproduce high-risk failures with a safe focused test
   or complete call path. Verify version-sensitive claims with installed versions
   and official primary sources. Deduplicate symptoms by root cause.

## Finding gate

A finding must include reachable path, evidence, failure mechanism, material
impact at Tron's current scale, confidence, and smallest root-cause correction.
Reject hypothetical scale, generic best practice, personal style, and a different
but reasonable implementation.

Priorities: `P0` active credential/data/execution compromise; `P1` exploitable or
release-blocking defect; `P2` material reliability/operability/maintenance risk;
`P3` bounded recurring cost. Verdicts are `PASS`, `CONCERNS`, `FAIL`, or
`BLOCKED`; `FAIL` requires an evidenced P0/P1 or required failing gate.

## Report

Return scope/exclusions, commands run, a security/delivery/maintainability/
lifecycle summary, deduplicated findings with exact paths, prerequisite-aware
remediation order, unverified candidates, and residual risk. Do not repair code
as part of this audit.
