# Phase 2 Agent Execution Restoration Evidence Manifest

Status: **complete**
Current score: **100/100**

Scorecard:
[`phase-2-agent-execution-restoration-scorecard.md`](phase-2-agent-execution-restoration-scorecard.md)

Inventory:
[`phase-2-agent-execution-restoration-inventory.md`](phase-2-agent-execution-restoration-inventory.md)
and
[`phase-2-agent-execution-restoration-inventory.tsv`](phase-2-agent-execution-restoration-inventory.tsv)

## Source Audit

Planning branch:
`codex/ios-affordance-restoration-map-current`

Planning baseline HEAD:
`980867c3534612cd8d30867473a5b3eb36ad1f03`

The plan was derived from repository artifacts instead of chat history. The
audit covered:

- Phase 1 iOS affordance map, inventory, TSV, evidence, and progress ledger;
- BPRC restoration backlog and primitive feature index;
- current README architecture, capabilities, event, settings, database, iOS,
  testing, and invariant sections;
- current Rust crate and domain `mod.rs` docs for the retained primitive
  baseline, workspace browser, transcription, and worker lifecycle boundaries;
- iOS architecture docs for Phase 1 closeout and Phase 2 deferral language;
- SACB authority, public context, grant, secret, pairing, and worker-boundary
  scorecard/evidence;
- CSD task, queue, stream, timer, cancellation, and owner evidence;
- TPC primitive-minimality and file-budget scorecard/evidence;
- HRA ownership and progressive-disclosure scorecard/evidence;
- SSARR readiness and SUWRF worker lifecycle inventories.

## Row Evidence

| Row | Status | Evidence | Validation anchor |
| --- | --- | --- | --- |
| P2AER-0 | passed | The scorecard records current branch, baseline HEAD, inspected artifacts, planning-only scope, and no feature implementation. | Scorecard Source Baseline and Scope sections. |
| P2AER-1 | passed | The roadmap carries forward Phase 1 Slice 6 notification/APNs deferral, server-backed workspace-browser limitations, passive cockpit placement deferral, and the Phase 2 reminder categories from the progress ledger. | Scorecard Exhaustive Feature Coverage and Slice 13. |
| P2AER-2 | passed | The TSV contains rows for all 24 BPRC feature buckets and the scorecard roadmap maps those buckets to implementation slices. | TSV `bprc_refs` column and inventory summary. |
| P2AER-3 | passed | Each row in the TSV uses the controlled classification set for primitive, modular package, iOS-only, server-fact rendering, deferred, or reject candidate surfaces. | Inventory Controlled Vocabulary. |
| P2AER-4 | passed | The memory section defines engine-owned memory primitives, replaceable memory engines, memory store families, privacy, provenance, confidence, expiry, edit/delete/export/migration, evals, engine comparison, iOS audit, and hidden-memory static gates. | Scorecard Deep Memory Architecture. |
| P2AER-5 | passed | Fourteen implementation slices plus Slice 0 planning closeout include objective, user outcome, primitives, modular boundaries, likely files, old evidence paths, acceptance criteria, focused tests, iOS validation, docs/static updates, and user decisions. | Scorecard Ordered Slice Roadmap. |
| P2AER-6 | passed | SACB authority, CSD scheduling, TPC minimality, HRA ownership, and DESI evidence rules are encoded as roadmap and validation constraints. | Scorecard Invariants and Validation Protocol. |
| P2AER-7 | passed | iOS parity defaults to generic runtime rendering and permits native surfaces only after stable server contracts and validation. | Scorecard Primitive And Capability Architecture and each slice's iOS validation notes. |
| P2AER-8 | passed | Companion narrative inventory and TSV exist with stable columns for old evidence, current replacement/gap, classification, owners, iOS surface, memory involvement, backend dependency, slice, user decision, validation, and status. | Inventory artifacts. |
| P2AER-9 | passed | The handoff packet requires first-principles UX review, architecture review, source evidence, user questions, and validation plan before coding. | Scorecard Handoff Packet section. |

## Slice 1 Implementation Evidence

Branch: `codex/phase-2-catalog-discovery-evidence-current`

Baseline HEAD: `7db72c1ee46ff4c974ad408f36e9c169da34dfd1`

Scope implemented:

