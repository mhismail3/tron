# Post-AHA Adversarial Closeout Scorecard

Current score: **100/100**

Status: **completed**

Branch: `codex/primitive-engine-teardown`

Baseline commit: `7b51e202d57af3340379acc2482a561cf2649860`

Plan: `/Users/<USER>/Downloads/PLAN (2).md`, redacted from the operator
Downloads path used to seed this campaign.

## Operating Rules

- Each row starts with a red guard or explicit failing proof, then lands the
  architecture/docs/test fix, targeted verification, evidence update, and a
  checkpoint commit.
- No runtime wire/API compatibility layer is added. Closeout work hardens
  architecture, source ownership, docs, guards, CI parity, and provenance.
- Legacy aliases, fallback branches, stale source-truth paths, and hollow
  drift checks are not acceptable closeout states.
- Generated Mac XcodeGen output stays ignored and untracked; iOS XcodeGen
  output stays tracked and drift-checked.
- Every phase records honest residuals before commit. Open loops stay visible
  here and in the evidence manifest until closed.

## Required Artifacts

| Artifact | Status | Purpose |
|----------|--------|---------|
| `packages/agent/docs/post-aha-adversarial-closeout-scorecard.md` | completed | Weighted PAC scorecard, open-loop ledger, and closeout state. |
| `packages/agent/docs/post-aha-adversarial-closeout-evidence-manifest.md` | completed | Red/green proof, verification commands, commit hashes, and residual risk. |
| `packages/agent/tests/post_aha_adversarial_closeout_invariants.rs` | completed | Integration target for post-AHA closeout static gates. |

## Scorecard

Total weight: **100**

| ID | Area | Weight | Status | Owner | Evidence | Open loops |
|----|------|--------|--------|-------|----------|------------|
| PAC-0 | Scorecard, evidence, README, and red-gate setup | 6 | passed_after_fix | docs/static gates | Added this scorecard, the evidence manifest, README living-doc links, and the intentionally red `post_aha_adversarial_closeout_invariants` target. | Later rows turn the red gates green. |
| PAC-1 | Mac generated-project CI policy | 10 | passed_after_fix | CI/project generation | Mac workflows now generate `TronMac.xcodeproj`, verify it is ignored, and build/test/archive from that generated project; iOS workflows keep tracked `TronMobile.xcodeproj` drift checks. The older AHA policy gate was revised to enforce this split policy instead of the superseded tracked-Mac rule. | Closed; focused Mac guard/source organization remains PAC-4/PAC-5. |
| PAC-2 | README/AGENTS source-truth path repair | 12 | passed_after_fix | docs/source truth | README and AGENTS now point to `settings/profile/types/`, `auth/credentials/`, `shared/protocol/events/`, and `shared/foundation/paths/`; the dead `domains/tools` maintenance path was removed. The PAC source-truth guard passes and stale paths remain only as regression needles. | Closed. |
| PAC-3 | Runtime/docs parity and database inventory | 10 | passed_after_fix | runtime/docs parity | README startup registration no longer lists the deleted public `context` domain, and the database table inventory includes the full engine catalog table set (`engine_catalog_changes`, `engine_catalog_workers`, `engine_catalog_functions`) alongside the booted runtime storage tables. PAC parity and migration schema tests pass. | Closed. |
| PAC-4 | Mac launch-agent/process ownership | 12 | passed_after_fix | Mac architecture | `LiveLaunchAgentManager` moved to `Server/LaunchAgent`, `Subprocess` moved to `Support/Foundation`, live launch-agent tests moved to `Tests/Server/LaunchAgent`, and `ServerPing.swift` now owns only ping/status capture behavior. PAC ownership and focused Mac launch-agent/ping tests pass. | Closed; PAC-5 owns broader Mac SourceGuard coverage. |
| PAC-5 | Mac guard parity | 10 | passed_after_fix | Mac guard parity | Added `MacSourceGuardTests` coverage for required roots, banned roots, helper-resource layout, staged-binary policy, `bundle-agent --clean`, and 590 LOC warning rows. `bundle-agent --clean` now removes only ignored staged binaries and preserves tracked helper plists, Info.plists, and icons. | Closed. |
| PAC-6 | iOS hierarchy and mirrored tests | 9 | passed_after_fix | iOS hierarchy | Retry tests moved under `Tests/Engine/Transport/Retry`, WebSocket tests moved under `Tests/Engine/Transport/WebSocket`, and Chat tests moved under `Coordinators`, `Messaging`, and `ViewModel`. SourceGuard now watches the production Retry source root plus the mirrored test roots, iOS docs name the owner mirror, tracked Xcode was regenerated, and HRA/PCC inventory rows were repaired for the moved/new tracked files. | Closed. |
| PAC-7 | Rust docs and LOC split budgets | 10 | passed_after_fix | Rust docs/budgets | Top-level Rust roots `app`, `domains`, `engine`, `shared`, and `transport` now carry `## Submodules`, `## Entry Points`, `## Invariants`, and `## Test Ownership` sections. The PAC split-plan watchlist now has the current 895 LOC row for `engine/catalog/registry/mod.rs` with a concrete split plan. | Closed. |
| PAC-8 | Local/GitHub CI parity | 8 | passed_after_fix | local/CI parity | `scripts/tron ci test` now runs the full explicit closeout target set: `db_path_guard`, PET/PCC/HRA/AHA/PAC invariants, `primitive_trace_execution`, and serial `integration`. GitHub's Rust static-gates job runs the same named target set in the same order, and README/CONTRIBUTING document that parity. | Closed. |
| PAC-9 | Provenance, privacy, and residue policy | 7 | passed_after_fix | provenance/privacy/residue | Added the redacted in-repo AHA plan digest, redirected the AHA scorecard and README to it, made the personal-info full-scan roots explicit for `packages/agent`, `packages/ios-app`, `packages/mac-app`, `AGENTS.md`, and `README.md`, and kept the allowed fallback/compatibility wording policy durable in this scorecard. | Closed. |
| PAC-10 | Final closeout verification | 6 | passed_after_fix | final closeout | Full Rust CI (`scripts/tron ci fmt check clippy test`), rustdoc, full personal-info guard, full PAC target, focused iOS hierarchy tests, focused and full Mac wrapper tests, generated-project drift checks, ignored-artifact audit, and residue scans completed. The broad wording scan hits were reviewed as live stale-state handling, provider model IDs, and negative guard/policy text rather than actionable legacy paths. | Closed. |

