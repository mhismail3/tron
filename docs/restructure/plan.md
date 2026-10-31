# Structure and verification contracts

[AGENTS.md](../../AGENTS.md) and [principles](../PRINCIPLES.md) own engineering policy. The current program and
execution order live in epic #2173,
not a repository phase plan. Tool owners below define executable behavior.

## 3. Metrics, definitions and targets

`scripts/tron metrics <rev>` measures Git objects and writes
`test-results/metrics/<sha>.json`. Classification, counting and unavailable fields
are defined in [metrics](../../tools/metrics/README.md). LOC is trailing evidence,
not a target or landing gate. `scripts/tron measure <base> [<head>]` is advisory.
The proposed [health scorecard](../../tools/verify/health-design.md) does not add
an executable check or scheduler.

### M2. Locality and conflict surface (primary objective)

One owner per file and downward layer/cycle/Pi-seam ratchets remain. File-size
reports do not establish architectural quality. Existing size-check behavior is
specified by [budgets](../../tools/budgets/README.md); changing it is separate
executable work, not accomplished by removing process prose.

### 4.3 Multi-agent-native design principles (dev-time)

Cross-module indexes are generated from their owners, not maintained as parallel
file ledgers. Tests, fixtures and documentation live with the owning module.
Verification selection follows manifests and declared dynamic edges.

## 5. Architecture

### 5.1 Layers (all packages)

```text
L5 composition   gateway main / iOS App / Mac App     wiring
L4 surfaces      transport+RPC dispatch / iOS UI      routes to owners
L3 modules       capability owners                    declared dependencies
L2 kernel        harness primitives                   session/run/host lifecycles
L1 contracts     wire + persisted value types         values
L0 platform      durability, logging, process, timing  foundations
```

The [layer checker](../../tools/layers/README.md) owns observed graph rules,
allowed dependencies and shrink-only baselines. The [kernel contract](k0-kernel.md)
owns the Pi seam. No phase transfer or file-move quota is required.

### 5.6 Docs target

Documentation sits beside its owner. [Docs indexes](../../tools/docs/README.md)
are generated; [AGENTS.md](../../AGENTS.md#documentation) owns documentation policy.

## 6. Verification system

### 6.1 Module manifest (V1)

Every tracked file matches exactly one co-located `<name>.module.json` owner.
The [ownership contract](../../tools/ownership/README.md#manifest) defines identity,
placement, fields, discovery and patterns. Manifests do not duplicate package
manager, compiler or deployment configuration. XcodeGen directory sources exclude
manifests and owner READMEs; SwiftPM manifests sit beside `Package.swift`, not
inside a source target.

### 6.2 `scripts/tron verify` (V2): the one command

[Verify](../../tools/verify/README.md) owns affected selection, none/partial/full
tiers, explicit batches, exact quarantine matching, cancellation and evidence.
A plan is selection evidence, never a test pass. No second runner or receipt gate.

### 6.4 Gateway behavior locks (V3)

[Scenario locks](../../packages/gateway/docs/scenario-locks.md) own normalization
and real Gateway/Pi boundary witnesses. The [oracle policy](../../tools/verify/test-oracles.md)
owns preserving what a test proves, not freezing test text.

### 6.6 iOS UI locks (V5-UI) and lock sensitivity

[UI locks](../../packages/ios-app/UITests/Locks/README.md) own rendered witnesses;
interaction journeys remain interaction evidence. Mutation sampling is an optional
sensitivity measurement, not a recurring phase obligation or per-change gate.

### 6.7 Structure checkers (V5, V6, V8, V9, V10)

- [Ownership](../../tools/ownership/README.md): exactly one owner per tracked path.
- [Layers](../../tools/layers/README.md): real compiler/index graph and ratchets.
- [Budgets](../../tools/budgets/README.md): current size reports and failures.
- [Metrics](../../tools/metrics/README.md): deterministic counts, never a gate.
- `scripts/tron measure`: advisory moved/rewrite counts, not move paperwork.

### 9.1 Hierarchy

GitHub tasks may link under an epic parent. [Work tooling](../../tools/work/README.md)
owns mutation and exact-head preservation contracts; module manifests, not issue
checklists, are the file-ownership authority.