- Added the `catalog_discovery` domain worker with
  `catalog_discovery::search`, `catalog_discovery::inspect`, and
  `catalog_discovery::conformance_report`.
- Added `catalog_search`, `catalog_inspect`, and `catalog_conformance` as
  inspect/evidence-only `capability::execute` operations while keeping the
  provider-visible tool list singular.
- Added resource-backed `catalog_discovery_report` evidence with explicit
  idempotency, a report lease, event-sourced compensation metadata, an output
  contract, and `catalog.discovery` stream publication.
- Kept protected/internal/admin functions protected: search reports omission
  counts by visibility and report checks aggregate protected failure counts
  without storing hidden ids.
- Added Runtime Cockpit Discovery rendering backed by live catalog DTOs and
  `catalog_discovery_report` resources; chat remains quiet unless a separate
  attention-worthy state exists.
- Did not add target routing, intent execution, broad public `/engine`
  expansion, generated `ui_surface` publication, fixed legacy panels, schema
  repair, or copied old modules.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_discovery -- --nocapture` | exit 0 | 20 Rust catalog tests passed, covering catalog registry behavior plus search/inspect/report no-target-invocation and protected-name omission. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution execute_catalog_search_does_not_require_working_directory_metadata -- --nocapture` | exit 0 | 1 integration test passed, proving catalog discovery through `execute` works without trusted working-directory metadata. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | 35 tests passed; HRA inventories cover the new catalog-discovery Rust files, Swift Runtime Cockpit files, and Xcode project membership. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | 17 tests passed; SACB guards cover provider-visible `execute`, protected-function visibility, idempotency, and working-directory scope for catalog ops. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | 16 tests passed; PCC file inventory classifies the new domain, tests, DTOs, and cockpit files as retained implementation/test surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | exit 0 | 15 tests passed; TPC retention inventory and file-budget scans include the split catalog discovery service/projection/report modules. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` | exit 0 | 12 tests passed; TMB confirmed catalog discovery crosses engine/resource boundaries through the engine facade rather than private stores. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | exit 0 | 11 tests passed; Phase 2 docs do not reclaim removed autonomous-authorship/generated-worker completion claims. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | exit 0 | 8 tests passed; BPRC feature coverage remains mapped while Slice 1 restores catalog/discovery evidence. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | exit 0 | 8 tests passed; IARM Runtime Cockpit and generated-surface anchors remain classified as server-fact rendering, not fixed legacy panels. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture` | exit 0 | 11 tests passed; Runtime Cockpit discovery uses live worker/function/resource facts and preserves generic runtime-surface boundaries. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture` | exit 0 | 12 tests passed; the iOS architecture remains a thin client over typed server/runtime facts. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | 12 tests passed; Slice 1 adds no unmanaged schedulers/timers while using async resource/catalog reads. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants capability_registry_recipe_and_conformance_scaffolding_is_deleted -- --nocapture` | exit 0 | 1 targeted teardown test passed; old capability registry/recipe/conformance scaffolding remains deleted while the new `catalog_conformance` report op is allowed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants replay_critical_entropy_is_allow_listed -- --nocapture` | exit 0 | 1 targeted determinism test passed; catalog discovery reports no longer add payload-local wall-clock timestamps outside durable resource/stream envelopes. |
| `cd packages/ios-app && xcodegen generate` | exit 0 | Xcode project regenerated after Swift DTO/view-model/UI changes. |
| `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/WorkerLifecycleDTOTests -only-testing:TronMobileTests/WorkerLifecycleClientTests -only-testing:TronMobileTests/AgentCockpitStateTests -only-testing:TronMobileTests/AgentCockpitViewModelTests` | exit 0 | 20 iOS simulator tests passed across DTO decoding, worker lifecycle client, cockpit projection, and cockpit view model report creation. |

## Slice 2 Implementation Evidence

Branch: `codex/phase-2-approval-safety-freshness-current`

Baseline HEAD: `f95d3b02efbffe15798d4164ae494e743a6332a5`

Scope implemented:

- Added the `approval` domain worker with `approval::request`,
  `approval::decide`, and `approval::check`.
- Added durable `approval_request` and `approval_decision` resource type
  definitions with requester, action, scope, risk class, expiry/freshness,
  evidence refs, resource selectors, trace/replay refs, decision actor/state,
  denial behavior, idempotency, and revision metadata.
- Added `approval.lifecycle` stream publication for requested, decided,
  denied, and revoked lifecycle transitions. Stream payloads record that
  approval is not authority and point execution permission back to existing
  engine authority grants.
- Added idempotent decision recording bound to the expected request resource
  version and a reusable fail-closed check path for approved, denied, expired,
  pending, missing, malformed, stale, and scope-mismatch outcomes.
- Added structured replay/evidence explanations for every check outcome,
  including request/decision resource ids, versions, evidence refs, resource
  selectors, trace refs, replay refs, denial behavior, and revision metadata.
- Added a hardening guard that aligns approval resource kind/schema ids,
  resource-backed output contracts, and persisted payload required fields with
  the engine resource-kernel definitions.
- Did not add native iOS approval UI, filesystem/jobs/git/web/memory/subagent/
  scheduling behavior, notifications, deployment behavior, or a default risky
  approval policy.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::approval -- --nocapture` | exit 0 | 6 Rust approval tests passed, covering request resource/stream creation, approved explanation, fail-closed denial/expiry/pending/missing/malformed/stale/scope mismatch, idempotent decision replay, stale revision conflict, freshness timeout, and approval resource schema alignment. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib stream_state -- --nocapture` | exit 0 | Focused agent-loop stream-state tests passed after extracting stream-message helpers to keep the TPC file budget green without behavior changes. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib turn_runner -- --nocapture` | exit 0 | 17 focused turn-runner tests passed after extracting turn parameters and failure emission helpers to keep the TPC file budget green without behavior changes. |

