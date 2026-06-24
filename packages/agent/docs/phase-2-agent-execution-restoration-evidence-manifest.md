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

## Slice 3 Implementation Evidence

Branch: `codex/phase-2-memory-foundation-current`

Baseline HEAD: `301f61bc3af24e69decbe0281d829b9a9f7ada8e`

Scope implemented:

- Added the `memory` domain worker with policy/status, retain, edit,
  tombstone, list, inspect, prompt-trace recording, and migration import/export
  contracts.
- Added built-in resource definitions for `memory_engine`, `memory_policy`,
  `memory_record`, `memory_prompt_trace`, `memory_eval_run`, and
  `memory_migration_envelope`.
- Added source-backed protocol DTOs for memory modes, engines, policy,
  records, prompt decisions/traces, eval runs, and migration envelopes.
- Added read-only model `execute` operations for `memory_status`,
  `memory_list`, and `memory_inspect`; mutating memory functions remain
  backend domain contracts, not provider-visible tools.
- Wired prompt assembly to include only explicit memory status/count/ref facts
  through a private audit block and to record prompt traces without logging
  private body content.
- Hardened policy resolution so session-scoped memory context inherits
  workspace policy before system default, and session policy overrides
  workspace policy.
- Hardened prompt-trace idempotency so each trace records fresh memory status
  instead of replaying the first session audit after policy or record changes.
- Hardened direct record-id operations so inspect, edit, and tombstone fail
  closed when the addressed memory record belongs to a different
  session/workspace/system resource scope.
- Added a deterministic resource-backed engine shell that supports disabled,
  active, shadow, and compare modes, redacted body refs, lifecycle metadata,
  provenance, sensitivity/privacy class, confidence, expiry/retention, source
  refs, trace/replay refs, tombstone state, and migration metadata.
- Did not add semantic/vector retrieval, embeddings, ranking, summarization,
  procedural rules/hooks/skills, automatic retention, native iOS memory UI,
  filesystem/jobs/git/web/subagents/scheduling behavior, or deployment
  behavior.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::memory -- --nocapture` | exit 0 | 11 memory tests passed, covering disabled writes, source-backed schema/output drift, workspace policy inheritance/session override, lifecycle/versioning, cross-session record-id denial for inspect/edit/tombstone, inline body-ref rejection, prompt trace privacy, fresh trace-specific context after policy changes, absent-context explicitness, and redacted migration export/import. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | 17 SACB tests passed; the memory domain and capability operations are classified without widening provider-visible authority. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | 35 HRA tests passed; memory files and resource-definition split ownership are covered. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` | exit 0 | 12 TMB tests passed; memory crosses engine/resource boundaries through domain contracts and engine facades. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | exit 0 | 15 TPC tests passed; new memory source files are classified and remain under the 750-line hard budget after service/prompt/migration/resource-definition splits. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | 16 PCC tests passed; retained memory implementation, test, protocol, and resource files are inventoried. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | exit 0 | 17 DRC tests passed after classifying memory UTC timestamps as resource/prompt-trace audit metadata, not replay ordering keys. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture` | exit 0 | 8 SSARR tests passed; successor/runtime wording remains classified and does not claim old autonomous-authorship behavior. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | 12 CSD tests passed; Slice 3 adds no unmanaged timers, sleeps, or task ownership. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | exit 0 | 8 BPRC tests passed after narrowing the old-memory-surface guard to allow only the P2AER-tracked Slice 3 foundation while still rejecting semantic/vector/procedural memory engines. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | exit 0 | 8 IARM tests passed; Slice 3 keeps iOS to generic resource/runtime facts and does not add native memory panels. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | exit 0 | 11 OPSAA tests passed; memory foundation does not restore removed learned-rule/skill runtime surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_updating_worker_runtime_foundation_invariants -- --nocapture` | exit 0 | 9 SUWRF tests passed after narrowing the removed-feature guard to allow only the P2AER-tracked Slice 3 foundation outside worker-lifecycle scope. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | 9 DESI tests passed after adding Slice 3 evidence rows. |
| `scripts/tron ci fmt check clippy test` | exit 0 | Full Rust CI passed after the memory foundation implementation, historical guard narrowing, and inventory/evidence updates. |
| `scripts/personal-info-guard.sh` | exit 0 | Full scan reported no personal-info leaks in source. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files reported. |

## Slice 4 Implementation Evidence

Branch: `codex/phase-2-filesystem-agent-tools-current`

Baseline HEAD: `4c35b2119`

This section records implementation evidence for the Order 19 filesystem
slice. The branch refs below remain provenance, and their accepted source/fix
artifacts are represented on the current consolidated mainline.

Scope implemented:

- Added a filesystem-domain agent toolbox separate from the iOS
  workspace-browser subset.
- Added provider-visible `capability::execute` operation values for
  `filesystem_read`, `filesystem_list`, `filesystem_find`,
  `filesystem_glob`, `filesystem_search_text`, `filesystem_diff`,
  `filesystem_write`, `filesystem_edit`, and `filesystem_apply_patch` while
  keeping `execute` as the only model-facing primitive.
- Reused existing engine primitives for trusted working-directory authority,
  grants, idempotency, resource leases, output contracts, resources, streams,
  trace/replay evidence, and generic result rendering.
- Added path authority checks that reject absolute paths, parent traversal, and
  symlink escapes outside the trusted root; search walks do not follow
  symlinks.
- Added bounded read/list/search/diff output, binary body omission, bounded
  rollback previews, exact single-match text patches, expected-hash protection
  for existing-file commits, and mutating preview default behavior.
- Post-closeout orchestrator review hardened truncated-snapshot handling:
  committed writes to existing files reject unavailable current hashes, and
  exact-text patches refuse files larger than the bounded preview limit rather
  than editing partial content.
- Kept provider-visible filesystem results relative to the authorized root; the
  resource/audit layer may retain canonical locations for committed materialized
  files.
- Added resource-backed patch proposal evidence for previews and commits, plus
  materialized-file resource versions and `filesystem.lifecycle` stream events
  for commits.
