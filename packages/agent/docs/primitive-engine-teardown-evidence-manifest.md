# Primitive Engine Teardown Evidence Manifest

Created: 2026-06-06

Scorecard: [`primitive-engine-teardown-scorecard.md`](primitive-engine-teardown-scorecard.md)

Current score: **37/100**

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
| PET-1 | passed_after_fix | Added the source-audited PET-1 deletion inventory and README living-doc link. The inventory classifies all current Rust domain roots, engine primitive workers, runner context planes, first-party managed skills, agent docs, iOS source/view roots, and settings surfaces as retain/delete/successor before behavior deletion. Red/green proof: the covering invariant was added first and failed because the inventory file was absent, then passed after the inventory/scorecard/manifest updates. Checkpoint commit: `6b80e8590`. Open loops are recorded in the inventory and remain owned by PET-2 through PET-11. | `find packages/agent/src/domains -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `sed -n '1,180p' packages/agent/src/domains/registration.rs` -> exit 0; `rg -n "pub\\(crate\\) const .*_WORKER_ID\|pub\\(crate\\) mod" packages/agent/src/engine/primitives/mod.rs` -> exit 0; `sed -n '1,140p' packages/agent/src/domains/agent/runner/context/mod.rs` -> exit 0; `find packages/agent/skills -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `find packages/agent/docs -maxdepth 1 -type f \| sort` -> exit 0; `find packages/ios-app/Sources/Views -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `find packages/agent/src/domains/settings/implementation/types -type f -name '*.rs' -maxdepth 1 -print \| sort` -> exit 0; red gate `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 101, `primitive_engine_teardown_inventory_stays_exhaustive` failed on missing `primitive-engine-teardown-inventory.md`; green rerun `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 2 passed; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `git diff --check` -> exit 0. | Classification mistakes can preserve product code; PET-2 through PET-10 must execute against the map and PET-11 must adversarially revisit every retained/successor classification. |
| PET-2 | passed_after_fix | Removed product/tool domain registration from startup and narrowed `agent::*` registration to prompt-loop infrastructure. Deleted public agent product operations for goal runs, work snapshots, user-question pauses, subagent status/result/cancel, and public queue management. The startup catalog now keeps `capability::execute` plus boot/provider/session infrastructure and rejects retired product namespaces. README capability docs now describe the branch primitive surface instead of the retired worker-first catalog/router. | Red `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_teardown_startup_catalog_excludes_deleted_product_domains -- --nocapture` -> exit 101, old startup catalog still contained retired namespaces. Green rerun -> exit 0, 1 passed, 5731 filtered out, 455 dead-code warnings from unregistered product modules. Broad verification `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive -- --nocapture` -> exit 0, 43 passed, 5690 filtered out, 455 dead-code warnings. `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 2 passed; `git diff --check` -> exit 0. Additional cleanup: removed dead capability admin schema helpers, dead `agent.queue` stream publisher, and stale agent module docs. | Product modules are absent from registration but still declared/compiled; the 455 warnings are PET-10/PET-5 deletion evidence, not acceptable final state. Session/event/UI tests still contain old product names until their rows run. |
| PET-3 | passed_after_fix | Collapsed provider export and `capability::execute` behavior to the primitive loop. OpenAI tool conversion now exports only function `execute` with no hosted `tool_search`/`defer_loading`. `capability::execute` directly implements `observe`, `state_get`, `state_set`, `state_list`, `file_read`, `file_write`, and `process_run`, with no capability registry recipe, vector search, binding, plugin, conformance, or policy routing dependency. Added run-loop proof that a mock provider calls `execute`, receives the `observe` result in the next turn context, and continues to final assistant text. | Red `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_execute_observes_without_registry_routing -- --nocapture` -> exit 101, old execute rejected `observe`; green rerun -> exit 0, 1 passed. Red `cargo test --manifest-path packages/agent/Cargo.toml --lib convert_tools_v2_never_exports_hosted_tool_search_for_primitive_branch -- --nocapture` -> exit 101, converter emitted hosted tool search; green rerun -> exit 0, 1 passed. New integration proof `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_loop_calls_execute_observes_result_and_continues -- --nocapture` -> exit 0, 1 passed, provider called `execute` and continued after the result. Broad verification `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive -- --nocapture` -> exit 0, 43 passed, including `model_capability_invocation_invokes_execute_primitive_through_engine`. | Context assembly still carries policy/rules/skills/hooks/subagent/job abstractions. OpenAI hosted-tool-search DTO/model support remains compiled but behavior-disabled; PET-10 must delete it with the provider absence gates. PET-4/PET-6 must delete context planes before context is primitive. |
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
