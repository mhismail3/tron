# Primitive Code Cleanup Scorecard

Created: 2026-06-08

Initial score: **0/100**

Current score: **22/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`primitive-code-cleanup-evidence-manifest.md`](primitive-code-cleanup-evidence-manifest.md)

Scope:
- Whole-repo structural cleanup for the primitive branch: Rust agent, iOS app,
  Mac wrapper, scripts, docs, tests, assets, generated project boundaries, and
  static gates.
- Remove stale product residue, dead code, compatibility scaffolding, fallback
  logic, tracked generated junk, and folders that no longer represent a real
  ownership boundary.
- Keep only directories justified by build, platform, persistence, provider,
  UI, generated/resource, test fixture, or maintainability boundaries.

Out of scope:
- Building successor self-adapting-agent behavior, new product workflows, or
  new generated-worker systems.
- Deleting local untracked build outputs such as `target`, `.build`,
  DerivedData, Xcode result bundles, or dependency caches without explicit user
  approval.
- Preserving old internal file paths, compatibility aliases, or migrations for
  deleted product behavior.

## Summary

This campaign makes the completed primitive branch structurally obvious. The
durable truth owners remain the Rust server, its event/resource/trace stores,
the thin iOS and Mac shells, and canonical docs/tests. A retained folder must
prove that it owns a boundary; otherwise its code is collapsed into the nearest
clear owner or deleted.

## Primitive And Plane Budget

Retained code should fit these primitive planes:

| Plane | Truth owner | Cleanup rule |
|-------|-------------|--------------|
| Server bootstrap | Rust `app`, `transport`, profile/path helpers | Keep only startup, health, auth, transport, and runtime wiring needed before an agent turn can run. |
| Primitive engine substrate | Rust `engine` and loop infrastructure domains | Keep state, stream, queue, resource, grant, trace, ledger, worker, and invocation surfaces only when runtime tests prove need. |
| Provider loop | Rust model provider domain | Keep provider framing, token/cost accounting, streaming conversion, and primitive-tool exchange; delete unused provider/tool dependencies. |
| Session truth | Rust session/event store plus iOS local cache | Keep append-only events, reconstruction, trace/session persistence, and bounded logs. |
| Client shells | iOS and Mac app sources | Keep pairing, chat, generic runtime rendering, settings, onboarding, diagnostics, and Mac server lifecycle surfaces. |
| Scripts | `scripts/tron`, command-family modules, shared helper libraries | Keep only contributor/build/runtime commands that are documented and exercised. |
| Documentation and evidence | README, source-local docs, scorecards, evidence manifests, static gates | Keep canonical, current docs; delete stale guides and aspirational claims. |

Do not create a new policy, compatibility, cache, or dashboard plane to avoid
deleting an old one. If a primitive needs state, it should be event/resource,
trace, queue, log, or agent-owned state truth, not a hidden side channel.

## Folder Justification Table

This table is the current baseline. Rows marked `collapse audit` are retained
only until the owning scorecard row proves whether they remain a boundary.