- Did not add unrelated jobs/git/web/subagent/memory/vector/procedural/
  scheduling capabilities, native iOS file/patch UI, public DTO expansion,
  database tables, settings, auth/provider changes, or production deployment
  behavior.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::filesystem -- --nocapture` | exit 0 | 17 filesystem tests passed after Order 19 audit hardening, covering workspace-browser regressions, parent traversal denial, symlink escape denial, bounded binary read preview, bounded text search with binary skip, preview/commit patch and materialized resources, hash/exact-match patch guards, direct package and `capability::execute` refusal for existing-file commits with unavailable hashes and exact patches on truncated previews, provider-boundary idempotency, and legacy `file_write` rejection. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | 17 SACB tests passed after classifying filesystem package files, provider-visible execute ops, working-directory requirements, and mutating idempotency requirements without weakening the authority guards. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` | exit 0 | 12 TMB tests passed; filesystem agent support crosses engine/resource boundaries through the engine host facade rather than private stores. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | 35 HRA tests passed; new filesystem support files and ownership mappings are inventoried. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | exit 0 | 15 TPC tests passed after adding filesystem retention rows and refreshing summary counts while keeping touched Rust files under the hard line budget. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | 16 PCC tests passed; filesystem package implementation and tests are retained surfaces rather than deleted legacy scaffolding. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | exit 0 | 8 BPRC tests passed after narrowing the deleted-filesystem guard to allow only the P2AER Slice 4 package while still rejecting retired `read_file`, `write_file`, and `edit_file` spellings. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | exit 0 | 8 IARM tests passed; Slice 4 remains generic-result/resource rendering first and does not add native file/patch UI. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | 9 DESI tests passed after adding Slice 4 inventory and evidence rows. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | exit 0 | 11 OPSAA tests passed after classifying the filesystem package without restoring autonomous-authorship or generated-worker surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture` | exit 0 | 26 provider prompt/converter tests passed after documenting filesystem execute operation names, relative-path guidance, and preview/hash/idempotency instructions. Mutating refusal behavior is covered by filesystem/capability execution tests rather than by the provider converter. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture` | exit 0 | 3 capability-domain tests passed with the filesystem execute operation dispatch path registered. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::registration::tests::primitive_teardown_startup_catalog_excludes_deleted_product_domains -- --nocapture` | exit 0 | 1 startup-catalog guard test passed after allowing the new Slice 4 filesystem function ids while continuing to reject retired legacy filesystem spellings. |
| `scripts/personal-info-guard.sh` | exit 0 | Full scan reported no personal-info leaks in source. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files reported. |
| `scripts/tron ci fmt check clippy test` | exit 0 | Full Rust CI passed after Slice 4 implementation, static guard updates, inventory/evidence updates, and focused filesystem tests; existing dead-code warnings remained warnings only. |

No Swift or Xcode project files changed, so XcodeGen and iOS simulator tests
were not run for Slice 4.

Order 19 audit-fix evidence on branch `codex/order-19-filesystem-tools-fix`:

- Removed legacy `file_read`/`file_write` from provider schema, OpenAI prompt
  guidance, authority working-directory classification, and
  `capability::execute` dispatch. Regression coverage now proves `file_write`
  is rejected through `capability::execute` and does not write a file.
- Preserved trace file evidence for committed filesystem mutations by deriving
  trace file records from hardened `filesystem_*` result metadata rather than
  from legacy request content.
- Narrowed provider/evidence claims: provider converter tests cover operation
  names and prompt guidance; filesystem/capability execution tests cover
  mutation refusals for unavailable hashes and truncated exact-patch previews.
- Clarified the historical branch evidence for Slice 4. Current consolidated
  mainline state carries the accepted artifacts; the branch refs remain
  provenance rather than a separate source of authority.

Adversarial self-review:

- Fixed a provider-visible path disclosure issue by changing filesystem execute
  results from absolute canonical paths to `root: "working_directory"` plus a
  relative path. Resource/audit evidence may still retain canonical locations
  where committed materialized files require provenance.
- Fixed an orchestrator-review data-loss issue: exact-text patching previously
  could operate on a truncated preview, and existing-file commit hash validation
  treated unavailable hashes as the string `"missing"`. Both now fail closed,
  with regressions proving the original file remains unchanged.
- Rechecked traversal, symlink escape, unbounded IO, binary-body disclosure,
  idempotency, expected-hash, rollback-preview, stale registration, and static
  guard risks. Real guard drift found during validation was narrowed to the new
  Slice 4 package and rerun.

## Slice 5A Implementation Evidence

Branch: `codex/phase-2-jobs-process-lifecycle-current`

Baseline: `1d35ac848` on top of `2650dd0b9`

Scope shipped:

- Added the modular `jobs` domain as the owner for durable non-interactive
  local process jobs and exposed `job_start`, `job_status`, `job_list`,
  `job_log`, and `job_cancel` through the existing provider-visible
  `capability::execute` boundary.
- Added built-in `job_process` resource definitions, bounded
  `execution_output` artifact creation, `jobs.lifecycle` stream evidence,
  trace/replay refs, authority/scope refs, cancellation metadata, terminal
  idempotency, and retention cleanup that archives scoped terminal jobs.
- Reused existing authority, working-directory freshness, resource, stream,
  trace, replay, output, idempotency, and shutdown primitives. Core changes
  were limited to generic resource/authority recognition needed by the new
  package; no transport, DB, provider, auth, settings, or iOS DTO surfaces were
  widened.
- Kept `process_run` as the synchronous bounded command primitive. Durable
  lifecycle state lives in the modular jobs package.
- Enforced fail-closed `networkPolicy: none` for process jobs: job start denies
  unsupported policy values and fails closed when the host cannot enforce
  network denial.
- Post-review hardening moved jobs to an owned process group on supported
  Unix/macOS hosts, bounds output draining to timeout/cancel/shutdown cleanup,
  and changes cancellation from "terminal write before kill" to
  "runtime cancel request, then terminal finalization with output evidence."
- Late cancel requests against completed processes now return
  completion-pending/already-terminal status and cannot overwrite completion or
  discard `execution_output` evidence.
- Runtime finalization now retries a stale job-resource version when a
  cancellation-request update lands between finalization's resource read and
  terminal update; the retry reuses the created output resource/link and
  preserves cancellation metadata.
- Re-audit follow-up for Order 20/Slice 5A fixes stale pre-startup `running`
  job reconciliation when more than 500 newer non-reconcilable rows occupy the
  public newest-first page. Startup/list/cleanup reconciliation now uses an
  internal scoped scan, and targeted status/log/cancel paths reconcile the
  addressed scoped resource before returning it while preserving live
  runtime-owned and post-startup rows.
- Deliberately deferred PTY/interactive terminals, interpreters/runtime
  packages, git/worktree/source-control behavior, web/network behavior,
  subagents, scheduling, native iOS process panels, notifications, and
  production deployment behavior.
- Deferred queue-backed internal job dispatch. The implementation found that
  queuing a hidden jobs runner from model-launched `execute` would require a
  new queued-internal-grant design, which is outside Slice 5A.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::jobs -- --nocapture` | exit 0 | 13 jobs-domain tests passed, covering schema alignment, start/status/list/log/cancel behavior, restart reconciliation for stale running resources including the >500 newer non-reconcilable row scan regression, terminal idempotency, bounded output, timeout terminal output, inherited-pipe background child cleanup, process-exit/cancel race, forced cancel-request/finalization version conflict retry, shutdown cancellation, output/resource evidence, cleanup archiving, and fail-closed network policy. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture` | exit 0 | 3 capability-domain tests passed with job execute operations registered. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture` | exit 0 | 26 provider prompt/converter tests passed after documenting the job operation names and provider-visible execute boundary. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | 17 SACB tests passed after classifying jobs files including `race_tests.rs`, operations, working-directory requirements, network-policy denial, and mutating idempotency requirements. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture` | exit 0 | 12 TMB tests passed; jobs are classified as a package owner using engine/resource facades instead of private stores. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | exit 0 | 12 CSD tests passed after classifying the process runtime, shutdown/cancellation ownership, and `race_tests.rs` cancellation/finalization interleaving coverage. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | exit 0 | 35 HRA tests passed; jobs files and ownership rows are inventoried. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | exit 0 | 16 PCC tests passed with jobs retained as shipped Slice 5A package code. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | exit 0 | 15 TPC tests passed after adding jobs retention rows and refreshing summary counts. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | exit 0 | 8 BPRC tests passed after documenting jobs as the planned Slice 5A restoration of process/job capability, not a legacy shell revival. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture` | exit 0 | 8 IARM tests passed; Slice 5A remains generic resource/result rendering first and does not add native iOS process UI. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | exit 0 | 11 OPSAA tests passed; jobs do not restore autonomous-authorship workers, scheduling, subagents, or generated-runtime surfaces. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | exit 0 | 7 PRG tests passed; jobs keep bounded output and process cleanup under the existing resource-governance model. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | exit 0 | 17 DRC tests passed after documenting jobs as the owner for lifecycle audit timestamps and elapsed-time diagnostics while keeping replay identity based on resource refs/hashes and stream/trace evidence. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | 9 DESI tests passed after adding Slice 5A implementation evidence and deferred queue-dispatch rationale. |
