# Primitive Code Cleanup Scorecard

Created: 2026-06-08

Initial score: **0/100**

Current score: **100/100**

Status: **completed**

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

This table is the current retained baseline after PCC-10. Every listed directory
has a build, platform, persistence, provider, UI, generated/resource, test, or
maintainability owner.

| Path | Classification | Owner | Reason | Target action |
|------|----------------|-------|--------|---------------|
| `.codex` | retain | Codex app integration | Local Codex environment actions for this workspace. | Retain if actions match current CLI surface. |
| `.github` | retain | CI/release boundary | GitHub workflows, templates, and dependency policy. | Audit only if commands or package layout change. |
| `packages` | retain | package boundary | Contains the Rust agent, iOS app, and Mac wrapper package roots. | Retain. |
| `scripts` | retain | CLI boundary | Workspace and installed helper scripts. | Retain cleaned manual dispatcher, command modules, installed runtime helpers, release helpers, hooks, benchmarks, and device helpers. |
| `packages/agent` | retain | Rust server package | Single Rust crate plus server docs/assets/tests. | Retain; remove stale examples/assets if unowned. |
| `packages/ios-app` | retain | iOS package | SwiftUI mobile shell and generated Xcode project boundary. | Retain consolidated primitive shell source roots. |
| `packages/mac-app` | retain | Mac package | SwiftUI menu-bar wrapper and generated Xcode project boundary. | Retain consolidated primitive wrapper source roots. |
| `packages/agent/src/app` | retain | Rust bootstrap | Server bootstrap, health, metrics, onboarding, shutdown. | Keep as top-level Rust root. |
| `packages/agent/src/transport` | retain | Rust transport | `/engine` client protocol, worker socket, auth gate. | Keep as top-level Rust root. |
| `packages/agent/src/engine` | retain | Rust engine substrate | Live catalog, workers, queues, resources, traces, ledger, host. | Retain after PCC-4 flattened unowned shards. |
| `packages/agent/src/domains` | retain | Rust worker domains | Vertical retained domains and provider/session implementation. | Retain after PCC-3/PCC-5 collapsed small-domain and session boilerplate. |
| `packages/agent/src/shared` | retain | Rust foundation/protocol | IDs, errors, paths, DTOs, storage helpers, logging. | Keep if helpers remain shared by at least two owners. |
| `packages/agent/src/platform` | retain | platform integration | OS/vendor platform boundary. | Keep only platform-specific code. |
| `packages/ios-app/Sources/App` | retain | iOS app lifecycle | App entry, scene, delegates, lifecycle. | Keep. |
| `packages/ios-app/Sources/Assets.xcassets` | asset | iOS assets | Xcode asset catalog boundary. | Keep. |
| `packages/ios-app/Sources/Engine` | retain | iOS engine protocol/cache | Engine DTOs, protocol transport, event decoding, local event cache, repositories. | Keep as the only server/engine integration root. |
| `packages/ios-app/Sources/Resources` | asset | iOS resources | Fonts, localized strings, and generated icon layer assets. | Keep resource boundary. |
| `packages/ios-app/Sources/Session` | retain | iOS session state | Chat/session view models, messages, activity summaries, parsing, token accounting. | Keep as the only session-state root. |
| `packages/ios-app/Sources/Support` | retain | iOS support services | Composition, diagnostics, feedback, foundation, pairing, share, and storage owners. | Keep as non-UI support root with no broad utility/service buckets. |
| `packages/ios-app/Sources/UI` | retain | iOS UI shell | Theme and SwiftUI views for chat, settings, onboarding, generic runtime surfaces. | Keep as the only UI source root. |
| `packages/mac-app/Sources/App` | retain | Mac app lifecycle | App entry, environment setup, command-mode startup, and runtime variant selection. | Keep. |
| `packages/mac-app/Sources/Assets.xcassets` | asset | Mac assets | Xcode asset catalog boundary. | Keep. |
| `packages/mac-app/Sources/MenuBar` | retain | Mac menu-bar shell | Menu model, controller, actions. | Keep as target root. |
| `packages/mac-app/Sources/Resources` | asset | Mac resources | Bundled resources and helper metadata. | Keep. |
| `packages/mac-app/Sources/Server` | retain | Mac server lifecycle | LaunchAgent, SMAppService, health polling, paths, token reads, and server control. | Keep. |
| `packages/mac-app/Sources/Support` | retain | Mac support services | Shared models, onboarding probes, pairing, feedback composition, diagnostics, theme, and formatting helpers. | Keep. |
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
| `packages/agent/src/engine/authority/grants/authorization.rs` | 2840 | Engine authority grants owner | Broad capability-invocation authorization scanner retained while accepted Slice 24C adds exact delegated subagent task selectors for `subagent_launch/status/result/cancel` alongside existing module-program-execution exact runtime/job selectors; future authority slices should split per-domain scanner helpers before growing this file further. | PCC-10/P3MSA-S23B/P3MSA-INV-009/P3MSA-INV-011 |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs` | 1302 | Capability runtime grant owner | Runtime capability grant derivation retained while accepted Slice 24C derives exact delegated subagent task selectors and delegated module refs under `capability::execute`; future grant slices should split per-domain grant policies before growing this file further. | PCC-10/SACB-10/P3MSA-INV-009/P3MSA-INV-011 |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/grant_tests.rs` | 1114 | Capability runtime grant test owner | Accepted Slice 24C keeps subagent delegation runtime-grant regressions with existing execute-resource grant tests; split restored resource-family and subagent delegated-grant fixtures into focused modules before adding more execute-resource families. | PCC-10/P3MSA-INV-011 |
| `packages/agent/src/domains/capability/contract.rs` | 1030 | Capability execute contract owner | Provider-visible `capability::execute` schema remains centralized while accepted restoration slices and accepted Slice 24C docs preserve the single operation contract surface. | PCC-10/P2AER-INV-013/P3MSA-INV-011 |
| `packages/agent/src/domains/capability/operations/module_program_execution_tests.rs` | 1210 | Capability execute test owner | Accepted Slice 24C extends accepted Slice 24B module-program-execution integration coverage with subagent delegated launch/replay exact-selector fixtures and provider-safety checks. | PCC-10/P3MSA-INV-010/P3MSA-INV-011 |
| `packages/agent/src/domains/subagents/execution.rs` | 1171 | Subagents domain owner | Accepted Slice 24C keeps controlled subagent launch/status/result/cancel lifecycle and exact task-selector enforcement together with delegated module-program execution binding checks. | PCC-10/P3MSA-INV-011 |
| `packages/agent/src/domains/git/service.rs` | 1461 | Git domain service | Slice 6A/6B/6C/6D source-control service covering trusted repository facts, bounded status/diff command helpers, non-interactive commit execution, pure staged-index tree evidence, shared Git command status helpers, and locked symbolic-HEAD movement. | PCC-6/P2AER-INV-013 |
| `packages/agent/src/domains/git/tests.rs` | 2718 | Git domain tests | Slice 6A/6B/6C/6D source-control tests covering status/diff evidence, index-only stage/unstage, staged-index commit evidence, branch-start evidence, rollback, and HEAD-drift guards, path/conflict/idempotency/resource guards, hook/prompt suppression, and provider-visible `capability::execute` routing. | PCC-6/P2AER-INV-013 |
| `packages/agent/src/domains/jobs/service.rs` | 1175 | Jobs domain service | Phase 2 Slice 5A durable jobs lifecycle service remains above the PCC budget with reconciliation, finalization, cleanup, and output-retention helpers consolidated under the jobs owner. | PCC-10/TPC-3 |
| `packages/agent/src/domains/memory/tests.rs` | 1101 | Memory domain tests | Slice 18A query/decision evidence tests extend the existing memory foundation coverage for disabled mode, record lifecycle, redaction, prompt trace, migration, scope isolation, idempotency, authority denial, and provider-safe inspection. | PCC-10/P2AER-INV-015/P2AER-INV-016 |
| `packages/agent/tests/baseline_pre_restoration_closure_invariants.rs` | 1011 | BPRC invariant owner | Large static invariant suite covering baseline-restoration closure, accepted-slice lineage, old product-surface absence, and Slice 10A inert subagent lifecycle guard updates. | PCC-10/BPRC-3/P2AER-INV-009 |
| `packages/agent/tests/ios_affordance_restoration_map_invariants.rs` | 1106 | IARM invariant owner | Large static invariant suite covering historical map closure, stale wording, physical-device redaction, queue/phase anchors, and APNs defer guards. | PCC-6/IARM-9 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2140 | iOS reconstruction tests | Large stored-event reconstruction suite. | PCC-6 |
| `packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` | 1799 | iOS static guards | Primitive shell absence, source guards, and HRA hierarchy gates. | PCC-6/HRA-8/HRA-11 |

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
- Mac wrapper cleanup shape stays current: app lifecycle, server lifecycle, and
  support services live under `Sources/App`, `Sources/Server`, and
  `Sources/Support`; root Swift files plus old `Sources/Services` and
  `Sources/Theme` roots stay absent.
