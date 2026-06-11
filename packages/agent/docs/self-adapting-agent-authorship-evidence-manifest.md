# Self-Adapting Agent Authorship Evidence Manifest

Branch: `codex/primitive-engine-teardown`
Baseline commit: `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7`
Status: **complete**

## Baseline Evidence

- Checkout verified clean on `codex/primitive-engine-teardown` at
  `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7`.
- ODA artifacts are present and complete, including
  `packages/agent/docs/observability-diagnostics-auditability-scorecard.md`.
- Pre-SAA source audit showed `execute` was the only provider-visible primitive,
  but typed resources were not directly authorable through `execute`; the slice
  adds resource operations inside the existing primitive rather than adding a
  new provider tool.

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk | Commit |
|---|---|---|---|---|---|
| SAA-0 | passed_after_fix | Added scorecard/evidence/inventory artifacts, `self_adapting_agent_authorship_invariants`, README links, and CI/local closeout target wiring. | Static harness parses scorecard rows, evidence rows, TSV structure, README links, and CI target lists. | Closed. | this slice |
| SAA-1 | passed_after_fix | Added Markdown and TSV inventory rows for provider context, `execute`, state, resources, files, UI, replay/trace, worker protocol, iOS/Mac runtime, scripts, docs, and static gates. | Inventory gate requires structured rows, tracked paths, required coverage, and no unclassified fields. | Inventory is source-grounded, not exhaustive proof of future generated artifacts. | this slice |
| SAA-2 | passed_after_fix | `capability::execute` remains the only provider-visible contract; resource authorship uses `resource_*` operations inside `execute`; provider clarification still rejects catalog targets. | Static guards check `contract.rs`, `primitive_surface.rs`, OpenAI clarification text, and `operations/resource.rs`. | Future provider adapters must keep the same one-tool projection. | this slice |
| SAA-3 | passed_after_fix | Added `agent_memory` and `agent_rule` built-in resource definitions and resource worker namespace claims. | Engine durability test checks core built-in kinds plus memory/rule required fields, lifecycle states, and relations. | Future semantic scoring of rule usefulness is outside this slice. | this slice |
| SAA-4 | passed_after_fix | Fixture creates goal, claim, evidence, decision, memory, and rule resources through `execute`, links them, inspects the rule, and checks trace operation evidence. | `saa_execute_can_author_goal_evidence_decision_memory_and_rule_resources` exercises the full loop. | Fixture uses in-memory isolated runtime, not a long-lived production session. | this slice |
| SAA-5 | passed_after_fix | Fixture creates `patch_proposal` and `materialized_file` resources with target path, hash, trace ref, and no immediate workspace file write. | `saa_execute_can_author_patch_materialized_file_and_ui_surface_without_live_promotion` checks the target file remains absent after resource creation. | Applying patches remains an explicit later operation. | this slice |
| SAA-6 | passed_after_fix | Fixture creates a validated `ui_surface`; static gates verify engine `ui_surface` validation and iOS generic runtime renderer/tests. | SAA target plus existing iOS `GeneratedUIRendererTests` close the generic runtime surface proof. | Rich generated UI semantics remain bounded by the existing schema. | this slice |
| SAA-7 | passed_after_fix | Runtime child grants include resource read/write and SAA resource kinds, but exclude `engine::promote`, worker registration, trigger creation, and worker write authority. | Static guard checks `capability_invocation_executor/grant.rs`, `engine::promote` transport contract, and external worker token validation. | Future promotion policy must add explicit decision/evidence validation at the promotion endpoint. | this slice |
| SAA-8 | passed_after_fix | Static scan rejects boot-time autonomous mutation loops, production deploy strings, repo-managed skills, and restored worker-pack/product paths in retained source. | `saa_source_has_no_boot_time_autonomous_mutation_loop_or_deploy_path` and promotion boundary guards. | Long-running improvement loops still need explicit user/session initiation in future slices. | this slice |
| SAA-9 | passed_after_fix | Execute resource operations are trace-recorded with stable operation names and inspectable resource refs; replay/trace/log surfaces remain inventoried. | Fixture checks `resource_create`, `resource_link`, and `resource_inspect` trace operations. | Live-scale redaction policy for arbitrary generated payloads remains a future hardening area. | this slice |
| SAA-10 | passed_after_fix | Scorecard total is 100/100, every closed row has evidence, stale closeout wording is rejected, and verification commands are recorded below. | SAA target, focused Rust targets, iOS/Mac guard targets, personal-info guard, diff checks, and final clean status. | Closed for this slice; do not start later SAA slices in this commit. | this slice |

## Verification Log

| Command | Result | Notes |
|---|---|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture` | passed | SAA static and fixture target. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | Existing execute trace/replay contract. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::agent --lib -- --nocapture` | passed | Agent loop and runtime grant coverage. |
| `cargo test --manifest-path packages/agent/Cargo.toml engine::durability::resources --lib -- --nocapture` | passed | Resource definitions and wrappers. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | Serial integration target. |
| `scripts/tron ci fmt check clippy test` | passed | Full local Rust closeout gate. |
| `scripts/personal-info-guard.sh` | passed | Personal-info literal guard. |
| `cd packages/ios-app && xcodegen generate` | passed | iOS project regeneration. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/GeneratedUIRendererTests` | passed | Closest generated-runtime/source guard target names were used because the retained suite is `GeneratedUIRendererTests`. |
| `cd packages/mac-app && xcodegen generate` | passed | Mac project regeneration. |
| `xcodebuild test -scheme TronMac -destination 'platform=macOS' -only-testing:TronMacTests/MacSourceGuardTests` | passed | Mac source guard closeout. |
| `git diff --check` | passed | Whitespace check. |
| `git ls-files -ci --exclude-standard` | passed | No ignored tracked files. |
| `git status --short` | passed | Worktree clean after commit. |

## Closeout

The final commit records code, tests, docs, inventories, scorecards, and
evidence together. Generated workers remain artifacts; they are not registered,
launched, scheduled, promoted, or deployed by this slice.