## Validation Log

| Command | Result | Evidence |
| --- | --- | --- |
| Source audit over required artifacts using `sed`, `rg`, `wc`, and `git rev-parse` | exit 0 | Required artifacts were readable; planning baseline HEAD and branch were captured; Phase 2 deferrals and BPRC feature ids were extracted into the plan. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Rust guard edits were formatted. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | 9 tests passed; the new scorecard arithmetic and companion evidence checks passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | exit 0 | 8 tests passed; Phase 1 deferral anchors remain intact. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | exit 0 | 8 tests passed; all BPRC feature buckets remain mapped. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture` | exit 0 | 8 tests passed; successor-term planning language is classified. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | exit 0 | 11 tests passed; Phase 2 planning docs remain future/readiness wording, not a completed autonomous-authorship architecture. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::approval -- --nocapture` | exit 0 | 6 Slice 2 approval tests passed, covering durable resources, lifecycle streams, fail-closed outcomes, idempotency/revision conflicts, replay/evidence explanations, and resource schema alignment. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib stream_state -- --nocapture` | exit 0 | Focused stream-state tests passed after the non-behavioral helper split. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib turn_runner -- --nocapture` | exit 0 | 17 focused turn-runner tests passed after the non-behavioral helper split. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | 17 tests passed; SACB inventory covers 758 rows including the approval worker, contracts, resources, lifecycle stream, not-authority boundary, and schema drift guard. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | 16 tests passed; PCC file inventory covers 1737 retained files including approval and helper-split files. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | exit 0 | 15 tests passed; TPC retention inventory covers 1692 retained rows and the touched Rust files remain within the 750-line hard budget. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` | exit 0 | 12 tests passed; TMB inventory covers 1069 rows and classifies approval as a package-owned module using engine/resource facades. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | 35 tests passed; HRA file and ownership inventories cover 1737 files including approval and helper-split ownership. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | exit 0 | 17 tests passed after documenting `domains/approval` as an approved UTC audit/freshness owner while retaining `check_approval_at` as the deterministic replay seam. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | 12 tests passed after adding the split `turn_runner/params.rs` cancellation-token owner to the CSD inventory. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture` | exit 0 | 10 tests passed; iOS architecture docs still preserve thin-client shell boundaries. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture` | exit 0 | 11 tests passed; Agent cockpit docs remain generic runtime-surface oriented. |
| `scripts/tron ci fmt check clippy test` | exit 0 | Full Rust CI passed after Slice 2 approval work, schema alignment hardening, DRC allow-list documentation, and CSD inventory refresh. |
| `scripts/personal-info-guard.sh` | exit 0 | Full scan reported no personal-info leaks in source. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git diff --cached --check` | exit 0 | No whitespace errors were reported in the staged diff. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files reported. |