| Path | Classification | Owner | Reason | Target action |
|------|----------------|-------|--------|---------------|
| `.claude` | retain | contributor tooling | Repo-local contributor guidance and automation metadata. | Audit for stale branch claims during docs cleanup. |
| `.codex` | retain | Codex app integration | Local Codex environment actions for this workspace. | Retain if actions match current CLI surface. |
| `.github` | retain | CI/release boundary | GitHub workflows, templates, and dependency policy. | Audit only if commands or package layout change. |
| `packages` | retain | package boundary | Contains the Rust agent, iOS app, and Mac wrapper package roots. | Retain. |
| `scripts` | retain | CLI boundary | Workspace and installed helper scripts. | Consolidate helpers during PCC-8. |
| `packages/agent` | retain | Rust server package | Single Rust crate plus server docs/assets/tests. | Retain; remove stale examples/assets if unowned. |
| `packages/ios-app` | retain | iOS package | SwiftUI mobile shell and generated Xcode project boundary. | Consolidate `Sources` during PCC-6. |
| `packages/mac-app` | retain | Mac package | SwiftUI menu-bar wrapper and generated Xcode project boundary. | Consolidate `Sources` during PCC-7. |
| `packages/agent/src/app` | retain | Rust bootstrap | Server bootstrap, health, metrics, onboarding, shutdown. | Keep as top-level Rust root. |
| `packages/agent/src/transport` | retain | Rust transport | `/engine` client protocol, worker socket, auth gate. | Keep as top-level Rust root. |
| `packages/agent/src/engine` | collapse audit | Rust engine substrate | Live catalog, workers, queues, resources, traces, ledger, host. | Flatten unowned shards during PCC-4. |
| `packages/agent/src/domains` | collapse audit | Rust worker domains | Vertical retained domains and provider/session implementation. | Collapse small domains during PCC-3/PCC-5. |
| `packages/agent/src/shared` | retain | Rust foundation/protocol | IDs, errors, paths, DTOs, storage helpers, logging. | Keep if helpers remain shared by at least two owners. |
| `packages/agent/src/platform` | retain | platform integration | OS/vendor platform boundary. | Keep only platform-specific code. |
| `packages/ios-app/Sources/App` | retain | iOS app lifecycle | App entry, scene, delegates, lifecycle. | Keep. |
| `packages/ios-app/Sources/Core` | collapse audit | iOS event/DI core | DI, event dispatch, plugins, transformers. | Fold into `Engine` or `Session` target shape during PCC-6. |
| `packages/ios-app/Sources/Database` | collapse audit | iOS local cache | SQLite event cache and repositories. | Fold into `Engine` unless DB boundary remains large. |
| `packages/ios-app/Sources/Extensions` | collapse audit | iOS utilities | Type/view extensions. | Fold into `Support` unless broad sharing justifies root. |
| `packages/ios-app/Sources/IconLayers` | asset | iOS app icon source | Source layers for generated app icon assets. | Keep as asset/generation boundary if tracked intentionally. |
| `packages/ios-app/Sources/Models` | collapse audit | iOS DTOs | Engine protocol, session, settings, event models. | Fold into `Engine`, `Session`, or `UI` during PCC-6. |
| `packages/ios-app/Sources/Protocols` | collapse audit | iOS abstraction leftovers | Small protocol files and test seams. | Delete or fold during PCC-6. |
| `packages/ios-app/Sources/Resources` | asset | iOS resources | Localized strings and fixtures. | Keep resource boundary. |
| `packages/ios-app/Sources/Services` | collapse audit | iOS transport/support services | Engine network, pairing, diagnostics, storage. | Split into target `Engine` and `Support` roots during PCC-6. |
| `packages/ios-app/Sources/Theme` | collapse audit | iOS UI styling | Colors, typography, design tokens. | Fold into `UI` unless reusable theme boundary remains. |
| `packages/ios-app/Sources/Utilities` | collapse audit | iOS helpers | Shared utility functions. | Fold into `Support`. |
| `packages/ios-app/Sources/ViewModels` | collapse audit | iOS session/UI state | Chat, settings, onboarding state. | Fold into `Session` or `UI`. |
| `packages/ios-app/Sources/Views` | collapse audit | iOS UI shell | Chat, settings, onboarding, generic runtime surfaces. | Move toward `UI` target shape. |
| `packages/ios-app/Sources/Assets.xcassets` | asset | iOS assets | Xcode asset catalog boundary. | Keep. |
| `packages/mac-app/Sources/Assets.xcassets` | asset | Mac assets | Xcode asset catalog boundary. | Keep. |
| `packages/mac-app/Sources/MenuBar` | retain | Mac menu-bar shell | Menu model, controller, actions. | Keep as target root. |
| `packages/mac-app/Sources/Resources` | asset | Mac resources | Bundled resources and helper metadata. | Keep. |
| `packages/mac-app/Sources/Services` | collapse audit | Mac server/support services | Server lifecycle, paths, feedback, diagnostics. | Split into `Server` and `Support` during PCC-7. |
| `packages/mac-app/Sources/Theme` | collapse audit | Mac styling | Styling helpers. | Fold into `Support` or `UI` owner if small. |
| `packages/mac-app/Sources/Wizard` | retain | Mac install/pairing wizard | Wizard state and views. | Keep; collapse tiny step files if unowned. |

