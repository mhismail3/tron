---
name: tron-architecture-auditor
description: Audit Tron's implemented architecture, ownership boundaries, contracts, dependency topology, and configuration authority. Use for system-structure fitness reviews, not diagrams or target-design proposals.
---

# Tron Architecture Auditor

Perform a read-only audit of the architecture Tron actually executes. Runtime
wiring, manifests, schemas, and canonical state ownership outrank diagrams and
folder names. Pattern compliance is not a goal by itself.

## Fixed architecture invariants

- One live Gateway runtime owns each canonical session; mutations serialize per
  session while distinct sessions may run concurrently.
- Accepted prompts continue after iOS disconnect. Reconnect receives an
  authoritative snapshot; prompts are never automatically replayed.
- Mutation requests carry command IDs and use bounded idempotency receipts.
- Canonical Pi JSONL, settings, credentials, packages, resources, compaction, and
  retries remain authoritative. iOS caches and Gateway snapshots are projections.
- Project trust gates executable project resources but is not a sandbox.
- Local Mac credentials, mobile device credentials, and legacy auth are distinct.
- Do not reintroduce Engine, workers, event journals, session mirrors, duplicate
  stores, or compatibility paths for retired architecture.

## Safety boundary

Read `AGENTS.md`, package architecture docs, manifests, entrypoints, and Git
status. Do not edit code/docs, generate architecture artifacts, mutate Gateway
lifecycle, deploy, migrate data, or open canonical sessions in another runtime.
Use safe static traces and focused tests only. Load `tron-ios` before any iOS
build, signing, simulator, device, or artifact work.

## Workflow

1. **Map actual units.** Identify processes, packages, modules, stores, protocols,
   entrypoints, configuration owners, public interfaces, external systems, and
   independent build/deploy/scale/failure boundaries.
2. **Trace critical flows.** Follow representative request, prompt, reconnect,
   mutation, notification, upload, settings, and shutdown paths from entrypoint to
   canonical outcome. Record runtime registration, not just definitions.
3. **Audit ownership.** For each state and resource identify the sole canonical
   owner, projection boundaries, atomicity owner, retry/cancellation owner, and
   cleanup owner. Flag ambiguity only when it creates correctness, security,
   deployment, or recurring change cost.
4. **Audit contracts.** Check protocol versions, input/output bounds, errors,
   nullability, command identity, idempotency, serialization, ordering, delivery
   semantics, registration, and producer/consumer agreement.
5. **Audit dependencies.** Resolve internal imports/calls/routes/events including
   aliases, re-exports, reflection, registries, generated code, and plugins.
   Validate cycles or direction violations against an explicit rule and concrete
   consequence; folder structure alone is low-confidence evidence.
6. **Audit evolution.** Compare code with current docs and accepted decisions.
   Find partial migrations, parallel mechanisms, compatibility with no consumer,
   misplaced configuration, and release coupling. Prefer bounded boundary repair
   over rewrites and speculative future architecture.
7. **Validate.** Prove each finding with a dependency, call, registration,
   configuration, or public-contract path and filter framework/generated behavior.

## Finding gate and verdict

Each finding needs affected boundary, exact evidence, current consequence,
materiality, migration/rollback constraints, and smallest safe outcome. Reject
pattern taste, generic best practice, speculative scale, and equally valid shapes.

Use `P0`–`P3`. Return `FAIL` for evidenced correctness/security ownership defects
or P0/P1 structural risk, `CONCERNS` for material non-blocking change
amplification, `BLOCKED` when required wiring/authority cannot be verified safely,
and `PASS` when no material architectural defect remains.

## Report

Return the actual architecture map, critical flows, ownership/contract/dependency
fitness summary, deduplicated findings with paths, prerequisite-aware evolution
order, documentation drift, accepted exceptions, blind spots, and residual risk.
