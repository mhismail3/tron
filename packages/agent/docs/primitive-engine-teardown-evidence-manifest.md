# Primitive Engine Teardown Evidence Manifest

Created: 2026-06-06

Scorecard: [`primitive-engine-teardown-scorecard.md`](primitive-engine-teardown-scorecard.md)

Current score: **13/100**

Status: **active execution artifact**

This manifest records command, simulator, database, source-audit, and commit
evidence for the primitive engine teardown campaign. Rows are intentionally
empty until each scorecard row runs. Do not award points in the scorecard
without adding concrete evidence here.

## Baseline Branch Point

- Source branch before teardown: `next/modular-capability-engine`.
- Existing worker-first checkpoint: completed at 100/100 before this branch.
- New teardown branch: `codex/primitive-engine-teardown`.
- Compatibility assumption: none. This branch may delete old capability names,
  old DTOs, old product tables, old UI modes, and old docs without migration
  support.
- PET-0 checkpoint status: plan, manifest, README link, and static gate were
  added on the teardown branch.

## Row Evidence

| Row | Status | Evidence summary | Commands / artifacts | Residual risk |
|-----|--------|------------------|----------------------|---------------|
| PET-0 | passed_after_fix | Formalized the clean-break primitive-engine teardown plan, companion evidence manifest, README living-doc link, and static invariant test. Existing iOS action/docs checkpoint was committed before branching so the branch point was clean. | `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-codex-actions-check -only-testing:TronMobileTests/SourceGuardTests` -> exit 0, 17 Swift Testing tests passed, result bundle `/tmp/tron-xcode-codex-actions-check/Logs/Test/Test-Tron-2026.06.06_18-46-49--0700.xcresult`; `git switch -c codex/primitive-engine-teardown` -> exit 0; red/green plan gate fixed Markdown wrapping and Rust formatting; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 1 passed; `git diff --check` -> exit 0. | None for planning. PET-1 owns source inventory before deletion. |
| PET-1 | passed_after_fix | Added the source-audited PET-1 deletion inventory and README living-doc link. The inventory classifies all current Rust domain roots, engine primitive workers, runner context planes, first-party managed skills, agent docs, iOS source/view roots, and settings surfaces as retain/delete/successor before behavior deletion. Red/green proof: the covering invariant was added first and failed because the inventory file was absent, then passed after the inventory/scorecard/manifest updates. Open loops are recorded in the inventory and remain owned by PET-2 through PET-11. | `find packages/agent/src/domains -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `sed -n '1,180p' packages/agent/src/domains/registration.rs` -> exit 0; `rg -n "pub\\(crate\\) const .*_WORKER_ID\|pub\\(crate\\) mod" packages/agent/src/engine/primitives/mod.rs` -> exit 0; `sed -n '1,140p' packages/agent/src/domains/agent/runner/context/mod.rs` -> exit 0; `find packages/agent/skills -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `find packages/agent/docs -maxdepth 1 -type f \| sort` -> exit 0; `find packages/ios-app/Sources/Views -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `find packages/agent/src/domains/settings/implementation/types -type f -name '*.rs' -maxdepth 1 -print \| sort` -> exit 0; red gate `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 101, `primitive_engine_teardown_inventory_stays_exhaustive` failed on missing `primitive-engine-teardown-inventory.md`; green rerun `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 2 passed; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `git diff --check` -> exit 0. | Classification mistakes can preserve product code; PET-2 through PET-10 must execute against the map and PET-11 must adversarially revisit every retained/successor classification. |
| PET-2 | pending | Not run. | pending | pending |
| PET-3 | pending | Not run. | pending | pending |
| PET-4 | pending | Not run. | pending | pending |
| PET-5 | pending | Not run. | pending | pending |
| PET-6 | pending | Not run. | pending | pending |
| PET-7 | pending | Not run. | pending | pending |
| PET-8 | pending | Not run. | pending | pending |
| PET-9 | pending | Not run. | pending | pending |
| PET-10 | pending | Not run. | pending | pending |
| PET-11 | pending | Not run. | pending | pending |

## Required Final Evidence

PET-11 must add:

- final branch and commit hash;
- full retained/deleted primitive inventory;
- provider model-facing tool export proof;
- fresh bare-session transcript or fixture output;
- database schema/table/resource/event proof for fresh state;
- iOS simulator target name, UDID, bundle id, launch return code, and iPhone/iPad
  screenshots;
- final command list with exit codes;
- final `git status --short --branch`;
- explicit list of anything deferred to the self-adapting-agent successor.