| `scripts/personal-info-guard.sh` | exit 0 | Full scan reported no personal-info leaks in source. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files reported. |
| `scripts/tron ci fmt check clippy test` | exit 0 | Full Rust CI passed after Slice 5A process-group cancellation hardening, bounded output-drain cleanup, cancel/completion race fixes, validation evidence updates, and static inventory refreshes; existing dead-code warnings remained warnings only. |

No Swift or Xcode project files changed, so XcodeGen and iOS simulator tests
were not run for Slice 5A.

Order 20/Slice 5A re-audit evidence on follow-up branches is represented on the
current consolidated mainline; the branch refs remain provenance for the
accepted fixes.

Adversarial self-review:

- Fixed static inventory drift found by validation in SACB, TMB, CSD, HRA,
  PCC, and TPC by adding explicit jobs rows and refreshing guarded counts.
- Fixed a DRC allow-list gap caught by full CI: jobs lifecycle timestamps and
  process elapsed-time measurements are now documented as audit/diagnostic
  clocks, not replay identity inputs.
- Rechecked core widening, hidden provider/auth/settings/iOS DTO expansion,
  private engine store coupling, unbounded stdout/stderr, cancellation races,
  terminal-state resurrection, idempotency gaps, stale registration, network
  smuggling, and queue-backed dispatch. Queue-backed internal dispatch remains
  intentionally deferred pending a separate grant model.
- Independent review found that direct-child-only cancellation could leave
  inherited-pipe descendants alive past timeout/cancel/shutdown, and that
  `job_cancel` could overwrite real completion before runtime output
  finalization. The fix moved cleanup to owned process groups, bound output
  draining after terminal signals, and made cancellation terminal state a
  runtime-finalized outcome rather than a pre-kill resource write.
- Second independent review found that cancellation-request metadata could
  still race terminal finalization's compare-and-set update. The fix added a
  bounded finalization retry that reloads the current nonterminal job, merges
  cancellation metadata, and attaches the existing output resource evidence
  before writing the terminal state.

## Phase 2 Slice 6A: Read-only Git/Worktree Foundation

Accepted implementation branches:
`codex/phase-2-slice-6a-readonly-git-worktree`,
`codex/phase-2-slice-6a-review-fixes`,
`codex/phase-2-slice-6a-review-fixes-2`, and
`codex/review-phase-2-slice-6a-final`.
Baseline: `origin/main@470e73897b885264aec0a6c9692e54eb2a186ef1`.
Independent review thread `019ef942-3a15-74c0-8230-7065c4e0000d` returned
`slice accepted` with no remaining findings. Mainline integration preserves
the reviewed commits through merge parent `1ecfb7ffb` and equivalent
mainline cherry-picks `76b1ce6cc`, `60bd839a7`, and `a86d9a470`.

What changed:

- Slice 6A adds a narrow read-only `domains/git` package with `git::status`
  and `git::diff` backend contracts.
- Slice 6A exposes provider access only as `git_status` and `git_diff`
  operation values behind the existing `capability::execute` primitive.
- Slice 6A reports trusted-path repository facts: worktree root, requested
  path, branch or detached HEAD, HEAD OID, upstream, ahead/behind, dirty state,
  staged/unstaged/untracked/conflicted summaries, and bounded status/diff
  evidence.
- Slice 6A keeps the implementation read-only: no staging, commits, merges,
  rebases, resets, pushes, branch checkout/deletion, conflict resolution,
  worktree graph resources, PR handoff, public API expansion, production
  deployment behavior, or native iOS SourceChanges UI.
- Review fixes disable configured Git textconv commands for staged and
  unstaged diff evidence, capture status/diff stdout through bounded readers,
  and stream full `git_diff` status-preflight counts while retaining only
  bounded status evidence bytes.

Deterministic coverage:

- Clean repo, dirty repo with staged/unstaged/untracked entries, nested repo
  path scoping, detached HEAD, missing upstream, upstream ahead/behind,
  non-repo path, trusted-root escape rejection, bounded/truncated status and
  diff output, configured textconv suppression, provider execute routing, and
  schema guards proving no mutating git operation names are exposed.

Validation on final review and mainline closeout:

- `cargo test --manifest-path packages/agent/Cargo.toml git -- --nocapture`
  passed; final review observed 15 matching library tests plus filtered static
  gate matches, covering git-domain behavior, provider
  execute routing, read-time bounded/truncated output, textconv suppression,
  static-gate wiring matches, event-store OAuth redaction, and the read-only
  schema guard.
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
  passed; final review passed the pending-review guard, and mainline closeout
  passed all 8 BPRC tests after promoting the Slice 6A read-only git package
  to current baseline.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `cargo check --manifest-path packages/agent/Cargo.toml` passed.
- `git diff --check` passed.
- `scripts/personal-info-guard.sh` passed.

## Phase 2 Slice 6B: Git Index Mutation Foundation

Implementation branch:
`codex/phase-2-slice-6b-git-index-mutation`.
Required baseline:
`origin/main@743b783976b0515372e5525c0c1671f5dbec37bd`
(`docs: shape slice 6b git index handoff`).

What changed:

- Slice 6B keeps provider-visible Git access behind the existing
  `capability::execute` primitive and adds only `git_stage` and `git_unstage`
  operation values.
- Slice 6B adds explicit `git_stage`/`git_unstage` index mutation as the only
  admitted Git write operation names.
- The Git domain owns backend `git::stage` and `git::unstage` contracts with
  `git.write` authority, explicit caller idempotency, expected HEAD, human/action
  reason, resource lease, manual compensation note, resource-backed output, and
  `git.lifecycle` stream evidence.
- Stage/unstage mutate only the Git index for explicit relative paths under
  trusted working-directory metadata. The implementation rejects absolute paths,
  traversal/worktree-root escapes, missing paths, non-repo targets, nested-repo
  misuse, stale expected HEAD, and conflicted pathspecs before running the index
  command.
- Successful index mutations create a `git_index_change` resource carrying
  bounded before/after status and staged/unstaged diff evidence, trace/replay
  refs, authority metadata, idempotency metadata, and revision/timestamp fields.
- Successful index mutations publish `git.lifecycle` stream events pointing back
  to the `git_index_change` resource. This uses the existing engine stream
  substrate rather than adding transport-visible session event DTOs.
- Non-goal Git behavior remains absent: commits, branch create/checkout/delete,
  merge, rebase, reset, stash, clean, fetch/pull/push, PR handoff, conflict
  resolution workflows, worktree graph resources, public `/engine` DTO expansion,
  native iOS SourceChanges UI, and production deploy behavior.

Deterministic coverage:

- Successful stage and unstage in a temp repository, proving only the index
  changes while worktree content remains untouched.
- Resource and stream evidence for committed stage operations.
- Idempotency replay with the same caller key returning the same resource and
  stream cursor without publishing a new lifecycle event.
- Rejection coverage for stale expected HEAD, absolute paths, traversal escapes,
  missing paths, non-repo targets, nested-repository misuse, and conflicted
  pathspecs/index conflicts.
- Bounded before/after evidence and truncation flags for index mutation
  snapshots.
- Slice 6A read-only status/diff coverage remains in the same Git-focused test
  target, including textconv suppression and bounded diff/status evidence.
- Provider schema/instruction tests and BPRC static guards now allow only
  `git_stage`/`git_unstage` as the Slice 6B mutation exception while continuing
  to reject later source-control non-goals.

Validation on implementation branch before commit:

