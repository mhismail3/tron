# Primitive Code Cleanup Inventory

Created: 2026-06-08

Status: `passed_after_fix`

Scorecard row: `PCC-1`

Last updated: 2026-06-08 during `PCC-5` session persistence cleanup.

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
| `retain` | 686 | Current package/config/test/doc boundaries |
| `collapse` | 531 | Cleanup rows PCC-6 through PCC-9 |
| `asset` | 74 | iOS/Mac resources and benchmark baselines |
| `delete` | 11 | PCC-9 delete candidates |
| `generated` | 7 | XcodeGen, Cargo, and package-manager outputs |
| **Total** | **1309** | Whole repo |

## Current Tracked Package Counts

| Area | Files |
|------|-------|
| `.claude` | 6 |
| `.codex` | 2 |
| `.github` | 8 |
| root files | 5 |
| `packages/agent` | 505 |
| `packages/ios-app` | 644 |
| `packages/mac-app` | 115 |
| `scripts` | 24 |

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
+-- .claude/                   Contributor helper docs after stale-rule audit
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
|   |   |   +-- Support/        Diagnostics, pairing, storage, utilities
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
|       |   +-- App/            Entry, environment setup, command mode
|       |   +-- Server/         SMAppService, LaunchAgent, health, paths
|       |   +-- Wizard/         Install/pairing wizard state and views
|       |   +-- MenuBar/        Menu model, controller, actions
|       |   +-- Support/        Pairing, feedback, diagnostics, theme
|       |   +-- Resources/
|       |   +-- Assets.xcassets/
|       |   +-- Info.plist
|       +-- Tests/
|       +-- project.yml         XcodeGen source of truth
+-- scripts/
    +-- tron                    Dispatcher
    +-- tron.d/                 Large command-family modules only
    +-- tron-lib.d/             Helpers shared by dispatcher and installed CLI
    +-- tron-lib.sh
    +-- documented standalone helpers
```

## Delete Candidates

The inventory classifies these tracked files as `delete` for later proof rows:

| Path family | Files | Owning row | Reason |
|-------------|-------|------------|--------|
| `packages/agent/examples/local-packs/` | 11 | PCC-9 | Old local-pack examples are not primitive runtime source unless host infrastructure docs/tests prove otherwise. |

No files were deleted in PCC-1. During PCC-3, the retired capability-search
asset bundle was deleted after source and lockfile audits proved no retained
primitive used it. PCC-9 must either delete the remaining local-pack family or
revise its classification with direct evidence.

## Collapse-Audit Hotspots

| Area | Inventory owner | Later row |
|------|-----------------|-----------|
| iOS source roots | `Core`, `Database`, `Models`, `Services`, `ViewModels`, `Views`, `Theme`, `Utilities`, `Extensions`, `Protocols` | PCC-6 |
| Mac source roots | root Swift files, `Services`, `Theme` | PCC-7 |
| Scripts | dispatcher/module/helper split | PCC-8 |
| Contributor rule docs and large tests | `.claude`, package rule docs, over-budget suites | PCC-9 |

## Open Loops

- 531 files are still `collapse` until their owning cleanup rows run.
- 11 files are `delete` candidates and intentionally remain in place until
  their owning rows prove deletion.
- The target tree is canonical for future moves, but Xcode project files must
  be regenerated from `project.yml` after iOS or Mac source moves.
- Historical teardown scorecards/evidence retain old product vocabulary as
  evidence; ordinary source/docs are guarded by
  `primitive_code_cleanup_invariants`.