## Static Gates

The Rust integration target
`post_aha_adversarial_closeout_invariants` owns these checks:

- `post_aha_adversarial_closeout_scorecard_stays_formalized`
- `mac_generated_project_policy_is_truthful`
- `documented_source_truth_paths_exist_or_use_supported_globs`
- `startup_domains_and_database_inventory_match_runtime_truth`
- `mac_launch_agent_and_subprocess_have_physical_owners`
- `mac_source_guards_cover_wrapper_contracts`
- `ios_transport_and_chat_tests_mirror_production_owners`
- `rust_progressive_docs_and_loc_split_plans_are_current`
- `local_and_github_ci_run_the_same_static_closeout_targets`
- `aha_provenance_privacy_and_residue_policy_are_in_repo`

## Allowed fallback/compatibility wording contexts

Live implementation, workflows, source-local docs, and README architecture
claims should avoid fallback or compatibility wording because those terms hide
old paths and dual behavior. The allowed contexts are:

- historical evidence that names a prior failure or removed surface;
- provider protocol term usage where an upstream API field is literally named
  that way;
- external CLI behavior notes that describe third-party command variance,
  without adding a Tron runtime branch.

## Open Loops

- No PAC implementation rows remain open. The evidence manifest records final
  verification commands, reviewed ignored artifacts, and checkpoint hashes.

## Rust/Swift Split-Plan Watchlist

PAC-7 owns this section. Files at or above 890 LOC must have a current LOC row
with a concrete split plan before PAC-7 can close.