- `cargo test --manifest-path packages/agent/Cargo.toml git -- --nocapture`
  passed with 22 matching library tests plus matched static gate tests.

Independent review and fix-loop evidence:

- Implementation thread `019ef956-6555-78d3-9956-8147108c7c14` produced
  `0689cbd5d58efcd764fbd6124e618bf0546e051b`.
- Review thread `019ef979-66d7-7aa2-8a83-21e2285522b4` required fixes for
  missing provider-visible mutation path requirements, bounded-status conflict
  preflight, and pre-acceptance docs wording.
- Fix thread `019ef982-1405-7a61-9231-9ecb95dddce8` produced
  `982e753d4a5a697c291307fbc9da466089e03b87`; review thread
  `019ef98b-d735-7c31-b564-b52b24bece05` then required static docs/inventory
  fixes.
- Fix thread `019ef993-a563-77b3-916b-c4d7cfc08f9b` produced
  `c473be51dd35d8083ca736f30e81cbfa83e81d78`; final review thread
  `019ef99a-3d8a-7fc2-9dca-a9251947d29e` then required HRA pending-review
  wording fixes.
- Docs-only fix commit `34b860b56ab20f6ff69f7ee177ce8906ceeead87` corrected
  HRA pre-integration wording; re-review thread
  `019ef9a4-2cc8-7f82-8f4c-6d95fe13b4ce` then required the BPRC invariant
  test file to receive an HRA large-file budget row.
- Fix thread `019ef9a8-79ae-7b82-9fb4-4e5bf6426d49` produced
  `c9583b1f4647bae7e5c09bf8460f2e40a340ac77`.
- Final accepting review thread `019ef9aa-d71e-7010-be57-82f8ca6ca323`
  reported no findings, verified `origin/main@743b783976b0515372e5525c0c1671f5dbec37bd`
  as an ancestor, verified all five candidate commits in order, and passed:
  `git diff --check`, `scripts/personal-info-guard.sh`,
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`,
  `cargo test --manifest-path packages/agent/Cargo.toml git -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants large_source_files_have_explicit_cleanup_budget_rows -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants boundary_inventory_covers_tracked_sources -- --nocapture`,
  and `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture`.

Mainline closeout validation before push:

- `git diff --check` passed.
- `scripts/personal-info-guard.sh` passed.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `cargo check --manifest-path packages/agent/Cargo.toml` passed with existing
  dead-code warnings.
- `cargo test --manifest-path packages/agent/Cargo.toml git -- --nocapture`
  passed from `main`.
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
  passed from `main` after the BPRC static gate was updated to require accepted
  Slice 6B current-baseline status and reject stale pre-integration wording.
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants large_source_files_have_explicit_cleanup_budget_rows -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants boundary_inventory_covers_tracked_sources -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture`
  passed.

## Phase 2 Slice 6C Discovery: Git Commit Evidence Foundation

Discovery branch: `codex/phase-2-slice-6c-discovery`.
Baseline:
`origin/main@d70486e8a8dbac3723ae0efca3fef816af12a612`
(`docs: record slice 6b acceptance`).

Selected next implementation slice:
**Phase 2 Slice 6C: Git Commit Evidence Foundation**.

Discovery outcome:

- Current `main` and canonical Phase 2 docs are sufficient to define a fresh
  implementation slice after accepted Slice 6B.
- The next safe source-control step is `git_commit`: create one commit from the
  already-staged index on the current named branch, with expected HEAD,
  expected index-tree freshness, explicit reason, caller idempotency,
  resource-backed `git_commit` evidence, and `git.lifecycle` stream evidence.
- The slice must expose/read the staged index tree before commit so a caller can
  bind commit execution to the exact reviewed staged content, not merely to the
  current HEAD.
- The slice must suppress or fail closed around repository hooks, editors,
  pagers, credential prompts, GPG signing, and network-dependent helper paths.
- Detached HEAD commits, branch create/checkout/delete, merge/rebase/reset,
  revert/cherry-pick, stash/clean, fetch/pull/push, PR handoff, conflict
  resolution workflows, worktree graph resources, public API expansion,
  production deploy behavior, and native iOS SourceChanges remain deferred.

Required implementation evidence is specified in the scorecard's
`Selected Slice 6C Discovery Packet`: request fields, `git_commit` resource
schema, lifecycle event shape, likely files, deterministic tests, docs/static
updates, risks, and validation commands. This discovery section records no
runtime behavior implementation.

## Phase 2 Slice 6C Accepted Implementation Evidence: Git Commit Evidence Foundation

Implementation branch: `codex/phase-2-slice-6c-git-commit-evidence`.
Baseline:
`origin/main@bc469ba3458ecce8301eb84abbd82070cfd0362a`
(`docs: shape slice 6c git commit handoff`).

Accepted status: Slice 6C is accepted after independent review/fix loops and
fast-forward integration into `main`.

Implementation evidence:

- Adds provider-visible `git_commit` only through the existing
  `capability::execute` primitive and backend Git commit service; no direct
  `git::commit` catalog function is registered.
- Creates exactly one commit from the already-staged index on the current named
  branch after `expectedHead`, `expectedIndexTree`, `reason`, bounded
  `message`, and idempotency checks.
- Exposes staged index tree evidence through repository facts without using
  `git write-tree`; the tree hash is derived from `git ls-files -s -z` and
  `git hash-object -t tree --stdin` without `-w`, and fails closed if the
  index listing is truncated.
- Rejects stale head, symbolic HEAD branch drift, stale index tree, empty staged
  index, detached HEAD, conflicted/unmerged index entries, non-repo and
  nested-repo misuse, path escapes, missing trusted working-directory metadata,
  empty message, and empty
  reason before committing.
- Suppresses hooks, editors, pagers, GPG signing, terminal prompts, askpass,
  and credential helpers with explicit command environment/config controls.
- Records `git_commit` resources (`tron.resource.git_commit.v1`) with commit
  oid, parent oid, actual tree, branch, expected head/index tree, authority,
  reason, bounded message metadata, before/after bounded evidence, trace/replay
  refs, idempotency, revision, and timestamp; publishes `git.commit_created`
  lifecycle events with resource refs.
- Keeps branch operations, merges/rebases/resets, remotes, PR handoff, conflict
  resolution workflows, worktree graph resources, public `/engine` DTO
  expansion, native SourceChanges UI, and production deploy behavior deferred.

Independent review and fix-loop evidence:

- Implementation thread `019ef9bc-d9d2-7f13-8966-7659f90e6d06` produced
  `ce147b9ff9958c101fa7b9d40d26b0470eafbf60`.
- Review thread `019ef9e2-1d45-7301-b20e-c7df03274a22` required fixes for
  hidden merge-commit risk after resolved merge state and stale
  mutation-boundary guarding.
- Fix thread `019ef9e7-6156-7bf1-8082-945be924808a` produced
  `f603ea566de9b021ec14cdc123f3cf71b43f1bad`, replacing porcelain commit with
  commit-tree, single-parent/tree verification, and guarded branch ref update.
- Re-review thread `019ef9f0-1a49-74c2-982d-b5bd08340256` required a symbolic
  HEAD drift fix before final branch ref update.
- Fix thread `019ef9f4-ffa5-7221-b5ac-3af6489bb65c` produced
  `6ec2e03baf03bf260e8e1d3522c93ef8bdeb563f`, adding HEAD lock/recheck
  protection and deterministic synthetic-gitdir branch CAS handling.
- Final independent review thread `019efa01-45ba-77b2-a2be-b8c0d2ac1d18`
  returned `slice accepted` with no findings. It verified the three-commit
  stack over `origin/main`, execute-only `git_commit`, prior P1 fixes, and the
  focused validation suite.

