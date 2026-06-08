# Primitive Code Cleanup Scorecard

Created: 2026-06-08

Initial score: **0/100**

Current score: **70/100**

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
| `packages/ios-app` | retain | iOS package | SwiftUI mobile shell and generated Xcode project boundary. | Retain consolidated primitive shell source roots. |
| `packages/mac-app` | retain | Mac package | SwiftUI menu-bar wrapper and generated Xcode project boundary. | Consolidate `Sources` during PCC-7. |
| `packages/agent/src/app` | retain | Rust bootstrap | Server bootstrap, health, metrics, onboarding, shutdown. | Keep as top-level Rust root. |
| `packages/agent/src/transport` | retain | Rust transport | `/engine` client protocol, worker socket, auth gate. | Keep as top-level Rust root. |
| `packages/agent/src/engine` | collapse audit | Rust engine substrate | Live catalog, workers, queues, resources, traces, ledger, host. | Flatten unowned shards during PCC-4. |
| `packages/agent/src/domains` | collapse audit | Rust worker domains | Vertical retained domains and provider/session implementation. | Collapse small domains during PCC-3/PCC-5. |
| `packages/agent/src/shared` | retain | Rust foundation/protocol | IDs, errors, paths, DTOs, storage helpers, logging. | Keep if helpers remain shared by at least two owners. |
| `packages/agent/src/platform` | retain | platform integration | OS/vendor platform boundary. | Keep only platform-specific code. |
| `packages/ios-app/Sources/App` | retain | iOS app lifecycle | App entry, scene, delegates, lifecycle. | Keep. |
| `packages/ios-app/Sources/Assets.xcassets` | asset | iOS assets | Xcode asset catalog boundary. | Keep. |
| `packages/ios-app/Sources/Engine` | retain | iOS engine protocol/cache | Engine DTOs, protocol transport, event decoding, local event cache, repositories. | Keep as the only server/engine integration root. |
| `packages/ios-app/Sources/Resources` | asset | iOS resources | Fonts, localized strings, and generated icon layer assets. | Keep resource boundary. |
| `packages/ios-app/Sources/Session` | retain | iOS session state | Chat/session view models, messages, activity summaries, parsing, token accounting. | Keep as the only session-state root. |
| `packages/ios-app/Sources/Support` | retain | iOS support services | Dependency injection, diagnostics, pairing, storage, settings, concurrency, feedback, extensions, utilities. | Keep as non-UI support root. |
| `packages/ios-app/Sources/UI` | retain | iOS UI shell | Theme and SwiftUI views for chat, settings, onboarding, generic runtime surfaces. | Keep as the only UI source root. |
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
| `packages/agent/src/engine/types.rs` | 1008 | engine metadata contracts | Public worker/function/trigger/catalog metadata contracts now include the collapsed catalog-change types and restored Rustdoc. | PCC-4 |
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | 1182 | agent stream tests | Provider stream reconstruction behavior. | PCC-3 |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | 1038 | context tests | Compaction behavior and edge-case coverage. | PCC-3 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2140 | iOS reconstruction tests | Large stored-event reconstruction suite. | PCC-6 |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | 1531 | iOS static guards | Primitive shell absence and source guards. | PCC-6 |
| `packages/ios-app/Sources/Engine/Network/EngineConnection.swift` | 958 | iOS transport | WebSocket transport and request/response lifecycle. | PCC-6 |
| `packages/ios-app/Sources/UI/Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift` | 817 | iOS dynamic runtime UI | Generic runtime renderer. | PCC-6 |

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
- Rust engine cleanup shape stays flat where proven: the catalog type shard is
  folded into `engine/types.rs`, dead resource event shards stay deleted, and
  `engine/tests/mod.rs` remains declaration-only.