| Path | Current LOC | Owner | Concrete split plan | Status |
|------|-------------|-------|---------------------|--------|
| `packages/agent/src/engine/catalog/registry/mod.rs` | 895 | engine catalog registry owner | concrete split plan: keep the revisioned registry type and public mutation/query boundary in `registry/mod.rs`; move the next new catalog-change projection, idempotency registration helper, or function query helper into a focused sibling module before adding behavior here. | watch |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs` | 1479 | capability runtime grant owner | concrete split plan: keep cross-domain grant orchestration in `grant.rs`; move the next execute-resource grant family into a focused grant policy helper module before adding behavior here. | watch |
| `packages/agent/src/domains/agent/loop/capability_invocation_executor/tests/grant_tests.rs` | 1284 | capability runtime grant test owner | concrete split plan: keep shared grant test fixtures here; move the next resource-family or delegated-module regression batch into focused `tests/grant_*` sibling modules before adding coverage here. | watch |
| `packages/agent/src/domains/capability/contract.rs` | 1086 | capability contract owner | concrete split plan: keep the primitive capability catalog boundary here; move the next execute operation schema guidance block into a focused contract helper module before adding behavior here. | watch |
| `packages/agent/src/domains/capability/operations/module_program_execution_tests.rs` | 1210 | capability execute test owner | concrete split plan: keep shared module-program-execution fixtures here; split the next lifecycle or delegated module-pack regression batch into focused sibling test modules before adding coverage here. | watch |
| `packages/agent/src/domains/git/service.rs` | 1461 | git domain owner | concrete split plan: keep git service orchestration here; move the next status/diff, staged-index, command-boundary, or ref-helper behavior into focused git service modules before adding behavior here. | watch |
| `packages/agent/src/domains/git/tests.rs` | 3022 | git test owner | concrete split plan: keep shared git test fixtures here; move the next status/diff, mutation, commit, branch-start, resource/schema, provider-static, or replay batch into focused git test modules before adding coverage here. | watch |
| `packages/agent/src/domains/jobs/service.rs` | 1175 | jobs owner | concrete split plan: keep lifecycle orchestration in `service.rs`; split the next reconciliation, finalization, cleanup, or output-retention behavior into focused jobs service sibling modules before adding behavior here. | watch |
| `packages/agent/src/domains/jobs/tests.rs` | 996 | jobs test owner | concrete split plan: keep shared jobs regression setup in `tests.rs`; split the next lifecycle, output, timeout, reconciliation, or fail-closed regression batch into focused jobs test modules before adding coverage here. | watch |
| `packages/agent/src/domains/memory/tests.rs` | 1784 | memory test owner | concrete split plan: keep shared memory fixtures here; move the next retrieval, prompt-inclusion, retention, projection, query/decision, or lifecycle regression batch into focused memory test modules before adding coverage here. | watch |
| `packages/agent/src/domains/module_registry/tests.rs` | 1640 | module registry test owner | concrete split plan: keep shared module-registry manifest fixtures here; split the next seed-manifest projection or module-pack manifest batch into focused sibling test modules before adding coverage here. | watch |
| `packages/agent/src/domains/procedural/service.rs` | 1976 | procedural domain owner | concrete split plan: keep procedural service orchestration here; move the next definition, activation request, activation decision, projection, or validation helper behavior into focused procedural modules before adding behavior here. | watch |
| `packages/agent/src/domains/procedural/tests.rs` | 1399 | procedural domain test owner | concrete split plan: keep shared procedural fixtures here; split the next definition, activation request/decision, authorization denial, or projection-redaction batch into focused procedural test modules before adding coverage here. | watch |
| `packages/agent/src/domains/subagents/execution.rs` | 1172 | subagents owner | concrete split plan: keep subagent execution orchestration here; move the next launch-planning, follow-up inspection/cancel/result projection, or authority-selector helper into focused subagent modules before adding behavior here. | watch |
| `packages/agent/src/domains/worker_lifecycle/tests/mod.rs` | 973 | worker lifecycle test owner | concrete split plan: keep common worker lifecycle fixtures in `tests.rs`; split the next manifest/package, inspection, or launch/reconciliation regression batch into focused worker lifecycle test modules before adding coverage here. | watch |
| `packages/agent/src/engine/authority/grants/authorization.rs` | 3182 | engine authority owner | concrete split plan: keep shared authorization orchestration here; move the next operation/resource selector extractor or per-domain explicit-grant scanner into focused authority grant modules before adding behavior here. | watch |
| `packages/agent/tests/baseline_pre_restoration_closure_invariants.rs` | 1153 | BPRC invariant owner | concrete split plan: keep shared BPRC scorecard parsing here; split the next Phase 2 lineage, inventory parser, or closeout assertion group into focused invariant modules before adding assertions here. | watch |
| `packages/agent/tests/ios_affordance_restoration_map_invariants.rs` | 1104 | IARM invariant owner | concrete split plan: keep shared invariant helpers in the root target; split the next physical-device, queue/phase, APNs defer, or planning-text guard into focused invariant modules before adding assertions here. | watch |