Validation on final review and mainline closeout:

- Final review passed `git diff --check origin/main...HEAD`,
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`,
  `scripts/personal-info-guard.sh`, `cargo check --manifest-path
  packages/agent/Cargo.toml`, `cargo test --manifest-path
  packages/agent/Cargo.toml git`, focused `domains::capability` and OpenAI
  message-converter tests, and the requested BPRC, HRA, TMB, TPC, and DRC
  invariant files.
- Mainline closeout reruns the same focused validation from `main` before
  pushing and records accepted commit ancestry in the orchestration summary.

## Phase 2 Slice 6D Discovery: Git Branch Start Foundation

Discovery branch: `codex/phase-2-slice-6d-discovery`.
Baseline:
`origin/main@1fa3e0009176a5c8df9a659e81e4f1329c4c2b96`
(`docs: record slice 6c acceptance`).

Discovery status: selected. Implementation may start from fresh `origin/main`;
this discovery does not implement runtime behavior.

Selected scope:

- Add only a local `git_branch_start` source-control operation through the
  existing `capability::execute` primitive and `domains/git` package boundary.
- Create exactly one new local `refs/heads/<branchName>` ref at `expectedHead`
  and move symbolic `HEAD` to that ref after freshness checks.
- Preserve the current index and worktree content exactly; no `git checkout`,
  file writes, stage/unstage, commit, branch deletion/rename, upstream setup,
  remote/network command, PR handoff, merge/rebase/reset, stash/clean, conflict
  workflow, worktree graph resource, native SourceChanges UI, or production
  deployment behavior is in scope.
- Require branch-name validation, expected head, reason, idempotency, trusted
  working-directory repository checks, conflict/sequencer rejection, bounded
  before/after evidence, `git_branch_start` resource evidence, and
  `git.lifecycle` stream evidence.

Discovery evidence:

- Baseline was verified clean on `main` after `git fetch origin main`; local
  `HEAD` and `origin/main` both resolved to
  `1fa3e0009176a5c8df9a659e81e4f1329c4c2b96`.
- Required canonical docs were read from the accepted Slice 6C mainline:
  README capability/source-control sections, Phase 2 scorecard/evidence/
  inventory artifacts, retrospective tracker, inventory TSV row
  `P2AER-INV-013`, and `packages/agent/src/domains/git/mod.rs`.
- Existing `domains/git` architecture shows a staged-state-only invariant with
  status/diff, stage/unstage, and commit support. Branch start is the next
  narrow local boundary before remote push/PR, conflict, merge/rebase/reset, or
  native UI work.
- The scorecard now contains the full Slice 6D handoff packet: objective,
  user value, modular boundary, request/resource/event shape, likely files,
  non-goals, safety risks, deterministic tests, docs/static updates, validation
  commands, and residual decisions.

## Phase 2 Slice 6D Accepted Implementation: Git Branch Start Foundation

Implementation branch: `codex/phase-2-slice-6d-branch-start`.
Baseline:
`origin/main@4d7221bf436acce3406d50ab0b1f2a06415616be`
(`docs: shape slice 6d branch start handoff`).

Implementation status: accepted after independent review/fix loops and
integrated into mainline.

Implemented scope:

- Added provider-visible `git_branch_start` as an operation value behind the
  existing single `capability::execute` primitive.
- Kept backend behavior in `domains/git` with a new `branch_start` module.
- Creates exactly one new local branch ref at `expectedHead` and moves symbolic
  `HEAD` to it through a locked guard that rechecks the old symbolic branch and
  resolved OID without invoking checkout.
- Requires `branchName`, `expectedHead`, non-empty `reason`, explicit payload
  `idempotencyKey`, trusted working-directory metadata, current named branch
  provenance, and clean conflict/sequencer state.
- Rejects stale heads, existing branch names, unsafe/ref-injection/reserved
  branch names, detached HEAD, non-repo and nested-repo misuse, missing
  metadata, empty reason, and missing idempotency.
- Records `git_branch_start` resource evidence and `git.branch_started`
  lifecycle stream evidence with trace/replay/idempotency/authority refs.
- Preserves staged, unstaged, and untracked worktree state; tests compare
  before/after status, staged names, unstaged names, index tree, branch refs,
  file content, and branch-start rejection when the current branch OID drifts
  before symbolic `HEAD` movement.
- Provider schema and instruction tests expose only the new
  `git_branch_start` source-control operation while continuing to reject
  checkout, branch delete/rename/move, merge/rebase/reset, push/pull/fetch,
  remote, stash, clean, cherry-pick, and revert names.

Implementation evidence:

- `cargo test --manifest-path packages/agent/Cargo.toml git` passed on the
  implementation branch with 46 git-filtered tests, including branch-start
  success, replay, stale/existing/invalid branch rejection, detached/conflict/
  sequencer rejection, missing metadata/idempotency/reason rejection, nested
  repo rejection, checkout-hook suppression, resource-definition coverage, and
  provider/static schema guards.

Independent review and fix-loop evidence:

- Implementation thread `019efa12-c7ca-7942-a90b-e52f721fbee7` produced
  `83030ba226a436cd72406fae1d5a53aa01dbed59`, adding local branch-start
  behavior through `capability::execute` and `domains/git`.
- Review thread `019efa28-ffe5-7291-b7de-00ab4c700557` required rollback
  hardening for symbolic `HEAD` movement failures after branch creation.
- Fix thread `019efa32-013b-70d1-9fe7-2824c84eda5c` produced
  `2d8d804ce00358800746d46788e03ab584cc12ec`, adding deterministic rollback
  coverage for successful and failed branch-ref cleanup.
- Re-review thread `019efa3c-8a0c-7863-9ea7-3d337fa8a7ec` required guarding
  against stale symbolic-HEAD movement after the current branch or OID changed
  between preflight and branch switch.
- Focused fix commit `cfff8bc5f732243724dc97c964a613070ef9736c` added the
  locked symbolic-HEAD old-ref/OID recheck, deterministic OID-drift coverage,
  and evidence/docs updates. The queued fix worker
  `019efa3f-df78-7d71-ab38-345daeb55d98` was paused without edits before this
  narrow fix was committed in the implementation worktree.
- Final independent review thread `019efa4a-ffdd-7e32-b08e-f175e2a44f1a`
  returned `slice accepted` with no blocking findings. It verified branch
  topology, execute-only dispatch, resource schema registration, prior P1
  fixes, and focused validation.

Validation on final review and mainline closeout:

- Final review passed `cargo fmt --manifest-path packages/agent/Cargo.toml
  --all -- --check`, `git diff --check origin/main...HEAD`, and `cargo test
  --manifest-path packages/agent/Cargo.toml git_branch_start -- --nocapture`
  with 10 branch-start tests.
- Implementation branch validation passed `scripts/personal-info-guard.sh`,
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`,
  `git diff --check origin/main...HEAD && git diff --check`, `cargo test
  --manifest-path packages/agent/Cargo.toml --lib domains::capability --
  --nocapture`, `cargo test --manifest-path packages/agent/Cargo.toml git --
  --nocapture`, and the touched BPRC, HRA, TMB, TPC, PCC, DRC, DESI, IARM, and
  SACB invariant files.
- Mainline closeout from `main` passed `cargo check --manifest-path
  packages/agent/Cargo.toml`, `cargo test --manifest-path
  packages/agent/Cargo.toml git -- --nocapture` with 46 git-filtered tests,
  `cargo test --manifest-path packages/agent/Cargo.toml --lib
  domains::capability -- --nocapture`, the touched BPRC, HRA, TMB, TPC, PCC,
  DRC, DESI, IARM, and SACB invariant files, `cargo fmt --manifest-path
  packages/agent/Cargo.toml --all -- --check`, `git diff --check`, and
  `scripts/personal-info-guard.sh`.

