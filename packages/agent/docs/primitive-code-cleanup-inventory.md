# Primitive Code Cleanup Inventory

Created: 2026-06-08

Status: `passed_after_fix`

Scorecard row: `PCC-1`

Last updated: 2026-06-08 during `HRA-16` final adversarial closeout.

Machine-readable inventory:
[`primitive-code-cleanup-file-inventory.tsv`](primitive-code-cleanup-file-inventory.tsv)

## Source Audit Commands

```bash
git status --short
git ls-files
find packages/agent/src -name mod.rs -print | sort
find packages/ios-app/Sources packages/mac-app/Sources -maxdepth 3 -type d -print | sort
git ls-files | awk -F/ '{if (NF==1) k="<root>"; else if ($1=="packages") k=$1"/"$2; else k=$1} {count[k]++} END {for (k in count) print count[k], k}' | sort -k2
git ls-files | awk -F. 'NF>1 {ext=$NF; count[ext]++} NF==1 {count["<none>"]++} END {for (ext in count) print count[ext], ext}' | sort -nr
```

## Classification Vocabulary

| Classification | Meaning |
|----------------|---------|
| `retain` | Keep as a real ownership, build, platform, persistence, provider, UI, test, docs, or config boundary. |
| `collapse` | Keep only until the owning row folds the file into a clearer parent or proves the boundary remains necessary. |
| `delete` | Delete candidate; no move happens until the owning implementation row proves no retained primitive needs it. |
| `generated` | Tracked generated or lock artifact whose source of truth is another file/tool. |
| `asset` | Binary/resource/fixture asset; keep only when the owning package still uses it. |

## Inventory Counts

| Classification | Files | Primary owner |
|----------------|-------|---------------|
| `retain` | 1315 | Current package/config/test/doc boundaries |
| `asset` | 53 | iOS/Mac resources and benchmark baselines |
| `generated` | 7 | XcodeGen, Cargo, and package-manager outputs |
| **Total** | **1375** | Whole repo |

## Current Tracked Package Counts

| Area | Files |
|------|-------|
| `.codex` | 2 |
| `.github` | 8 |
| root files | 5 |
| `packages/agent` | 576 |
| `packages/ios-app` | 643 |
| `packages/mac-app` | 119 |
| `scripts` | 22 |

The count excludes untracked local build outputs. PCC-2 owns recurring local
artifact hygiene and must not delete untracked local directories without user
approval.

## Canonical Target Tree

This target tree constrains later moves. A folder not listed here must either be
deleted, folded into one of these owners, or added back with explicit scorecard
evidence.