## Large File Budgets

Default budgets:
- Rust source/test target: **<= 1,000 LOC** unless this table names the owner,
  reason, and cleanup row.
- Swift source/test target: **<= 800 LOC** unless this table names the owner,
  reason, and cleanup row.
- Generated files, assets, lockfiles, and Xcode project files are excluded.

Current over-budget exceptions:

| Path | Current LOC | Owner | Reason | Cleanup row |
|------|-------------|-------|--------|-------------|
| `packages/agent/tests/primitive_engine_teardown_plan_invariants.rs` | 2258 | teardown static gates | Completed teardown gate is historical proof; new cleanup gates should move to separate files. | PCC-9 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | 1571 | session persistence tests | Dense event-store behavior suite. | PCC-5 |
| `packages/agent/src/domains/auth/provider_credentials/storage/tests.rs` | 1383 | auth storage tests | Credential persistence behavior suite. | PCC-3 |
| `packages/agent/src/engine/tests/resource_kernel.rs` | 1196 | engine resource tests | Resource substrate behavior suite. | PCC-4 |
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | 1182 | agent stream tests | Provider stream reconstruction behavior. | PCC-3 |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | 1038 | context tests | Compaction behavior and edge-case coverage. | PCC-3 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2140 | iOS reconstruction tests | Large stored-event reconstruction suite. | PCC-6 |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | 1531 | iOS static guards | Primitive shell absence and source guards. | PCC-6 |
| `packages/ios-app/Sources/Services/Network/EngineConnection.swift` | 958 | iOS transport | WebSocket transport and request/response lifecycle. | PCC-6 |
| `packages/ios-app/Sources/Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift` | 817 | iOS dynamic runtime UI | Generic runtime renderer. | PCC-6 |

## Static Gates

`packages/agent/tests/primitive_code_cleanup_invariants.rs` owns the cleanup
planning gates:
- this scorecard and evidence manifest exist and are linked from `README.md`;
- every retained top-level source directory appears in the folder-justification
  table;
- removed product terms stay absent outside scorecards, evidence manifests,
  inventory docs, and static absence tests;
- over-budget Rust and Swift files must be listed in the large-file budget
  table;
- tracked generated/cache junk such as Python bytecode caches, dependency
  folders, Rust build outputs, and Xcode result bundles is absent.

## Operating Loop