## Phase 2 Slice 6E Discovery: Git Branch Inventory Foundation

Discovery branch: `codex/phase-2-slice-6e-discovery`.
Baseline:
`origin/main@719ebb5fc6d0db082a2577e44aa60982abbed253`
(`docs: record slice 6d acceptance`).

Discovery status: selected. Implementation may start from fresh `origin/main`;
this discovery does not implement runtime behavior.

Selected scope:

- Add only a read-only branch inventory source-control operation through the
  existing `capability::execute` primitive and `domains/git` package boundary.
- Report bounded local branch evidence for the trusted repository root:
  current branch or detached state, local branch names/refs, oids, upstream
  names when present, ahead/behind when available without network, and bounded
  last-commit metadata.
- Do not create, switch, delete, rename, reset, merge, rebase, revert,
  cherry-pick, stash, clean, fetch, pull, push, set upstreams, create PRs,
  create worktrees, mutate the index, edit worktree files, add public `/engine`
  DTOs, add native SourceChanges UI, or run production deployment behavior.
- No durable resource kind is required unless implementation discovers a real
  replay-custody need beyond normal invocation/result trace evidence.

Discovery evidence:

- Baseline was verified after `git fetch --prune`; local `HEAD` and
  `origin/main` both resolved to
  `719ebb5fc6d0db082a2577e44aa60982abbed253`.
- Required canonical docs were read from accepted Slice 6D mainline: README
  capability/source-control sections, Phase 2 scorecard/evidence/inventory
  artifacts, retrospective tracker, inventory TSV row `P2AER-INV-013`, and
  `packages/agent/src/domains/git/mod.rs`.
- Existing `domains/git` architecture shows read-only status/diff plus narrow
  stage, commit, and branch-start mutation boundaries. Since canonical docs
  still defer arbitrary checkout, branch delete/rename, remotes, conflict
  workflows, worktree graph resources, and native SourceChanges, branch
  inventory is the next safe source-control slice before any broader branch
  mutation.
- The scorecard now contains the full Slice 6E handoff packet: objective, user
  value, modular boundary, request/output shape, likely files, non-goals,
  deterministic tests, docs/static updates, validation commands, and residual
  decisions.

## Phase 2 Slice 6E Accepted Implementation: Git Branch Inventory Foundation

Implementation branch: `codex/phase-2-slice-6e-branch-inventory-v2`.
Implementation baseline:
`origin/main@2241def83033d3bb49836b0d6b1ecf3c36fc8c39`
(`docs: shape slice 6e branch inventory handoff`).

Accepted commits:

- `7f72e9407bf1dfc39b9a41dd091fc7fd7565d432` (`feat: add git branch inventory foundation`);
- `16025248d4b9f470786e61888d5f74b7fc9f3572` (`Fix truncated branch metadata inventory evidence`).

Review/fix evidence:

- Initial independent review thread `019efa73-0911-7bc2-a10c-37be6ab374d9`
  returned `changes required` for oversized branch metadata that could truncate
  before all NUL-delimited fields and fail the whole inventory operation.
- Focused fix thread `019efa76-51cd-7902-8fca-aed5bb3487f9` committed
  `16025248d4b9f470786e61888d5f74b7fc9f3572`, preserving bounded row evidence
  with metadata truncation flags and adding an oversized-author regression.
- Final independent re-review thread `019efa7c-7bb9-7803-bf80-224f8b799c1b`
  returned `slice accepted` with no findings.

Accepted evidence:

- Adds read-only `git_branch_inventory` behind the existing
  `capability::execute` primitive; no direct `git::branch_inventory` catalog
  contract and no branch-inventory resource kind are added.
- Implements branch inventory under `packages/agent/src/domains/git/` with
  trusted-root repository validation shared with prior Git slices.
- Returns current branch or detached `HEAD` evidence, sorted local branch
  rows, local branch refs/names/OIDs, optional local upstream/ahead-behind
  counts, bounded last-commit subject/time/author metadata, oversized metadata
  rows as truncated evidence, and explicit `maxBranches`/`maxBranchBytes`
  truncation metadata.
- Rejects non-repo paths, traversal, missing trusted working-directory
  metadata, and nested-repo misuse.
- Keeps later mutation scope deferred: checkout/switch, branch deletion/rename,
  upstream setup, merge/rebase/reset/revert/cherry-pick, stash/clean,
  fetch/pull/push, PR handoff, worktree graph resources, public `/engine`
  DTOs, native SourceChanges UI, durable branch-inventory resources, and
  production deployment behavior.

Validation recorded before mainline closeout:

- `cargo test --manifest-path packages/agent/Cargo.toml git_branch_inventory -- --nocapture`
  passed with seven focused tests covering sorted/current branch evidence,
  detached `HEAD`, upstream/no-upstream, count/byte truncation, unusual branch
  names, oversized metadata truncation, path/repo rejection, and provider
  execute boundary.
- `cargo check --manifest-path packages/agent/Cargo.toml` passed with existing
  dead-code warnings.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`,
  `git diff --check`, and `scripts/personal-info-guard.sh` passed.
- Independent re-review also passed the baseline closure, HRA, true modularity,
  true primitive cleanup, primitive code cleanup, SACB, and DESI invariant
  targets.

## Phase 2 Slice 7A Discovery: Goal And Question Foundation

Discovery branch: `codex/phase-2-slice-7a-discovery`.
Baseline:
`origin/main@db05cd467ff028530df043dc754dfd252c2211ac`
(`docs: record slice 6e acceptance`).

Discovery status: selected. Implementation may start from fresh `origin/main`;
this discovery does not implement runtime behavior.

Selected scope:

- Add the first backend Slice 7 sub-slice as a domain/package-owned goal and
  question foundation, not a broad autonomous planning/runtime slice.
- Reuse existing engine queues, generic resources, streams, idempotency,
  approvals, memory trace refs, and replay rows.
- Restore durable goal lifecycle operations and durable user-question lifecycle
  operations behind the existing `capability::execute` primitive.
- Record bounded queue/resource/stream/replay evidence and answer provenance.
- Keep native iOS Work dashboards and question sheets deferred until after the
  backend contract exists.

Discovery evidence:

- Baseline was verified after `git fetch --prune`; the discovery worktree was
  initially detached at `db05cd467ff028530df043dc754dfd252c2211ac`, and
  `origin/main` resolved to the same commit.
- Required canonical docs were read from accepted Slice 6E mainline: README
  capability/source-control/resource sections, Phase 2 scorecard/evidence/
  inventory artifacts, retrospective tracker, inventory TSV rows
  `P2AER-INV-010` and `P2AER-INV-013`, and relevant `domains`, Git, jobs,
  approval, queue, resource, registration, and capability docs/source.
- Fresh discovery found no smaller required source-control follow-up after
  Slice 6E. Current docs classify read-only status/diff, index stage/unstage,
  staged-index commit, branch start, and branch inventory as current baseline,
  while arbitrary checkout, branch deletion/rename, remotes, conflict
  workflows, worktree graph resources, PR handoff, and native SourceChanges UI
  remain explicit deferred policy work.
- Current architecture has queue/resource/stream/replay substrate and an
  existing generic `goal` resource kind, but no package-owned goal/question
  lifecycle, user-question resource, answer provenance, or bounded
  queue-to-goal handoff contract.
- The scorecard now contains the full Slice 7A handoff packet: first-principles
  UX review, architecture review, exact implementation scope, non-goals, likely
  files, deterministic tests, docs/static updates, validation commands, risks,
  and residual decisions.

Discovery validation:

- `git diff --check` and `git ls-files -ci --exclude-standard` passed.
- `scripts/personal-info-guard.sh` passed with no personal-info leaks.
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  passed with 9 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
  passed with 8 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture`
  passed with 12 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed with 14 tests.