```text
tron/
+-- .codex/                    Codex workspace actions and local skills
+-- .github/                   CI, release, issue, and PR workflow config
+-- packages/
|   +-- agent/
|   |   +-- src/
|   |   |   +-- app/            Rust bootstrap and server lifecycle
|   |   |   +-- transport/      /engine and worker transport boundaries
|   |   |   +-- engine/         Primitive substrate after PCC-4 flattening
|   |   |   +-- domains/        Retained loop domains after PCC-3/PCC-5 collapse
|   |   |   +-- shared/         IDs, errors, paths, DTOs, storage/log helpers
|   |   |   +-- platform/       OS/vendor integrations only
|   |   +-- defaults/           Bundled profile defaults
|   |   +-- docs/               Active scorecards, evidence, inventory
|   |   +-- tests/              Concern-owned integration/static tests
|   +-- ios-app/
|   |   +-- Sources/
|   |   |   +-- App/            App entry, lifecycle, delegates
|   |   |   +-- Engine/         WebSocket transport, DTOs, event plugins, cache
|   |   |   +-- Session/        Chat/session state and message transformation
|   |   |   +-- UI/             Chat, input, settings, onboarding, dynamic surfaces
|   |   |   +-- Support/        Composition, diagnostics, feedback, foundation, pairing, share, storage
|   |   |   +-- Resources/      Fonts, strings, fixtures
|   |   |   +-- Assets.xcassets/
|   |   |   +-- IconLayers/
|   |   |   +-- Info.plist
|   |   |   +-- PrivacyInfo.xcprivacy
|   |   +-- ShareExtension/     Separate Xcode target boundary
|   |   +-- Tests/
|   |   +-- project.yml         XcodeGen source of truth
|   +-- mac-app/
|       +-- Sources/
|       |   +-- App/
|       |   |   +-- Lifecycle/   Entry, runtime variant, startup maintenance
|       |   |   +-- CommandMode/ Internal command-mode entry points
|       |   |   +-- Composition/ Environment setup and DI
|       |   +-- Server/
|       |   |   +-- LaunchAgent/ SMAppService and LaunchAgent protocol boundary
|       |   |   +-- Health/      Ping, health awaiter, status poller
|       |   |   +-- Paths/       TronPaths and profile settings TOML cache
|       |   |   +-- PairingToken/ Bearer token reader
|       |   |   +-- ProcessControl/Dev stopper, probe, lock, uninstall
|       |   +-- MenuBar/        Actions, controller, presentation
|       |   +-- Wizard/         Flow, steps, and components
|       |   +-- Support/        Diagnostics, feedback, foundation, onboarding, pairing, theme
|       |   +-- Resources/
|       |   +-- Assets.xcassets/
|       |   +-- Info.plist
|       +-- Tests/              Mirrors App, Server, MenuBar, Support, Wizard, Infrastructure
|       +-- project.yml         XcodeGen source of truth
+-- scripts/
    +-- tron                    Dispatcher
    +-- tron.d/                 Large command-family modules only
    +-- tron-lib.d/             Helpers shared by dispatcher and installed CLI
    +-- tron-lib.sh
    +-- tron-cli                Installed runtime CLI entrypoint
    +-- tron-ios-beta           Physical-device iOS beta helper
    +-- tron-version            Release version checker/syncer
    +-- tron-release-notes      GitHub release changelog generator
    +-- benchmarks/             Benchmark command implementation and baselines
    +-- documented standalone helpers
```

## Delete Candidates

No tracked files remain classified as `delete`. No files were deleted in PCC-1.
During PCC-3, the retired capability-search asset bundle was deleted after
source and lockfile audits proved no retained primitive used it. During PCC-9,
the old `packages/agent/examples/local-packs/` examples were deleted after the
stale-doc audit found they described retired worker-pack product surfaces rather
than current primitive runtime behavior. During PCC-10, package-local `.claude`
rule trees and the retired iOS git workflow DTO were deleted after adversarial
review proved they were stale branch/product residue.

## Collapse-Audit Hotspots

| Area | Inventory owner | Later row |
|------|-----------------|-----------|
| iOS source roots | old `Core`, `Database`, `Models`, `Services`, `ViewModels`, `Views`, `Theme`, `Utilities`, `Extensions`, `Protocols` roots now collapsed to the retained primitive shell | PCC-6 passed |
| Mac source roots | root Swift files, old `Services`, old `Observability`, old `Mocks`, and old `Theme` now collapsed to HRA-14 App, Server, MenuBar, Wizard, Support, and Infrastructure owners | PCC-7/HRA-14 passed |
| Scripts | manual dispatcher, command modules, installed runtime helpers, release helpers, hooks, benchmarks, and device helpers retained; automatic deploy watcher deleted | PCC-8 passed |
| Contributor rule docs and large tests | root/package `.claude` helper trees deleted; package docs and behavior-owned test suites audited | PCC-10 passed |

## Open Loops

- No files remain classified as `collapse` or `delete`.
- The target tree is canonical for future moves; Xcode project files must be
  regenerated from `project.yml` after iOS or Mac source moves.
- Historical teardown scorecards/evidence retain old product vocabulary as
  evidence; ordinary source/docs are guarded by
  `primitive_code_cleanup_invariants`.