1. Pick the highest-value pending row.
2. Audit the real files and current ownership boundaries before moving code.
3. Add or identify the smallest covering test first.
4. Collapse or delete unowned folders and remove adjacent dead/fallback code.
5. Update source-local docs, README, scorecard, evidence manifest, and ledger.
6. Run focused verification for the touched area.
7. Commit each coherent row or row group before continuing.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence contract | Residual risk | Checkpoint |
|----|------|--------|--------|-------|-------------------|---------------|------------|
| PCC-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix | docs_or_scorecard | New cleanup scorecard, evidence manifest, README links, static invariant test, folder-justification baseline, large-file budget, tracked-junk scan, and focused cleanup invariant output. The gate first failed on stale deleted-product wording in iOS rule docs and a non-static settings test, then passed after the wording was removed or generalized. | None. | PCC-0 setup checkpoint |
| PCC-1 | Inventory and folder justification | 12 | passed_after_fix | architecture | Added [`primitive-code-cleanup-inventory.md`](primitive-code-cleanup-inventory.md) and [`primitive-code-cleanup-file-inventory.tsv`](primitive-code-cleanup-file-inventory.tsv). The inventory classifies all 1339 tracked/current cleanup artifact paths: 686 `retain`, 551 `collapse`, 74 `asset`, 21 `delete`, and 7 `generated`; records the canonical target tree; and names every delete/collapse owner row. Static gates now prove every tracked file has an inventory row and the README links both inventory artifacts. | Collapse/delete work remains owned by PCC-3 through PCC-9; no folder is unowned because every unresolved area has a cleanup row. | PCC-1 inventory checkpoint |
| PCC-2 | Root and generated artifact hygiene | 5 | passed_after_fix | repo_hygiene | Tracked generated/cache scan found no tracked `__pycache__`, `.pyc`, `.xcresult`, `target`, `node_modules`, or `DerivedData` paths. Root `.gitignore` now covers project-local Rust, Xcode, Node, Python, benchmark, temp, log, debug, and worktree artifacts, including `DerivedData/`, `*.dSYM/`, `*.pyc`, and `.pytest_cache/`. Static gates assert both absence and ignore coverage. No untracked build outputs were deleted. | Local untracked ignored outputs may exist and are intentionally left alone. | PCC-2 hygiene checkpoint |
| PCC-3 | Rust agent consolidation | 18 | running | rust_agent | Dependency cleanup checkpoint removed unused `fastembed`, `sqlite-vec`, `rquickjs`, `rquickjs-serde`, `image`, and `resvg` dependencies, refreshed `Cargo.lock`, deleted the retired `packages/agent/assets/capability-search/` bundle, regenerated the file inventory, and added a static dead-dependency gate. Remaining PCC-3 work owns small-domain consolidation and any further Rust source flattening. | Small-domain collapse and large Rust boundary audits remain open. | PCC-3 dependency cleanup checkpoint |
| PCC-4 | Engine and primitive surface cleanup | 10 | pending | engine_architecture | Engine shards flattened where unowned; runtime need for resources/state/queues/traces/catalog/grants/workers proven; primitive loop tests pass. | Some substrate may remain until final adversarial proof. | pending |
| PCC-5 | Session, trace, and persistence cleanup | 8 | pending | storage | Persistence helpers collapsed where possible, schema/query owners retained only where needed, trace/session/event truth remains agent-queryable, and old product schema/event absence gates pass. | Existing large tests may need decomposition. | pending |
| PCC-6 | iOS app consolidation | 12 | pending | ios | `Sources` moves toward `App`, `Engine`, `Session`, `UI`, `Support`, `Resources`, assets, and extension boundaries; project regenerated; source guards and targeted UI tests pass. | Simulator/device proof may require environment availability. | pending |
| PCC-7 | Mac app consolidation | 8 | pending | mac | `Sources` moves toward `App`, `Server`, `Wizard`, `MenuBar`, `Support`, and resources; project regenerated; targeted Mac tests pass. | macOS UI test breadth may stay source-level if no harness exists. | pending |
| PCC-8 | Scripts cleanup | 6 | pending | scripts | Dispatcher/helper/module split matches README, stale helpers/caches deleted, syntax checks and relevant status/dev health-gated checks pass. | Live service checks depend on local environment. | pending |
| PCC-9 | Docs and test cleanup | 8 | pending | docs_or_test_harness | Stale docs deleted or rewritten, redundant tests consolidated, static gates cover deleted product surfaces and folder drift, progressive disclosure docs updated. | Historical scorecards may retain deleted terms as evidence. | pending |
| PCC-10 | Final adversarial pass | 8 | pending | test_harness | Stale product/fallback/compat/dead-code scans, unused dependency checks, subagent review, broad verification, score math/status closeout, ledger, and final checkpoint commit. | None acceptable at closeout; successor scope must be explicit. | pending |

Total weight: **100**

## Next Test

Continue PCC-3 with the small-domain collapse audit:

```bash
find packages/agent/src/domains/blob packages/agent/src/domains/logs packages/agent/src/domains/message packages/agent/src/domains/system -maxdepth 2 -type f -print | sort
```
