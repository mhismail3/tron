# Primitive Engine Teardown Evidence Manifest

Created: 2026-06-06

Scorecard: [`primitive-engine-teardown-scorecard.md`](primitive-engine-teardown-scorecard.md)

Current score: **5/100**

Status: **active planning artifact**

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
| PET-1 | pending | Not run. | pending | pending |
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