- Scripts cleanup shape stays manual and documented: `scripts/tron` remains the
  dispatcher, `tron.d/` contains only large manual command families,
  `tron-lib.d/` contains installed-runtime helpers, and the automatic
  deployment watcher stays deleted.
- Docs and examples stay current: the stale root `retired helper tree` helper tree and
  retired `packages/agent/examples/local-packs/` examples stay deleted; package
  `retired helper tree` rule trees stay deleted; retained docs/source stay free of retired
  product terms; and the file inventory has no unresolved `collapse` or
  `delete` rows.
- Final residue cleanup stays enforced: unused direct Rust dependencies,
  dead setup directories, retired iOS git/cron/import DTOs, stale bootstrap
  grants, and removed import-atomic persistence paths stay absent.

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
| PCC-1 | Inventory and folder justification | 12 | passed_after_fix | architecture | Added [`primitive-code-cleanup-inventory.md`](primitive-code-cleanup-inventory.md) and [`primitive-code-cleanup-file-inventory.tsv`](primitive-code-cleanup-file-inventory.tsv). The inventory now classifies all 1,872 tracked/current cleanup artifact paths: 1,795 `retain`, 70 `asset`, and 7 `generated`; records the canonical target tree; and names every retained owner row through the Phase 2 Slice 13 accepted notification/device foundation. Static gates prove every tracked file has an inventory row and the README links both inventory artifacts. | No unresolved collapse/delete rows remain; new tracked files must add owner rows with the implementing slice. | PCC-1 inventory checkpoint |
| PCC-2 | Root and generated artifact hygiene | 5 | passed_after_fix | repo_hygiene | Tracked generated/cache scan found no tracked `__pycache__`, `.pyc`, `.xcresult`, `target`, `node_modules`, or `DerivedData` paths. Root `.gitignore` now covers project-local Rust, Xcode, Node, Python, benchmark, temp, log, debug, and worktree artifacts, including `DerivedData/`, `*.dSYM/`, `*.pyc`, and `.pytest_cache/`. Static gates assert both absence and ignore coverage. No untracked build outputs were deleted. | Local untracked ignored outputs may exist and are intentionally left alone. | PCC-2 hygiene checkpoint |
| PCC-3 | Rust agent consolidation | 18 | passed_after_fix | rust_agent | Removed unused `fastembed`, `sqlite-vec`, `rquickjs`, `rquickjs-serde`, `image`, and `resvg` dependencies, refreshed `Cargo.lock`, deleted the retired `packages/agent/assets/capability-search/` bundle, collapsed `blob`, `logs`, `message`, and `system` contract/deps/handler shards into their owning `mod.rs` files, retargeted the aggregate domain catalog, regenerated the file inventory, and added static gates for dead dependencies and small-domain shape. | Engine substrate flattening remains PCC-4; session persistence flattening remains PCC-5; client/script/docs consolidation remain later rows. | PCC-3 Rust consolidation checkpoint |
| PCC-4 | Engine and primitive surface cleanup | 10 | passed_after_fix | engine_architecture | Collapsed the unowned `engine/types/catalog.rs` shard into `engine/types.rs`, folded the resource-store event/id helper into `resources/store.rs`, deleted the uncalled `resources/store/trace_events.rs` query extension, collapsed `capability::execute` deps/handler boilerplate into its worker module, removed empty local source directories left by earlier cleanup, regenerated the file inventory, and added a static gate for the retained engine/capability shape. Engine concern tests prove the retained catalog, grant, resource, state, queue, stream, trigger, ledger, host, worker, and `capability::execute` substrates still run. | Session/event persistence cleanup remains PCC-5; final adversarial scans remain PCC-10. | PCC-4 engine substrate checkpoint |
| PCC-5 | Session, trace, and persistence cleanup | 8 | passed_after_fix | storage | Collapsed session worker `deps`/`handlers` into `session/mod.rs`, collapsed the one-file `operations/` folder into `session/operations.rs`, rewrote stale SQLite/event-store docs that still described retired migration planes, deleted retired `message.queued`/`message.dequeued` payload DTOs, added parser rejection proof for those event strings, regenerated the file inventory, and added a cleanup invariant for the retained session persistence shape and old product schema absence. | Existing dense event repository tests remain intentionally over budget and listed; iOS queue/event client surfaces remain PCC-6. | PCC-5 session persistence checkpoint |
| PCC-6 | iOS app consolidation | 12 | passed_after_fix | ios | Deleted the prompt-queue UI/event/settings/client plane, removed Rust prompt queue message metadata shims, consolidated iOS `Sources` to `App`, `Engine`, `Session`, `Support`, `UI`, `Resources`, and assets, moved shared App Group transfer types into `Support/Share`, regenerated XcodeGen, updated README/iOS docs/path guards, renamed stale synchronous prompt stream wording to `apply_invoked`, regenerated the file inventory, and proved the shell with focused source guards/settings/share/session tests plus a retained-source residue scan. | Full app-wide iOS suite remains a final PCC-10 candidate; no open PCC-6 cleanup loops. | PCC-6 iOS consolidation checkpoint |
| PCC-7 | Mac app consolidation | 8 | passed_after_fix | mac | Consolidated Mac `Sources` to `App`, `Server`, `Support`, `Wizard`, `MenuBar`, resources, and assets; moved app lifecycle, LaunchAgent/server, support/theme/pairing/feedback owners out of root `Services`/`Theme`; kept menu-bar feedback status formatting at the menu-bar boundary; regenerated XcodeGen; updated README/Mac docs/rules/tests/inventory; and added a static gate for the retained Mac primitive roots. | Final PCC-10 broad stale/fallback scan remains; no PCC-7-specific open loops. | PCC-7 Mac consolidation checkpoint |
| PCC-8 | Scripts cleanup | 6 | passed_after_fix | scripts | Deleted the automatic `scripts/auto-deploy` watcher and its `tron auto-deploy` launchd module, removed the command from workspace/installed CLI dispatch, removed stale auto-deploy runtime constants and Mac path constants, kept the manual contributor command as the documented user-run path, marked retained script helpers/modules in the inventory, and added a static gate proving the automatic deploy path stays absent. | Live service checks remain environment-dependent; syntax and static gates cover the script cleanup surface. | PCC-8 scripts cleanup checkpoint |
| PCC-9 | Docs and test cleanup | 8 | passed_after_fix | docs_or_test_harness | Deleted the stale root `retired helper tree` contributor helper tree and the retired `packages/agent/examples/local-packs/` worker-pack examples, removed the README `retired helper tree` structure claim, rewrote the Mac test-organization note that still promised a future PCC-9 cleanup, audited iOS/Mac test roots as retained behavior-owned suites under recursive XcodeGen test targets, regenerated the file inventory to 1282 retained/generated/asset paths with no unresolved `collapse` or `delete` rows, and added a static gate for the deleted docs/example surfaces. | Historical scorecards and static gates may retain deleted terms as evidence. Final adversarial scans remain PCC-10. | PCC-9 docs/test cleanup checkpoint |
| PCC-10 | Final adversarial pass | 8 | passed_after_fix | test_harness | Ran retained-surface scans, unused-dependency checks, and an adversarial subagent review. Fixed real blockers: pruned unused direct Rust dependencies and lockfile residue; deleted package-local `retired helper tree` rule trees; deleted the retired iOS git DTO file and regenerated XcodeGen; removed iOS cron/import error DTO cases; removed dead `~/.tron/skills`, `workspace/inbox`, `workspace/automations`, and `workspace/inbox/voice-notes` setup paths plus the unused inbox path helper; removed stale `cron-scheduler`, `mcp-catalog-refresh`, and `agent-worker-guide` bootstrap grants; removed dead model routing `policy_profile`/profile-name presentation residue; removed uncalled event-store import-atomic API and server import error mapping; and updated `scripts/tron ci` to run retained primitive invariant/trace targets instead of deleted `threat_model_invariants`. | None. | PCC-10 final cleanup checkpoint |

Total weight: **100**

## Closeout

Closeout complete. The final verification command set is recorded in
[`primitive-code-cleanup-evidence-manifest.md`](primitive-code-cleanup-evidence-manifest.md).

```bash
scripts/tron ci fmt check clippy test
```