## Phase 2 Slice 8A Accepted Implementation: Web Fetch And Source Provenance Foundation

Implementation branch: `codex/phase-2-slice-8a-web-fetch-source-provenance`.
Baseline:
`origin/main@49a47cc1902a958eb775bcb5a3a28913d0d3aefb`
(`docs: accept phase 2 slice 7a`).
Accepted commits:
`f5b0bb0895f9f829541bfa426453b59cf0a401cd`,
`37e835d7b575ef3b4063a5c0da0b050fd6f8b192`, and
`77f0620545b4d277c0288cc9503e2d90cdf7e0b8`.
Threads:
implementation `019efaed-2665-72c2-aa07-11c1ba094076`, initial review
`019efb09-38db-7f20-9e12-e8424180b747`, focused fix
`019efb12-6784-7943-a134-41cb1669dc18`, first re-review
`019efb24-c729-7502-a099-a504b54190df`, second focused fix
`019efb2d-dced-7cf1-a139-a4c9c6c5aded`, and final accepting re-review
`019efb3c-e2b3-7950-b1f6-56cc884c509e`.

Accepted implementation evidence:

- Added the `web` domain owner for direct fetch source provenance without
  adding public `web::*` catalog functions.
- Added one provider-visible operation value behind `capability::execute`:
  `web_fetch`.
- Added the `web_source` resource definition for source/cache evidence:
  requested URL, final URL, fetched-at timestamp, status, content type,
  captured-byte count, SHA-256 hash, truncation metadata, redaction metadata,
  authority refs, trace refs, replay refs, and idempotency/cache refs.
- Runtime grant derivation keeps `networkPolicy: none` for existing execute
  operations and derives `networkPolicy: declared` only for `web_fetch`, with
  `web_source` as the additional resource kind.
- Fetch validation rejects unsupported schemes, credentials, fragments,
  malformed or overlong URLs, unsafe IPv4/IPv6 literals, unsafe DNS-resolved
  socket addresses, and unsafe redirect targets except deterministic HTTP
  loopback test targets.
- Fetch execution uses structured URL parsing and `reqwest`, not shell/process
  network paths, browser sessions, cookies, credentials, or provider search
  APIs.

Review findings and fixes:

- Initial review found redirect targets could be fetched before validation,
  domain hosts could resolve to local/internal IPs, and README startup wording
  could be read as accepting the candidate too early.
- Focused fix `37e835d7b575ef3b4063a5c0da0b050fd6f8b192` added redirect
  target validation before `follow()`, canonical host and resolver filtering,
  deterministic regressions, and candidate-scoped README wording.
- First re-review found IPv6 site-local/IPv4-compatible edge gaps and missing
  `network_policy.rs` inventory coverage.
- Focused fix `77f0620545b4d277c0288cc9503e2d90cdf7e0b8` rejects `fec0::/10`,
  unsafe IPv4-compatible `::/96`, and unsafe IPv4-translated embeddings,
  adds URL-literal and DNS-override regressions, and covers
  `network_policy.rs` in HRA, SACB, PCC, TMB, and TPC inventories.
- Final re-review returned `slice accepted` with no findings.

Accepted validation:

| Command | Result | Notes |
|---------|--------|-------|
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Compile check passed with pre-existing dead-code warnings. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::web -- --nocapture` | exit 0 | 10 focused web-domain tests passed, including unsafe IPv6 URL-literal and DNS-override regressions. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture` | exit 0 | 3 capability schema tests passed. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Formatting passed. |
| Static/inventory invariant bundle for SACB, HRA, TMB, TPC, PCC, BPRC, IARM, DESI, and public protocol | exit 0 | Static inventories and public-surface claims passed in implementation/fix/re-review validation. |
| `git diff --check 49a47cc1902a958eb775bcb5a3a28913d0d3aefb..77f0620545b4d277c0288cc9503e2d90cdf7e0b8` | exit 0 | Whitespace check passed for accepted range. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files. |
| `scripts/personal-info-guard.sh` | exit 0 | Personal-info guard passed. |

Deferred scope: search providers, browser automation, crawling, sitemap
traversal, robots policy, login/cookies/session reuse, credential reuse, shell
or process network side channels, native iOS web/source UI, public `/engine`
web APIs, and network-enabled jobs remain deferred to later slices.

## Phase 2 Slice 8B Accepted Implementation: Web Source Citation And Inspection Foundation

Implementation branch:
`codex/phase-2-slice-8b-web-source-citation-inspection`.
Baseline:
`origin/main@d2cb7cd32976f1de460defe5fc0cb094669b0140`
(`docs: accept phase 2 slice 8a`).
Accepted commit:
`8033e22932f55388a94f9d18ce6b11a91f9f1545`
(`feat: add web source citation inspection`).
Implementation thread:
`019efb53-19a3-7c43-8afd-2cf6972055cd`.
Independent review thread:
`019efb6e-dfc0-7b73-8bd6-d23f91e82248`.
Status: `accepted`.

Accepted implementation evidence:

- Adds execute-only `web_source_list` and `web_source_inspect` operation values
  behind the single provider-visible `capability::execute` primitive.
- Adds `domains/web/source.rs` as the read-only source inspection owner. The
  module returns bounded citation-ready fields from durable `web_source`
  resource payloads: requested/final URLs, fetched time, status, content type,
  captured SHA-256, captured/output byte counts, truncation/redaction metadata,
  redacted snippets, trace refs, replay refs, and resource refs.
- Requires trusted current-session execute context plus `web.read` and
  `resource.read` authority before returning source details. Grant derivation
  and central grant authorization now include web-source read operations and
  keep read operations at `networkPolicy: none`.
- Rejects malformed ids, wrong resource kind/schema, missing current versions,
  missing or stale requested versions, cross-session scope mismatches, and
  missing read authority.
- Keeps `web_fetch` as the only network operation; no search provider, browser
  automation, crawling, robots policy, login/cookies/session reuse, native
  source UI, public `/engine` API, or network-enabled job behavior is added.

Review and validation:

- Independent review thread `019efb6e-dfc0-7b73-8bd6-d23f91e82248` found no
  blocking issues and returned `slice accepted`.