- Session persistence cleanup shape stays current: session worker deps/handler
  shards and one-file operation folders stay collapsed, SQLite docs describe
  only the fresh primitive schema, retired message queue payload DTOs stay
  absent, and v001 does not recreate old product tables.

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
| PCC-3 | Rust agent consolidation | 18 | passed_after_fix | rust_agent | Removed unused `fastembed`, `sqlite-vec`, `rquickjs`, `rquickjs-serde`, `image`, and `resvg` dependencies, refreshed `Cargo.lock`, deleted the retired `packages/agent/assets/capability-search/` bundle, collapsed `blob`, `logs`, `message`, and `system` contract/deps/handler shards into their owning `mod.rs` files, retargeted the aggregate domain catalog, regenerated the file inventory, and added static gates for dead dependencies and small-domain shape. | Engine substrate flattening remains PCC-4; session persistence flattening remains PCC-5; client/script/docs consolidation remain later rows. | PCC-3 Rust consolidation checkpoint |
| PCC-4 | Engine and primitive surface cleanup | 10 | passed_after_fix | engine_architecture | Collapsed the unowned `engine/types/catalog.rs` shard into `engine/types.rs`, folded the resource-store event/id helper into `resources/store.rs`, deleted the uncalled `resources/store/trace_events.rs` query extension, collapsed `capability::execute` deps/handler boilerplate into its worker module, removed empty local source directories left by earlier cleanup, regenerated the file inventory, and added a static gate for the retained engine/capability shape. Engine concern tests prove the retained catalog, grant, resource, state, queue, stream, trigger, ledger, host, worker, and `capability::execute` substrates still run. | Session/event persistence cleanup remains PCC-5; final adversarial scans remain PCC-10. | PCC-4 engine substrate checkpoint |
| PCC-5 | Session, trace, and persistence cleanup | 8 | passed_after_fix | storage | Collapsed session worker `deps`/`handlers` into `session/mod.rs`, collapsed the one-file `operations/` folder into `session/operations.rs`, rewrote stale SQLite/event-store docs that still described retired migration planes, deleted retired `message.queued`/`message.dequeued` payload DTOs, added parser rejection proof for those event strings, regenerated the file inventory, and added a cleanup invariant for the retained session persistence shape and old product schema absence. | Existing dense event repository tests remain intentionally over budget and listed; iOS queue/event client surfaces remain PCC-6. | PCC-5 session persistence checkpoint |
| PCC-6 | iOS app consolidation | 12 | passed_after_fix | ios | Deleted the prompt-queue UI/event/settings/client plane, removed Rust prompt queue message metadata shims, consolidated iOS `Sources` to `App`, `Engine`, `Session`, `Support`, `UI`, `Resources`, and assets, moved shared App Group transfer types into `Support/Share`, regenerated XcodeGen, updated README/iOS docs/path guards, renamed stale synchronous prompt stream wording to `apply_invoked`, regenerated the file inventory, and proved the shell with focused source guards/settings/share/session tests plus a retained-source residue scan. | Full app-wide iOS suite remains a final PCC-10 candidate; no open PCC-6 cleanup loops. | PCC-6 iOS consolidation checkpoint |
| PCC-7 | Mac app consolidation | 8 | pending | mac | `Sources` moves toward `App`, `Server`, `Wizard`, `MenuBar`, `Support`, and resources; project regenerated; targeted Mac tests pass. | macOS UI test breadth may stay source-level if no harness exists. | pending |
| PCC-8 | Scripts cleanup | 6 | pending | scripts | Dispatcher/helper/module split matches README, stale helpers/caches deleted, syntax checks and relevant status/dev health-gated checks pass. | Live service checks depend on local environment. | pending |
| PCC-9 | Docs and test cleanup | 8 | pending | docs_or_test_harness | Stale docs deleted or rewritten, redundant tests consolidated, static gates cover deleted product surfaces and folder drift, progressive disclosure docs updated. | Historical scorecards may retain deleted terms as evidence. | pending |
| PCC-10 | Final adversarial pass | 8 | pending | test_harness | Stale product/fallback/compat/dead-code scans, unused dependency checks, subagent review, broad verification, score math/status closeout, ledger, and final checkpoint commit. | None acceptable at closeout; successor scope must be explicit. | pending |

Total weight: **100**

## Next Test

PCC-7 starts Mac app consolidation. Begin with source-root ownership and
generated project audit:

```bash
find packages/mac-app/Sources -maxdepth 3 -type f -print | sort
```
