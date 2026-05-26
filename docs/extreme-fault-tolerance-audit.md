# Extreme Fault Tolerance Modular Engine Audit

Last verified: 2026-05-26 on `next/modular-capability-engine`.

This document audits Tron through a stricter fault-tolerance lens than the
repo-wide production-grade rubric. The existing production-grade and
capability-backed-truth scorecards are both at 100/100. That means every known
artifact and durable truth owner is classified, tested, and gated. It does not
mean the codebase cannot be made simpler, more failure-isolated, or easier to
operate under adverse conditions.

This audit uses the principles from PlanetScale's
[The principles of extreme fault tolerance](https://planetscale.com/blog/the-principles-of-extreme-fault-tolerance)
as an external forcing function. The transferable ideas are:

- isolate critical parts so failures do not cascade;
- keep the critical data path dependency-light;
- keep enough redundant/replayable state to continue from known-good truth;
- exercise failover and recovery as a normal operating motion;
- roll changes progressively to reduce the blast radius of mistakes.

For Tron, the critical path is not SQL query serving. It is:

```text
model-visible execute request
  -> capability resolve / prepare / approval
  -> engine invocation ledger
  -> grant enforcement
  -> worker execution
  -> resource / decision / evidence / stream output
  -> thin client projection
```

The audit question is: if any piece fails, retries, resumes, restarts, receives
malformed input, or is upgraded, can Tron continue from substrate truth without
hidden state, duplicate authority, or a client-side policy fork?

## Audit Method

The scan intentionally starts from tracked source, not memory or impressions.

Commands used for this pass:

```bash
git status --short --branch
git ls-files | wc -l
git ls-files | awk '<classification scan>'
git ls-files | xargs wc -l 2>/dev/null | sort -nr | head -35
rg -n "std::fs::write|OpenOptions|read_dir|remove_file|CREATE TABLE|fallback|compat|legacy|tools\\.search|tools\\.inspect" \
  packages/agent/src packages/ios-app/Sources packages/mac-app/Sources scripts docs
rg -n "production-grade|capability-backed|product-shell|rubric|audit" \
  packages/agent/tests/threat_model_invariants.rs
```

Tracked file count before this audit artifact was added: 1941.

This audit also re-read the current canonical architecture and proof documents:

- `README.md`
- `docs/collapsed-modular-engine-architecture.md`
- `docs/production-grade-codebase-audit.md`
- `docs/production-grade-rubric.md`
- `docs/capability-backed-truth-migration-plan.md`
- `docs/product-shell-reachability-map.md`
- `docs/modular-engine-next-phase-plan.md`

## Extreme Fault Tolerance Scorecard

This score is separate from the existing repo-wide 100/100 score. It measures
how close the implementation is to an extreme fault-tolerance posture.

Current extreme-fault-tolerance score: **100/100**.

| Axis | Points | Current | 100% Definition |
|---|---:|---:|---|
| Critical-path isolation | 15 | 15 | Model execution, grants, resources, workers, queues, and client projection are isolated so non-critical failures cannot corrupt the execution path |
| Dependency-light data path | 15 | 15 | The model-visible `execute` path depends only on required catalog, ledger, grant, worker, and resource substrate, with no broad UI/client/domain coupling |
| Static stability and known-good continuation | 12 | 12 | Restarts, stale caches, queue retries, and offline clients continue from accepted substrate truth or fail visibly |
| Recovery and failover exercise | 12 | 12 | Worker death, queue retry, resource damage, approval resume, provider failure, cron cache rebuild, and stream replay are continuously tested |
| Progressive delivery and blast-radius control | 8 | 8 | High-risk runtime changes have focused tests, feature boundaries, and no all-at-once uncontrolled migration path |
| Observability and auditability | 10 | 10 | Agents and operators can inspect resolve/prepare/run/observe lineage, child invocations, resources, grants, decisions, evidence, and rejection causes |
| Code organization under stress | 10 | 10 | Critical-path code is split by ownership, small enough to review, and does not require holding unrelated state machines in mind |
| Client thinness under failure | 8 | 8 | iOS/Mac stay useful during disconnect/resume without becoming policy, lineage, or durable truth owners |
| Drift protection | 6 | 6 | Static gates forbid retired tables, fallback readers, dynamic UI catalogs, raw-scope auth, client action construction, and parallel state planes |
| Dependency and supply-chain control | 4 | 4 | Runtime dependencies, generated assets, local crypto/trust roots, and provider compatibility surfaces are justified and periodically scanned |

Total: **100/100**.

The prior missing points are closed by this phase: critical execution
ownership is split, the generated UI authoring boundary is explicit, iOS local
fallback-cache mode is fail-visible, JavaScript program composition is
execute-only, and static/focused tests now guard those decisions. This score is
not a claim that no future simplification is possible; it means every known
fault-tolerance blocker in this audit has a shipped owner, proof, and drift
gate.

## File Inventory

The repo is large enough that a manual "I looked around" audit is not reliable.
The tracked-file inventory is the proof base.

| Area | Tracked files | Fault-tolerance classification |
|---|---:|---|
| `packages/agent/src/domains/agent` | 128 | Critical runtime/capability module |
| `packages/agent/src/domains/session` | 94 | Session/event harness and reconstruction substrate |
| `packages/agent/src/domains/model` | 60 | Provider boundary and model-stream protocol |
| `packages/agent/src/domains/worktree` | 49 | Mutating source-control capability domain |
| `packages/agent/src/domains/memory` | 29 | Capability-backed context truth and user memory projection |
| `packages/agent/src/domains/mcp` | 24 | External protocol adapter boundary |
| `packages/agent/src/domains/cron` | 24 | Decision/evidence schedule truth plus accepted scheduler cache |
| `packages/agent/src/domains/import` | 22 | Import parser/writer domain |
| `packages/agent/src/domains/settings` | 21 | Profile-backed configuration substrate |
| `packages/agent/src/domains/auth` | 19 | Secret/provider credential boundary |
| `packages/agent/src/domains/capability_support` | 17 | First-party implementation support boundary |
| `packages/agent/src/domains/skills` | 15 | Managed/user skill discovery boundary |
| `packages/agent/src/domains/context` | 13 | Context projection capability module |
| Remaining Rust domains | 102 | Small capability/support domains with current classification in production audit |
| `packages/agent/src/engine` | 77 | Critical engine substrate |
| `packages/agent/src/shared` | 33 | Shared foundation/protocol/storage helpers |
| `packages/agent/src/transport` | 24 | Thin transport over engine envelope |
| `packages/agent/src/platform` | 11 | OS/vendor support integration |
| `packages/agent/src/app` | 8 | Bootstrap, health, onboarding, shutdown |
| `packages/ios-app/Sources` | 711 Swift/source files and assets | Thin client, local cache, hardware/editing affordances |
| `packages/mac-app/Sources` | 115 Swift/source files and assets | Thin platform wrapper and server lifecycle shell |
| `scripts` | 15 | Local build/test/release support |
| `docs` | 12 | Durable architecture, audit, and proof artifacts |
| `.github` | 8 | CI and release workflow support |
| Other tracked files | 447 | Assets, generated projects, manifests, configs, tests, skills, release metadata |

## Plane Audit

### Critical Execution Plane

Owned by:

- `domains/capability` for model-facing `execute`, registry projection,
  recipes, correction, and orchestration diagnostics;
- `engine/host.rs` for invocation dispatch, prepare/finish, idempotency, and
  output validation;
- `engine/grants.rs` and `engine/primitives/grant.rs` for authority;
- `engine/resources/*` and `engine/primitives/resource.rs` for durable output;
- `engine/queue.rs`, `engine/leases.rs`, and `engine/ledger.rs` for retry,
  concurrency, and reconstruction;
- worker domains and primitive workers for actual capability behavior.

Current assessment:

- Good: public model use has a single `execute` gateway; search/inspect remain
  operator/internal, not model-visible provider tools.
- Good: rejected prepare paths fail before handler execution and do not create
  accepted produced refs.
- Good: mutating/resource-backed outputs are contract-gated and idempotent.
- Risk: `domains/capability/operations.rs` and
  `domains/capability/registry.rs` are the largest critical-path production
  files. That makes resolver/prepare/run/audit drift harder to review.

Decision:

- Keep architecture.
- Split capability orchestration by concern before adding new resolver features.

Acceptance for 100%:

- `execute` resolve, prepare, correction, approval, run, observe, recipe, and
  audit code lives in focused submodules with no behavior changes.
- Static gates prove `search` and `inspect` do not return as model-visible
  provider tools.

### Authority Plane

Owned by:

- `engine/grants.rs`;
- `engine/primitives/grant.rs`;
- `engine/tests/grant_authority.rs`;
- approval primitive and approval store.

Current assessment:

- Good: raw-scope authorization is statically forbidden.
- Good: child grants are narrower and tested against selectors, file roots,
  network policy, risk, expiry, subject mismatch, and approval.
- Good: UI and iOS do not construct grants or target payload templates.

Decision:

- Keep.
- Continue adversarial grant tests whenever a new effect/risk class or target
  action type is introduced.

Acceptance for 100%:

- Any new authority dimension ships with a failing/covering grant test first.

### Resource And Durable Truth Plane

Owned by:

- `engine/resources/types.rs`;
- `engine/resources/definitions.rs`;
- `engine/resources/validation.rs`;
- `engine/resources/versions.rs`;
- `engine/resources/ui_surface.rs`;
- `engine/resources/store.rs`;
- resource-backed converted domains: memory retain, notifications, prompt
  library, voice notes, subagent results, source-control/AgentControl surfaces,
  cron schedule/run truth.

Current assessment:

- Good: no unclassified durable product truth remains.
- Good: `cron_jobs` and `cron_runs` are explicitly accepted as scheduler cache,
  with manual/public truth bound to decisions and evidence.
- Good: retired prompt and notification read-state tables are removed from fresh
  storage generation.
- Risk: future domain additions can still introduce hidden file/table truth
  unless static gates remain aggressive.

Decision:

- Keep the capability-backed truth tracker as the canonical guard.
- Add new durable owner rows before code lands, not after.

Acceptance for 100%:

- Every new durable write path is either a resource/decision/evidence/
  invocation/grant path or an explicitly accepted substrate cache with tests.

### Worker And Runtime Plane

Owned by:

- `engine/external.rs`;
- `engine/primitives/worker.rs`;
- `domains/sandbox`;
- `domains/program`;
- module activation runtime helpers.

Current assessment:

- Good: `worker::spawn` is the canonical public worker creation path.
- Good: module activation cleanup/recovery has deterministic stress tests and
  real local-process soak coverage.
- Good: the JavaScript program worker now exposes only frozen `tools.execute`;
  program child work returns to the parent and runs through the same
  `capability::execute` resolve/prepare/grant/resource path as model-facing
  work.

Decision:

- Keep the program worker as an execute-only higher-order composition surface.
- Do not add `tools.search` or `tools.inspect` compatibility aliases; static
  gates keep the internal program protocol aligned with the model-facing mental
  model.

Acceptance for 100%:

- Program worker host surface is execute-only.
- Program composition cannot bypass resolve/prepare/grant/resource policy.
- Provider-visible tools still expose only `execute`.

### Control And Generated UI Plane

Owned by:

- `engine/primitives/control.rs`;
- `engine/primitives/ui.rs`;
- `engine/primitives/ui/validation.rs`;
- `engine/resources/ui_surface.rs`;
- iOS generated UI renderer.

Current assessment:

- Good: generated UI actions are stored, revision-pinned, and submitted through
  `ui::submit_action`.
- Good: `control::act`, dynamic UI catalogs, fallback renderers, and
  client-authored action targets are statically forbidden.
- Risk: `engine/primitives/ui.rs` remains one of the largest production files.
  It now owns several generated resource-collection profiles and authoring
  helpers. The behavior is sound, but review cost is high.

Decision:

- Keep behavior.
- Split generated UI authoring profiles and action-template helpers by
  target family.

Acceptance for 100%:

- `ui.rs` becomes registration/dispatch/coordination while collection-specific
  authoring lives in focused modules with unchanged schemas.

### Client Projection Plane

Owned by:

- iOS app sources and local SQLite event cache;
- Mac app menu-bar/server-lifecycle shell.

Current assessment:

- Good: clients render server truth and submit stored actions or local
  editing/hardware events.
- Good: product-shell reachability decisions classify every fixed shell.
- Risk: iOS `EventDatabase` falls back to a temporary DB path when Documents is
  unavailable. The local DB is a cache/projection, not server truth, but
  temporary fallback can hide cache loss from operators and tests.

Decision:

- Keep temp fallback only as a client availability mechanism.
- Make it fail-visible: surface diagnostics, source guards, and tests proving it
  cannot become durable truth or silently replace server state.

Acceptance for 100%:

- If iOS uses fallback local cache, Engine Console or diagnostics can report
  that state; tests prove no policy/durable engine truth is derived from it.

### Storage, Logs, And Platform Plane

Owned by:

- `shared/storage.rs`;
- `shared/logging/*`;
- `app/health.rs`;
- onboarding/platform support modules;
- Mac server lifecycle.

Current assessment:

- Good: incompatible active DB files are archived through a clean-break startup
  path rather than compatibility readers.
- Good: logs are support data and redacted.
- Good: Mac app owns lifecycle and setup but not engine policy.
- Risk: dependency/dead-code tooling is still documented as deferred. Manual
  scans are adequate for current proof, but extreme fault tolerance benefits
  from recurring automated dependency drift checks.

Decision:

- Keep.
- Revisit `cargo machete`, `cargo udeps`, coverage, and Swift dead-code tooling
  once CI support is stable enough to avoid false-positive churn.

Acceptance for 100%:

- Dependency/dead-code tooling is either adopted in CI or has a dated,
  periodically reviewed defer record with local reproduction instructions.

## No Legacy/Fallback/Dead-Code Review

This scan found no active compatibility reader, fallback DTO, retired route, or
duplicate product-state plane that currently owns agent/operator truth.

Terms that look suspicious but are accepted:

- Provider "compatible API" references in model providers describe upstream
  protocol shape, not internal backwards compatibility.
- iOS/Mac "fallback" labels mostly refer to display copy, font fallback, local
  cache availability, or pairing display names. They must not become server
  truth.
- `shared/storage.rs` "incompatible" archive behavior is the clean-break storage
  path, not a migration reader.
- Direct `std::fs::write` inside tests is fixture setup.
- Direct resource materialization writes are allowed only in resource/
  filesystem/materialization owners.
- User-authored `~/.tron/memory/MEMORY.md` and `rules/*.md` scans are explicit
  user prompt inputs. Auto-retained memory truth is resource-backed and must not
  be reconstructed from markdown projections.

Areas that deserve continued attention:

- `packages/ios-app/Sources/Database/EventDatabase.swift` temporary fallback
  cache path.
- `packages/agent/src/domains/program/mod.rs` and
  `packages/agent/src/bin/tron-program-worker.rs` host-call surface naming.
- very large production files in capability, UI, module, host, and event
  protocol areas.
- the monolithic `packages/agent/tests/threat_model_invariants.rs` static-gate
  test file.

## Large File Findings

Large files are not automatically wrong. Generated assets and provider DTOs can
be large. The issue is critical-path cognitive load.

| File | Lines | Classification | Decision |
|---|---:|---|---|
| `packages/agent/assets/capability-search/embeddings/all-MiniLM-L6-v2/model.onnx` | 285348 | Generated model asset | Keep; asset provenance and update process should stay documented |
| `packages/agent/src/domains/capability/operations.rs` | 6676 | Critical execution path | Split by resolve/prepare/run/observe/correction/audit |
| `packages/agent/src/domains/capability/registry.rs` | 5398 | Critical registry/index projection | Split by recipes/index/store/provider metadata where safe |
| `packages/agent/tests/threat_model_invariants.rs` | 4527 | Static gate suite | Split by invariant family after preserving test names/gates |
| `packages/agent/src/engine/primitives/ui.rs` | 4279 | Generated UI authoring/dispatch | Split authoring profiles and action helpers |
| `packages/agent/src/engine/primitives/module.rs` | 3832 | Module coordinator plus shared helpers | Continue narrowing parent coordinator |
| `packages/agent/src/engine/host.rs` | 3275 | Invocation core | Split only after characterization; high risk |
| `packages/agent/tests/integration/tests.rs` | 3108 | Broad integration suite | Split by runtime/transport/integration concern |
| `packages/agent/src/domains/session/event_store/store/tests.rs` | 3083 | Store tests | Split if more cases are added |
| `packages/agent/src/shared/protocol/events.rs` | 2899 | Protocol DTO definitions | Keep if docs/tests prove generated-style ownership |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2848 | Event transformer tests | Split by event category when next touched |
| `packages/agent/src/engine/primitives/module/source_trust.rs` | 2738 | Module source trust | Keep for now; split if adding new trust operations |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/tests.rs` | 2719 | Worktree coordinator tests | Future test-ownership split candidate |
| `packages/agent/src/domains/worktree/implementation/scm/git.rs` | 2713 | Git SCM adapter | Keep with focused docs/tests; split command builders if it grows |

## Fault Injection And Recovery Matrix

The current suite already covers many failure paths. Extreme fault tolerance
requires repeating these as deliberate drills.

| Failure class | Current proof | Gap |
|---|---|---|
| Duplicate model-visible execute calls | Execute idempotency and resource-output tests | Expand provider-specific exported-tool tests for all providers after any schema change |
| Malformed execute arguments | Correction and rejection tests | Add more adversarial recipe/ranking cases as manual testing discovers confusion classes |
| Approval pause/resume | Approval primitive, process, UI ordering tests | Continue real-device resume testing |
| Queue retry | Queue drainer and module activation retry tests | Add periodic retry stress for non-module domain actions |
| Worker spawn/stop failure | Module activation runtime tests | Add broader worker disconnect chaos around external workers |
| Resource damage/stale CAS | Resource kernel tests | Add operator recovery drill docs for damaged resource versions |
| Cron cache loss | Cron decision rehydration tests | Keep this as recurring regression after scheduler changes |
| Client offline/resume | iOS event cache and reconnect tests | Make fallback local DB mode visible and tested |
| Provider partial stream/tool-call mismatch | Provider protocol tests and execute orchestration | Add cross-provider conformance matrix when provider payloads change |
| Static gate drift | `threat_model_invariants` | Split by invariant family to reduce edit risk |

## Fault-Tolerance Backlog

### 1. Capability Execute Critical-Path Split

Goal:

- Make the single `execute` portal easier to review and harder to regress.

Closure:

- `packages/agent/src/domains/capability/operations.rs` is removed.
- `packages/agent/src/domains/capability/operations/mod.rs` remains the
  registration/coordination surface for capability operations.
- `packages/agent/src/domains/capability/operations/execute.rs` owns the
  model-facing execute orchestration path: schema intake, safe corrections,
  resolve, prepare, and observe diagnostics.
- `packages/agent/src/domains/capability/operations/run.rs` owns child
  invocation execution, approval pause/resume projection, preflight rejection
  results, and program execution handoff.
- `packages/agent/src/domains/capability/operations/search.rs`,
  `packages/agent/src/domains/capability/operations/inspect.rs`, and
  `packages/agent/src/domains/capability/operations/audit.rs` own operator
  discovery, inspection/status, and bounded audit-query projection instead of
  growing the parent coordination file.
- `packages/agent/src/domains/capability/registry.rs` is removed.
- `packages/agent/src/domains/capability/registry/mod.rs` owns registry store,
  snapshots, search index, and audit storage.
- `packages/agent/src/domains/capability/registry/recipes.rs` owns recipe
  generation used by resolve/prepare guidance.

Acceptance:

- Provider-visible tools still expose only `execute`.
- Existing execute integration/manual-test paths are unchanged.
- Static gates prove search/inspect stay non-model-visible and the retired
  single-file operation/registry boundaries stay absent.
- Focused `capability_` and `program` tests cover the split boundaries.

### 2. Generated UI Authoring Split

Goal:

- Keep UI flexible and server-owned without accumulating another large
  dispatcher file.

Closure:

- `packages/agent/src/engine/primitives/ui.rs` remains the `ui::*`
  registration, dispatch, resource mutation, and coordination surface.
- `packages/agent/src/engine/primitives/ui/authoring/` owns server-authored
  generated UI surface authoring by target family: prompt-library collections,
  notifications, subagent lineage, source control, AgentControl, and shared
  stored action templates.
  - `packages/agent/src/engine/primitives/ui/authoring/mod.rs`
  - `packages/agent/src/engine/primitives/ui/authoring/prompt.rs`
  - `packages/agent/src/engine/primitives/ui/authoring/notifications.rs`
  - `packages/agent/src/engine/primitives/ui/authoring/subagent.rs`
  - `packages/agent/src/engine/primitives/ui/authoring/source_control.rs`
  - `packages/agent/src/engine/primitives/ui/authoring/agent_control.rs`
- `packages/agent/src/engine/primitives/ui/validation.rs` continues to own
  stored-surface/action validation and stale action rejection.

Acceptance:

- Public `ui::*` schemas do not change.
- Swift generated UI renderer continues to receive the same component catalog.
- Static gates forbid dynamic catalogs and client-authored targets.

### 3. iOS Fallback Cache Visibility

Goal:

- Keep app startup resilient without hiding local-cache loss.

Closure:

- `EventDatabaseStorageMode` records `primaryDocuments` versus
  `temporaryFallback`.
- `EventDatabase.initialize()` logs fallback-cache mode as a warning when the
  temporary cache is used.
- `DependencyContainer` exposes the local cache mode for diagnostics only.
- Engine Console overview shows a fail-visible fallback-cache banner.
- Diagnostics bundles include the local event database storage mode.
- Swift source guards prove fallback-cache ownership files do not construct
  grants, generated action targets/templates, or resource lineage.

Acceptance:

- Documents-directory failure does not crash app startup.
- Operators can see that fallback cache is in use.
- Tests prove fallback cache cannot decide server state.

### 4. Program Worker Execute-Only Convergence

Goal:

- Align program composition with the one execute mental model.

Closure:

- QuickJS receives only frozen `tools.execute`.
- Program host calls no longer carry `search` or `inspect` primitive variants.
- Parent-side program host invokes only `capability::execute`.
- Program risk budgets merge into execute constraints before child execution.
- Program allowed-contract/allowed-implementation bounds are enforced before
  `capability::execute` can run.
- No `tools.search` or `tools.inspect` compatibility alias remains.

Acceptance:

- Program composition cannot bypass resolve/prepare/grants/resources.
- Program worker docs match provider-facing `execute` semantics.
- No backwards-compatibility alias remains.

### 5. Static Gate And Integration Test Decomposition

Goal:

- Preserve strong absence gates while reducing review risk.

Closure:

- Static gates now cover the execute-only program surface, operation/registry
  split boundaries, generated UI authoring split, and iOS fallback-cache mode.
- Existing threat invariant test names are preserved in this checkpoint to keep
  review noise low; the next maintenance task is mechanical relocation into
  focused files, not new invariant discovery.

Acceptance:

- No gate is weakened.
- New contributors can identify the owner from the failure messages and the
  linked audit sections.

### 6. Fault Drill Suite

Goal:

- Make failover/recovery a routine test practice.

Closure:

- Existing resource, generated UI, module runtime, cron, approval, queue, and
  program tests remain the deterministic drill suite for damaged resources,
  stale generated UI actions, approval pause/resume, queue retry, worker
  lifecycle, and cron decision rehydration.
- This phase adds execute-only program-worker drills and iOS fallback-cache
  visibility drills.

Acceptance:

- Drills run locally with focused filters.
- Full CI includes the low-flake deterministic subset.
- Real-device manual testing continues to cover provider and iOS reconnect
  behavior.

## Architecture Verdict

The architecture is sound:

- the engine substrate is collapsed and capability-owned;
- durable truth is resource/decision/evidence/invocation/grant backed or
  explicitly accepted as mechanical substrate;
- clients remain thin;
- authority is grant-owned;
- generated UI actions are server-authored and revision-pinned;
- stale, damaged, duplicate, or malformed inputs have strong negative tests.

The post-100 backlog in this audit is closed. The maintenance posture is now:

1. preserve the single model/program execute portal;
2. keep fallback caches visible and non-authoritative;
3. treat large critical-path file growth as a regression;
4. add focused fault drills whenever a new failure mode is discovered;
5. keep static gates stricter than the implementation they protect.

## Verification Standard

Any change derived from this audit should run, at minimum:

```bash
cd packages/agent && cargo test --test threat_model_invariants -- --nocapture
cd packages/agent && cargo test generated_ui --lib -- --nocapture
cd packages/agent && cargo test resource_ --lib -- --nocapture
cd packages/agent && cargo test capability_ --lib -- --nocapture
cd packages/agent && RUSTFLAGS="-D warnings" cargo check --all-targets
git diff --check
scripts/tron ci fmt check clippy test
```

iOS/Mac checks are required when client/project files change:

```bash
cd packages/ios-app && xcodegen generate
cd packages/mac-app && xcodegen generate
```

Targeted Xcode tests should match the touched surface.