- Review verified the expected head, baseline ancestry, read authority,
  current-session scope, stale/missing version rejection, no-network read
  behavior, provider operation exposure, static inventories, and
  personal-info guard.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `cargo check --manifest-path packages/agent/Cargo.toml` passed with
  pre-existing dead-code warnings.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::web -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib engine::tests::authority -- --nocapture`
  passed in review.
- SACB/HRA/TMB/TPC/PCC/BPRC/IARM/DESI/public-protocol static guards passed.
- `git diff --check`, `git ls-files -ci --exclude-standard`, and
  `scripts/personal-info-guard.sh` passed.

## Phase 2 Slice 7A Accepted Implementation: Goal And Question Foundation

Implementation branch: `codex/phase-2-slice-7a-goal-question-foundation-v2`.
Baseline:
`origin/main@9950ea484299901e09af9077f33466021118ca33`
(`docs: shape phase 2 slice 7a handoff`).

Accepted status: current baseline after independent review and mainline
integration. Final accepted branch head:
`4ecb612612abd7f000c059aafcd2c5e135361fa3`.

Accepted scope:

- Added `packages/agent/src/domains/goals/` as the backend owner for durable
  goal records, user-question records, and answer provenance.
- Kept provider-visible access under `capability::execute` operation values:
  `goal_create`, `goal_list`, `goal_inspect`, `goal_cancel`,
  `question_create`, `question_list`, `question_inspect`, and
  `question_answer`.
- Reused existing engine resources, streams, traces, replay refs, and the
  execute idempotency ledger; no autonomous runner, planner, scheduler,
  reminder, notification, subagent, public `/engine` goal API, settings, or
  native Work/question UI was added.
- Added `user_question` and `goal_answer` resource definitions and expanded the
  generic `goal` resource schema narrowly for lifecycle/evidence refs.

Accepted evidence:

- Goal create/list/inspect/cancel records include scoped resource refs,
  lifecycle state, bounded summaries, queue/plan/evidence refs, trace refs,
  replay refs, and cancellation reason/idempotency details.
- Question create/list/inspect/answer records include optional goal association,
  prompt/options/free-form/expiry fields, pending/answered/expired/cancelled
  lifecycle, answer provenance, authority/freshness refs, stream evidence, and
  expected-version guarding.
- Replaying the same `question_answer` idempotency key through
  `capability::execute` returns the stored answer evidence and leaves exactly
  one `goal_answer` resource.
- Stale expected versions, wrong scope, expired/closed questions,
  malformed/missing resource ids, missing reason, empty/oversized text, and
  missing/untrusted execution context fail closed in focused tests.

Implementation, review, and acceptance evidence:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::goals -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`
- Review `019efabf-6f5b-76b0-951b-13e28ae785f4` required resource-authority
  hardening for inner goal/question operations.
- Fix commits `6915bcfcd` and `b96494d89` require goal/question resource
  kinds/selectors and `goals.read`/`goals.write` scopes before handlers run.
- Review `019eface-a421-7271-b688-f5250066cf26` found the new authority test
  file missing from HRA inventory coverage; fix commit `4ecb61261` added the
  row across tracked inventories.
- Final review `019efad9-68bb-7ab0-9933-df140600ebed` accepted the slice with
  no blocking findings after `cargo fmt`, focused goal tests, execute authority
  regression, execute schema test, `cargo check`, HRA/TMB/TPC/PCC/SACB
  invariant group, `git diff --check`, ignored-file audit, and
  `scripts/personal-info-guard.sh` all passed.
- Mainline closeout validation after fast-forwarding `main` passed:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::goals`;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib capability_execute_inner_goal_operations_require_resource_authority -- --nocapture`;
  `cargo test --manifest-path packages/agent/Cargo.toml execute_schema_exposes_primitive_operations_not_catalog_targets`;
  `cargo check --manifest-path packages/agent/Cargo.toml`;
  HRA/TMB/TPC/PCC/SACB invariant group; DESI/BPRC/IARM documentation gates;
  `git diff --check`; ignored-file audit; and
  `scripts/personal-info-guard.sh`.

### Slice 8C Accepted Evidence: Web HTML/Text Extraction And Citation Quality Foundation

Implementation branch:
`codex/phase-2-slice-8c-web-html-text-extraction`.
Fix branch:
`codex/phase-2-slice-8c-web-html-text-extraction-fix1`.
Baseline:
`origin/main@5c99501b5e00305f3be95ae3fce4d2f855c6aed8`
(`docs: accept phase 2 slice 8b`).
Accepted implementation commit:
`ea4a4d04ceb37a10899871c3fe4f394ae10fbfa5`
(`feat: add web html text extraction`).
Accepted fix commit:
`5e881e8681229545fe8260a1dc2be8f47cd07a3a`
(`fix: sanitize web html titles`).

Accepted evidence:

- Added `packages/agent/src/domains/web/extract.rs` as a dependency-free,
  deterministic HTML/XHTML readable-text extraction module.
- Integrated extraction in `web_fetch` before output bounding, redaction, and
  snippet generation while preserving captured raw response bytes and raw
  captured-byte SHA-256 as source provenance.
- Added backward-compatible `textEvidence` metadata for extraction mode,
  extractor id/version, bounded/redacted safe title, extracted text bytes, and
  truncation flags.
- Updated `web_source_list` and `web_source_inspect` to surface extraction
  metadata when present and return `null` metadata for older Slice 8A/8B
  records.
- Added defensive source list/inspect title sanitization for existing or future
  records and deterministic regression coverage for secret-like and oversized
  title metadata.
- Kept provider-visible operation names unchanged and did not add search,
  browser, crawl, login, native source UI, public `/engine` web APIs, or
  network-enabled job behavior.

Review/fix loop:

- Initial review thread `019efb99-ee44-7901-b70a-56ea4643f302` returned
  `changes required` for unbounded/unredacted title metadata and missing HRA
  current-ownership-map coverage.
- Focused fix thread `019efb9e-766b-7273-862b-5e739ac73c01` committed
  `5e881e8681229545fe8260a1dc2be8f47cd07a3a`, adding title bounds/redaction,
  source output hardening, regression tests, and HRA ownership rows.
- Re-review thread `019efbac-4560-7382-a034-4ef36854367f` verified branch
  ancestry, title safety, HRA coverage, focused web tests, static guards, and
  repository hygiene, then returned `slice accepted`.

Accepted validation evidence:

- Focused web tests cover deterministic HTML fixture extraction, script/style
  and navigation/noise removal, redaction after extraction, JSON/XML/plain text
  preservation, binary omission, malformed HTML tolerance, oversized output
  bounds, non-UTF8 lossy text behavior, idempotent cache replay stability, and
  old `web_source` record inspection compatibility.
- Fix validation covers fetch result JSON, stored payload, source inspect, and
  source list for title redaction and title bounds.
- Mainline closeout validation reruns focused web, HRA/TMB/TPC/PCC/SACB/BPRC/
  IARM/DESI/public-protocol gates, repository hygiene, and personal-info guard
  before push.

### Slice 8D Implementation Candidate Evidence: Web Source Retention And Cache Policy Foundation

Implementation branch:
`codex/phase-2-slice-8d-web-source-retention-cache-policy`.
Baseline:
`origin/main@8ed8db55500f3a05aef55a1e2ec39acba30a8c07`
(`docs: accept phase 2 slice 8c`).
Status:
`pending_review`.

Candidate evidence:

- Adds `packages/agent/src/domains/web/archive.rs` as the web-owned
  current-session source archive lifecycle module.
- Adds execute-only `web_source_archive` behind `capability::execute` and
  wires least-privilege grant derivation plus engine authorization scope/kind
  checks for `web.read`, `web.write`, `resource.read`, `resource.write`, and
  `web_source`.
- Appends archived `web_source` versions with archive metadata while preserving
  source payload/provenance and using `expectedWebSourceVersionId` CAS.
- Updates `web_source_list` to default to active/fetched records and require
  explicit `includeArchived` for archived records.
- Keeps `web_source_inspect` able to inspect exact archived records for
  replay/citation audit.
- Keeps archive/list/inspect at `networkPolicy: none` with no network I/O.
- Adds focused `web_archive_tests.rs` coverage for archive success, stale CAS,
  wrong kind/scope, missing authority, idempotency replay, default list
  filtering, explicit archived inclusion, archived inspect, and no-network
  behavior.

Candidate non-goals remain deferred: search providers, browser automation,
crawling, robots/sitemap policy, login/cookies/session reuse, public `/engine`
web APIs, native iOS source UI, deletion/erasure/pruning, automatic TTL cleanup,
settings/profile fields, database migrations, and network-enabled jobs.

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
