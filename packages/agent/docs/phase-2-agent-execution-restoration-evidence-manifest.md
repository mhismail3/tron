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

### Slice 8D Accepted Evidence: Web Source Retention And Cache Policy Foundation

Implementation branch:
`codex/phase-2-slice-8d-web-source-retention-cache-policy`.
Baseline:
`origin/main@8ed8db55500f3a05aef55a1e2ec39acba30a8c07`
(`docs: accept phase 2 slice 8c`).
Accepted implementation commit:
`3a9d4f35674b166528d7e15aea0e17802d634cea`
(`feat: add web source archive lifecycle`).
Implementation thread:
`019efbbd-f745-7752-8cd8-fdd86194d138`.
Independent review thread:
`019efbd4-b199-71c2-b56d-4d8c7aa02976`.
Status:
`accepted`.

Accepted evidence:

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

Independent review found no findings and returned `slice accepted`. Review
validation passed `cargo fmt`, `cargo check`, focused `domains::web`,
`domains::capability`, OpenAI message-converter tests, HRA/TMB/TPC/PCC/SACB/
BPRC/IARM/DESI/public-protocol static guards, `scripts/personal-info-guard.sh`,
`git diff --check`, and ignored-file audit.

Accepted non-goals remain deferred: search providers, browser automation,
crawling, robots/sitemap policy, login/cookies/session reuse, public `/engine`
web APIs, native iOS source UI, deletion/erasure/pruning, automatic TTL cleanup,
settings/profile fields, database migrations, and network-enabled jobs.

### Slice 8E Accepted Evidence: Web Robots Policy Foundation

Implementation branch:
`codex/phase-2-slice-8e-web-robots-policy`.
Accepted fix branch:
`codex/phase-2-slice-8e-web-robots-policy-fix2`.
Baseline:
`origin/main@9a74084d9ce8b241d8fdf4a7865a683bd04e652c`
(`docs: accept phase 2 slice 8d`).
Discovery thread:
`019efbe3-8098-7372-9c03-e3ef645badb3`.
Implementation thread:
`019efbe9-ea1a-7e73-93a9-5c2ddcf67e76`.
Review/fix loop:
`019efc06-2c7d-76b2-a773-8cbcf0a2ca8a`,
`019efc0a-d75e-7032-810f-f81f0f5ed15b`,
`019efc18-7248-7ad3-9f38-647283af6f0f`,
`019efc1e-0ce8-79a1-a89a-d028333b7e9a`, and
`019efc26-2fca-7dc3-abf2-c8d1dbab81b5`.
Status:
`accepted`.

Accepted evidence:

- Adds `packages/agent/src/domains/web/robots/mod.rs` as the web-owned
  execute-only robots policy check module.
- Adds `web_robots_check` behind `capability::execute` and wires
  least-privilege grant derivation plus engine authorization for
  `networkPolicy: declared`, `web.write`, `resource.read`,
  `resource.write`, and `web_robots_policy`.
- Adds built-in `web_robots_policy` resource definitions for bounded
  append-only robots evidence.
- Reuses the existing web URL, redirect, and DNS-resolved socket safety policy
  before target network I/O.
- Requires HTTPS in production for robots network fetches while preserving an
  explicit test-only HTTP loopback fixture flag.
- Requires `resource.read` before reading or replaying scoped
  `web_robots_policy` cache/evidence and `resource.write` before writing new
  evidence.
- Records origin, robots URL, fetched-at time, status, captured-byte SHA-256,
  bounded body metadata, parser id/version, matched user-agent, allow/deny
  decision, relevant matched rule, sitemap refs as metadata only, authority
  refs, trace/replay refs, and idempotency/cache refs.
- Keeps sitemap traversal, search, crawl, browser, login/cookies, public
  `/engine` web APIs, native iOS source UI, deletion/pruning/TTL cleanup,
  settings/profile fields, database migrations, and network-enabled jobs out
  of scope.

Review findings and fixes:

- Initial review required production HTTP loopback rejection for
  `web_robots_check` and a split below the TPC 750-line hard file budget.
  Fix commit `b0352fbb79f30b267d8725deaf3fc2e234ec5998` addressed both.
- First re-review required `resource.read` authority for robots policy
  cache/evidence reads. Fix commit
  `21d3d24a7f757b43d3f51599fe35a14e7f0f3633` added runtime grant derivation,
  engine authorization, direct grant inspection, docs/static coverage, and a
  missing-`resource.read` no-network-I/O regression.
- Final re-review returned `slice accepted` with no findings and marked
  `codex/phase-2-slice-8e-web-robots-policy-fix2@21d3d24a7f757b43d3f51599fe35a14e7f0f3633`
  suitable for mainline integration after closeout docs.

Accepted validation recorded on branch and re-review:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `cargo check --manifest-path packages/agent/Cargo.toml`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::web -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`
- HRA, TMB, TPC, PCC, SACB, BPRC, IARM, DESI, and public-protocol invariant
  suites.
- `scripts/personal-info-guard.sh`
- `git diff --check 9a74084d9ce8b241d8fdf4a7865a683bd04e652c..21d3d24a7f757b43d3f51599fe35a14e7f0f3633`
- `git ls-files -ci --exclude-standard`

### Slice 8F Accepted Evidence: Web Fetch Robots Evidence Linkage Foundation

Implementation branch:
`codex/phase-2-slice-8f-web-fetch-robots-evidence-linkage`; accepted fixed
branch `codex/phase-2-slice-8f-web-fetch-robots-evidence-linkage-fix1`.
Baseline:
`origin/main@419433985790f35f5ef514e9f508b4f8906d37a1`
(`docs: accept phase 2 slice 8e`).
Source handoff thread:
`019ef914-ed80-78f2-b253-229240d49444`.
Discovery thread:
`019efc32-30b1-7811-9959-7e539ba8062f`.
Implementation thread:
`019efc38-4532-7d02-97d2-67149b834f76`.
Implementation worktree:
`/Users/<USER>/.codex/worktrees/07b9/tron`.
First review thread:
`019efc5c-dead-76c0-8cb3-496dba956a06`.
Focused fix thread:
`019efc66-358e-7571-8508-6e691c663e49`.
Accepting re-review thread:
`019efc78-a769-76a0-97fe-e75601b0955a`.
Status:
`accepted`.
Accepted commits:
`c01924ba634b64ec0bdb6033bd53dc304b5a94fc` and
`cb30347b29d7e11d8e0e4210068ee67e6cabd9f0`.

Accepted evidence:

- Adds `packages/agent/src/domains/web/robots_link.rs` as the fetch-side
  validation boundary for optional robots-policy evidence refs.
- Extends `web_fetch` under the existing `capability::execute` primitive with
  optional paired inputs `webRobotsPolicyResourceId` and
  `expectedWebRobotsPolicyVersionId`.
- Validates referenced current-session `web_robots_policy` resources before
  target HTTP client construction or target network I/O when the pair is
  supplied.
- Requires current kind/schema, current session scope, current expected
  version, checked resource/payload state, matching origin, matching target URL,
  and `policy.decision == "allow"`.
- Uses a non-displayed canonical target URL fingerprint to enforce exact target
  identity when visible target URLs are sanitized, including sensitive query
  parameter values.
- Persists only bounded `robotsPolicyRefs` into `web_source` payloads and
  exposes those refs through `web_source_list` and `web_source_inspect` without
  robots body previews, body evidence, or sitemap content.
- Updates runtime grant derivation and central engine authorization so
  robots-linked `web_fetch` gets `web.read`, `resource.read`, and
  `kind:web_robots_policy` authority only when both robots evidence fields are
  non-empty strings.
- Preserves default non-robots `web_fetch` compatibility.

Deferred scope remains explicit: no search providers, browser automation,
crawling, sitemap traversal/fetching, login/cookies/session reuse, public
`/engine` web APIs, native iOS source UI, settings/profile changes, database
migrations, deletion/pruning/TTL cleanup, network jobs, or global robots
requirement.

Review and validation evidence:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  exited 0.
- `cargo check --manifest-path packages/agent/Cargo.toml` exited 0 with
  pre-existing dead-code warnings in provider and engine helper code.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::web -- --nocapture`
  exited 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`
  exited 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`
  exited 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::agent::r#loop::capability_invocation_executor -- --nocapture`
  exited 0.
- HRA, TMB, TPC, PCC, SACB, BPRC, IARM, DESI, and public-protocol invariant
  suites exited 0.
- `scripts/personal-info-guard.sh` exited 0.
- `git diff --check` exited 0.
- `git diff --cached --check` exited 0.
- `git ls-files -ci --exclude-standard` exited 0 and reported no tracked
  ignored files.
- Initial independent review thread `019efc5c-dead-76c0-8cb3-496dba956a06`
  returned `changes required`: sanitized target URL comparison could authorize
  a different sensitive query value, and explicit JSON null robots fields could
  broaden ordinary fetch grants.
- Focused fix thread `019efc66-358e-7571-8508-6e691c663e49` committed
  `cb30347b29d7e11d8e0e4210068ee67e6cabd9f0`, adding exact target fingerprint
  validation, nullable optional schema handling, parser-aligned grant/authority
  detection, and deterministic regressions for both findings.
- Accepting re-review thread `019efc78-a769-76a0-97fe-e75601b0955a` returned
  `slice accepted` with no findings. Re-review validation passed format,
  `cargo check`, focused `domains::web`, capability invocation executor,
  `domains::capability`, OpenAI message converter tests, HRA/TMB/TPC/PCC/SACB/
  BPRC/IARM/DESI/public-protocol static gates, personal-info guard,
  `git diff --check 419433985790f35f5ef514e9f508b4f8906d37a1..cb30347b29d7e11d8e0e4210068ee67e6cabd9f0`,
  and ignored-file scan.

Slice 9A implementation evidence:

Accepted status: current baseline after independent review/fix loops and
mainline integration. Final accepted branch head:
`2c472ed7ded121e1e2210156d89526b70e28ad65`
(`fix: complete tool source static inventories`).

Threads and commits:

- Discovery thread `019efc87-5b5f-7cd0-82c8-9491b6266377` selected Slice 9A
  from baseline `6b3512a4280e0f1c43b3e7bfad813fe86f0ce8c4` with no docs
  changes and verdict `implementation may start`.
- Implementation thread `019efc8e-09dc-7b61-9b63-1a7df6fbe99a`, worktree
  `/Users/<USER>/.codex/worktrees/0f97/tron`, committed
  `2bd51fcf38d68720ee4ed25937b393b8450ecbe0`
  (`feat: add tool source proposal provenance`).
- Initial review thread `019efca9-05e9-7b43-8c88-3396f57dd791` returned
  `changes required` for missing `tool_source_conformance_report`
  resource-kind authority, string-valued activation/registration intent, and
  premature docs acceptance wording. Stopped fix thread
  `019efcb2-2ced-7ae0-8554-227d5b40fe0c` returned no actionable blocker and
  was replaced.
- Replacement fix thread `019efcb6-9530-7dc1-b515-789ab8e656a1`, worktree
  `/Users/<USER>/.codex/worktrees/e30d/tron`, committed
  `788b105980b59d73b5e0c05eb682c81b669827ad`
  (`fix: tighten tool source report provenance guards`).
- Re-review thread `019efcc2-007f-79c1-87f8-a9200369f79f` returned
  `changes required` for inspect trusting resource id prefix over stored
  kind/schema, passive/noun activation intent gaps, and stale evidence counts.
- Focused fix thread `019efcca-8dcc-70c1-b401-4af360bbab38`, worktree
  `/Users/<USER>/.codex/worktrees/44c9/tron`, committed
  `8fcb3051dc0359e558ffac9dfe77f525709f1c92`
  (`fix: harden tool source provenance checks`).
- Re-review thread `019efce1-b995-70e1-95a2-2de9644d7e2e` returned
  `changes required` for missing static inventory rows for the split inspect
  and validation test files plus premature README baseline wording.
- Focused fix thread `019efcea-c8e6-7a70-ae89-d96942d4aaa0`, worktree
  `/Users/<USER>/.codex/worktrees/b8fd/tron`, committed
  `2c472ed7ded121e1e2210156d89526b70e28ad65`
  (`fix: complete tool source static inventories`).
- Accepting re-review thread `019efcf5-050b-7320-b9ce-d4b248f4c61d`, worktree
  `/Users/<USER>/.codex/worktrees/c2b1/tron`, returned `slice accepted` with
  no findings.

Accepted scope:

- Adds `domains/tool_sources` as an inert proposal/provenance boundary with
  internal trusted-only `tool_source_proposal` and
  `tool_source_conformance_report` resource creation.
- Adds read-only `capability::execute` operations `tool_source_list` and
  `tool_source_inspect`; no provider-visible proposal, install, launch,
  registration, MCP start/restart, catalog registration, trust promotion, or
  tool execution operation is introduced.
- Adds built-in resource definitions for `tool_source_proposal` and
  `tool_source_conformance_report` with required source identity, provenance,
  sandbox policy, declared metadata, authority, trace/replay/evidence refs,
  idempotency, and revision fields.
- Requires trusted internal system/admin authority, derived non-bootstrap
  grants, explicit non-wildcard resource-kind grants, idempotency, and
  `networkPolicy: none` before proposal/report creation.
- Rejects inline secrets, credential-looking values, unsafe paths, unbounded
  schemas, wildcard sandbox authority, command/env execution fields, and active,
  passive, or noun-form activation/registration intent while preserving
  explicit inert prohibition prose.
- Revalidates stored resource kind/schema during inspect and conformance report
  linkage rather than trusting resource id prefixes.
- Covers split `tool_sources` test files in SACB, HRA file inventory, HRA
  current ownership, TPC TSV/count summary, and PCC inventories.

Deferred scope remains explicit: no MCP process start/restart/enable/disable,
package install/update/uninstall, catalog registration, proposed-tool
execution, provider-visible self-proposal, public `/engine` expansion,
browser/search/crawl/login scope, network-enabled jobs, native iOS fixed UI, or
grant broadening beyond existing `capability::execute`.

Review and validation evidence:

- Implementation validation passed `cargo fmt --manifest-path
  packages/agent/Cargo.toml --all -- --check`, `cargo check --manifest-path
  packages/agent/Cargo.toml`, focused `cargo test --manifest-path
  packages/agent/Cargo.toml tool_sources -- --nocapture` with 13 tests before
  later regression additions, SACB/HRA/TMB/TPC/PCC/BPRC/IARM/DESI/SUWRF/
  public-protocol/PPRC static gates, personal-info guard, diff whitespace
  checks, and ignored-file audit.
- Fix2 validation passed focused `tool_sources` tests plus relevant
  static/docs gates after conformance-report authority and string activation
  intent hardening.
- Fix3 validation passed `cargo fmt`, `cargo check`, focused
  `tool_sources` tests with 16 tests, SACB/HRA/TMB/TPC/PCC/BPRC/IARM/DESI/
  SUWRF/public-protocol/PPRC gates, personal-info guard, diff checks, and
  ignored-file audit.
- Fix4 validation passed SACB/HRA/TPC/PCC and overlap TMB/BPRC/IARM/DESI/
  SUWRF/public-protocol/performance-resource gates, personal-info guard,
  diff whitespace checks, cached diff check, and ignored-file audit. Rust
  format/tests were skipped for fix4 because it changed only docs/static
  inventories.
- Accepting re-review validation passed
  `cargo test --manifest-path packages/agent/Cargo.toml tool_sources -- --nocapture`
  with 16 tests, SACB/HRA/TPC/PCC, TMB/BPRC/IARM/DESI/SUWRF/public-protocol/
  performance-resource governance gates, personal-info guard,
  `git diff --check 6b3512a4280e0f1c43b3e7bfad813fe86f0ce8c4..HEAD`,
  plain `git diff --check`, and ignored-file audit.

Slice 9B accepted evidence:

- Discovery thread `019efd04-598f-7232-a24e-5ba85f0d4d56` selected Worker
  Package Lifecycle Inspection Foundation from
  `origin/main@8ad68584b546b17db06ca256a12e7a9d905e3320` with no discovery
  docs changes.
- Implementation thread `019efd0b-3461-79c0-8d28-7a11fdcb9703` produced
  `codex/phase-2-slice-9b-worker-package-lifecycle-inspection` at
  `ce56ff609948d0d31dbd76e74a30a87a027738d3`, adding read-only
  `capability::execute` operation values `worker_package_list` and
  `worker_package_inspect`; no provider-visible proposal, install, enable,
  disable, launch, stop, retire, MCP start/restart, package install/update/
  uninstall, catalog registration, proposed-tool execution, trust promotion,
  public `/engine` expansion, browser/search/crawl/login scope, settings,
  migrations, or native fixed UI is added.
- Initial review thread `019efd21-89f2-7951-9efe-242402f9604d` returned
  `changes required` for missing provider runtime grants, selector-wildcard
  acceptance, archived proposal/conformance exposure, inspection module TPC
  budget overflow, and direct installation `authorityGrantId` leakage.
- Focused fix thread `019efd2a-de81-7b02-9605-32d93153b9a9` produced
  `7c794417c1b5b6490324fa6e1062580b73f339a8`, adding exact read grant
  derivation, selector-wildcard denial, archived record exclusion/denial, the
  HRA/TPC-compliant inspection module split, and top-level authority-grant
  omission.
- Re-review thread `019efd3e-7bac-7ec1-b67e-2c22d60f2886` returned
  `changes required` for arbitrary metadata grant-id leakage through shared
  provider-visible projections.
- Focused fix thread `019efd4b-0240-7a41-a401-701346bee279` produced
  `cd97c2f87afa3e961258eedf37a227926e496720`, redacting `authorityGrantId`,
  `authority_grant_id`, `grantId`, `grant_id`, nested grant-id key variants,
  and obvious grant-id string values across provenance, failure, trace, and
  replay metadata while preserving non-sensitive lifecycle status text.
- Accepting re-review thread `019efd54-5da3-7842-bf6e-6e66a1d83472` returned
  `slice accepted` with no findings. Validation passed: `cargo fmt
  --manifest-path packages/agent/Cargo.toml --all -- --check`, `cargo check
  --manifest-path packages/agent/Cargo.toml`, `cargo test --manifest-path
  packages/agent/Cargo.toml worker_package -- --nocapture`, `cargo test
  --manifest-path packages/agent/Cargo.toml
  execute_schema_exposes_primitive_operations_not_catalog_targets --
  --nocapture`, SACB/HRA/TMB/TPC/PCC/BPRC/IARM/SUWRF/PMBD/DESI/
  public-protocol/performance-resource gates, `scripts/personal-info-guard.sh`,
  `git diff --check
  8ad68584b546b17db06ca256a12e7a9d905e3320..cd97c2f87afa3e961258eedf37a227926e496720`,
  `git ls-files -ci --exclude-standard`, and clean status.

Slice 10A accepted evidence:

- Delegation source thread `019ef914-ed80-78f2-b253-229240d49444`
  and discovery thread `019efd62-d8e2-73a0-8d94-e217a86248ef`
  selected Subagent Task Lifecycle Foundation from
  `origin/main@de8bac83d7508c0dc99a929e095a3c2240d89910`.
- Implementation branch
  `codex/phase-2-slice-10a-subagent-task-lifecycle-foundation` at
  `5d8216085006973c02349ecef3604124a87bf3e3` adds an inert `subagents`
  domain, built-in `subagent_task` resource definition, trusted/internal-only
  Rust service functions for bounded lifecycle create/update, and read-only
  `capability::execute` operation values `subagent_task_list` and
  `subagent_task_inspect`.
- Lifecycle records persist bounded task id, parent session/workspace/trace
  refs, objective/prompt summaries, evidence/output refs, timestamps as audit
  metadata, optional result/error placeholders, explicit activation proof,
  and `networkPolicy: none` evidence. Raw prompts, secrets, process metadata,
  endpoints, env values, worker tokens, and nested launch/tool metadata are
  rejected or absent from the stored record shape.
- Read projections require trusted current-session context, derived
  non-bootstrap read grants, explicit `subagents.read` and `resource.read`,
  explicit `subagent_task` resource-kind authority, matching
  `kind:subagent_task` selectors, stored kind/schema revalidation, scope
  isolation, allowlisted bounded/redacted projection independent of stored
  payload trust, and `networkPolicy: none`.
- Focused review-fix branch
  `codex/phase-2-slice-10a-subagent-task-lifecycle-foundation-fix1` at
  `a7ed577ece4e8a1bb26dc655e818a3c256fa4933` hardens list/inspect projections
  with `domains/subagents/projection.rs` and aligns OpenAI provider guidance
  with only the read-only `subagent_task_list` and `subagent_task_inspect`
  operations.
- Second focused fix branch
  `codex/phase-2-slice-10a-subagent-task-lifecycle-foundation-fix2` at
  `93ad5383dd2b4d21cffe05117bdde736d01a0c99` adds minimal read-only runtime
  grant derivation and pre-handler authorization for `subagent_task_list` and
  `subagent_task_inspect`, rejects wildcard/broad selectors even when mixed
  with `kind:subagent_task`, and adds SACB inventory coverage for
  `domains/subagents/projection.rs`.
- Slice 10A does not spawn child agents, launch workers/packages, start jobs or
  processes, execute tools, register catalog entries, perform network/browser/
  search/login work, schedule work, cancel real workers, merge results into
  conversation state, add public `/engine` APIs, change settings/profile
  schemas, add migrations, or add fixed native iOS subagent UI.
- Initial review thread `019efd86-5fda-7700-b3a5-2da50f144454` returned
  `changes required` for raw stored-payload projection leakage and missing
  provider prompt/schema exposure for read-only subagent task list/inspect.
- Re-review thread `019efdae-6377-7b91-834e-f325c77e1cd2` returned
  `changes required` for missing provider runtime grant/pre-handler
  authorization, broad selector acceptance, and missing SACB projection
  inventory coverage.
- Accepting re-review thread `019efdc9-fdf2-7172-8bf3-5dffe414ed9e` returned
  `slice accepted` with no findings for fixed head
  `93ad5383dd2b4d21cffe05117bdde736d01a0c99`.
- Focused validation passed `cargo fmt --manifest-path packages/agent/Cargo.toml
  --all -- --check` and `cargo test --manifest-path packages/agent/Cargo.toml
  subagent -- --nocapture` with 16 focused tests covering creation/update,
  runtime grant derivation, pre-handler authorization, authority denial,
  idempotency, scope isolation, selector denial, stored kind/schema mismatch
  rejection, malformed stored-payload projection redaction/bounding,
  bounded/redacted validation, resource definition fields, and static
  no-launch/no-registration/no-network guards.
- Final implementation validation also passed `cargo check --manifest-path
  packages/agent/Cargo.toml`, `scripts/personal-info-guard.sh`, `git diff
  --check`, `git ls-files -ci --exclude-standard`, and the relevant HRA, SACB,
  TMB, TPC, PCC, BPRC, IARM, DESI, SUWRF, PMBD, public-protocol, and
  performance-resource static gates.
- The DRC invariant target was run and failed only on the pre-existing
  `goals`, `web`, and `tool_sources` UTC allow-list gap observed at the Slice
  9B baseline. The failure list did not include `domains/subagents`; Slice 10A
  documents its audit-timestamp ownership without widening the deferred DRC
  cleanup scope.

## Phase 2 Slice 10B Accepted Evidence: Subagent Worker Launch Foundation

Slice 10B accepted evidence:

- Delegation source thread `019ef914-ed80-78f2-b253-229240d49444` and
  discovery thread `019efddb-9995-71f3-8e44-175d81b87adc` selected Subagent
  Worker Launch Foundation from
  `origin/main@414cb54119453afbdaf496c7063fcea7dd8e694f`.
- Implementation branch
  `codex/phase-2-slice-10b-subagent-worker-launch-foundation` in worktree
  `/Users/<USER>/.codex/worktrees/03e5/tron` adds controlled
  `subagent_launch`, `subagent_status`, `subagent_result`, and
  `subagent_cancel` provider-visible operation values behind the existing
  `capability::execute` primitive.
- The implementation keeps `subagent_task` as the durable parent task and
  causality anchor. Launch requires trusted current-session/workspace context,
  exact `kind:subagent_task` selectors, explicit `subagents.read`,
  `subagents.write`, `resource.read`, and `resource.write` authority,
  idempotency, `modelPolicy: bounded_placeholder_v1`, parent
  session/workspace/trace refs, bounded objective/prompt summaries, one
  running task per session/workspace scope, no-network policy, and stored
  proof that no worker/job/process/tool/package/network/result-merge side
  effects occurred.
- Status/result use allowlisted bounded/redacted projections with trace,
  replay, resource, model-policy, concurrency, worker/job/process, and
  side-effect proof refs rather than trusting arbitrary stored payload fields.
  Cancel records idempotent cancellation provenance and optional
  expected-version freshness while remaining a resource-state transition only.
- Runtime grant derivation, pre-handler authorization, OpenAI provider
  guidance, provider schema operation exposure, and resource schema coverage
  were updated only for the intended lifecycle operation names. Provider/static
  guards continue to reject broad delegation/spawn, arbitrary tool execution,
  package install/launch, MCP start, public `/engine`, browser/search/login,
  and network scope.
- Focused validation passed `cargo test --manifest-path
  packages/agent/Cargo.toml --lib domains::subagents -- --nocapture` with 19
  tests, `cargo test --manifest-path packages/agent/Cargo.toml --lib
  domains::capability::contract -- --nocapture`, `cargo test --manifest-path
  packages/agent/Cargo.toml --lib
  domains::model::providers::openai::message_converter -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml --lib
  subagent_launch_and_cancel_runtime_grants_are_scoped_writes -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml --lib
  subagent_status_and_result_runtime_grants_are_read_only -- --nocapture`, and
  `cargo test --manifest-path packages/agent/Cargo.toml --lib
  unsupported_subagent_task_operation_does_not_gain_lifecycle_authority --
  --nocapture`.
- Static validation passed `cargo fmt --manifest-path
  packages/agent/Cargo.toml --all -- --check`, `cargo check --manifest-path
  packages/agent/Cargo.toml`, SACB, CSD, HRA, TMB, TPC, PCC, BPRC, DESI,
  public-protocol, performance-resource, and PMBD invariant targets.
- The DRC invariant target was run and failed only on the known non-subagents
  UTC allow-list gap in `goals`, `web`, and `tool_sources`. The failure list
  did not include `domains/subagents`.
- Implementation commit
  `81421e7209f1b4316e3dd8a5f29415660b94f755` and HRA ownership-map fix
  commit `cd7b5f6cde3e6521470e256d49aa9bfe65c94102` were accepted for
  mainline integration after independent review.
- Initial review thread `019efdf9-2a2a-7d73-a132-a0b8524e7645` in worktree
  `/Users/<USER>/.codex/worktrees/76d3/tron` returned `changes required`
  solely for missing HRA current-ownership-map rows for
  `packages/agent/src/domains/subagents/execution.rs` and
  `packages/agent/src/domains/subagents/execution_tests.rs`.
- Focused fix thread `019efdfd-752c-7081-88b3-3b3e2fad1d26` in worktree
  `/Users/<USER>/.codex/worktrees/6069/tron` added the two ownership-map rows
  on branch `codex/phase-2-slice-10b-subagent-worker-launch-foundation-fix1`.
  Its validation passed HRA invariants, TSV column-count check,
  personal-info guard, diff checks, cached diff check, and ignored-file audit.
- Accepting re-review thread `019efe06-d899-7ee2-83a4-695d9255e18e` verified
  fixed branch
  `codex/phase-2-slice-10b-subagent-worker-launch-foundation-fix1` at
  `cd7b5f6cde3e6521470e256d49aa9bfe65c94102` descends from both the
  implementation head and baseline. It found no findings and returned exact
  verdict `slice accepted`.
- Accepting re-review validation passed `cargo fmt --manifest-path
  packages/agent/Cargo.toml --all -- --check`, `cargo check --manifest-path
  packages/agent/Cargo.toml`, HRA invariants, `cargo test --manifest-path
  packages/agent/Cargo.toml subagent -- --nocapture` with 25 focused tests,
  runtime grant, capability schema, OpenAI provider instruction tests, SACB,
  CSD, HRA, TMB, TPC, PCC, BPRC, DESI, public-protocol, performance-resource,
  personal-info guard, `git diff --check`, and ignored-file audit. DRC failed
  only on the known non-subagents UTC allow-list gap in `goals`, `web`, and
  `tool_sources`; no `subagents` path was listed.
- Real child-agent execution, actual worker/package/job/process start, tool
  execution, scheduler/autonomy, cancellation signalling to workers, result
  merge into conversation state, model-profile policy, approval triggers,
  public `/engine`, settings/profile/migrations, network/browser/search/login,
  catalog registration, trust promotion, and native fixed subagent UI remain
  deferred.

## Accepted Slice 11A: Procedural State Provenance And Inspection Foundation

- Branch
  `codex/phase-2-slice-11a-procedural-state-provenance-foundation` in worktree
  `/Users/<USER>/.codex/worktrees/e852/tron` starts from
  `origin/main@85579a78da54113321cb32de9eb90dd8cd330aef`.
- Focused review fix branch
  `codex/phase-2-slice-11a-procedural-state-provenance-foundation-fix1` in
  `/Users/<USER>/Workspace/tron` addresses review worker
  `019efe48-be03-7cd1-8798-fad9ad24f0fb` by revalidating provider-visible
  `eval.status`, `eval.lastRunAt`, and payload `contentHash` before list or
  inspect projection.
- Accepted status: current baseline after implementation thread
  `019efe1d-353a-7310-a4b6-8bc5af2c940b`, review worker
  `019efe48-be03-7cd1-8798-fad9ad24f0fb`, focused fix worker
  `019efe4e-eb18-7c53-ad66-cb0db70c62de`, and accepting re-review worker
  `019efe62-2db7-7a43-aee3-223307edfa43`. Accepted commits are
  `621e1bf2b3e95af4ed44a133f789bdbd908c1d41` and
  `4e56ef5b62dd873bacb21ba5b625df559bd71844`.
- Adds a built-in `procedural_record` resource schema for inert skill, rule,
  hook, and procedure provenance/eval/status metadata. The schema is resource
  custody only; it declares read/write authority and redaction/materialization
  policy but does not register triggers, activation, prompt context, learned
  behavior, tool execution, worker/package/job/process launch, or scheduler
  behavior.
- Adds read-only `procedural_state_list` and `procedural_state_inspect`
  operation values behind the existing `capability::execute` primitive.
  Operations require trusted current-session/workspace context, exact agent
  actor/session binding or system actor, `procedural.read`, `resource.read`,
  explicit non-wildcard `procedural_record` resource-kind authority, exact
  `kind:procedural_record` and `proceduralKind:*` selectors, and
  `networkPolicy: none`.
- Projection revalidates stored resource kind, schema id, payload
  `schemaVersion`, payload `proceduralKind`, current-version availability,
  scope, lifecycle/status, bounded selector values, provider-visible eval
  scalar fields, and payload `contentHash` before emitting evidence. It returns
  allowlisted summaries/details with truncation metadata and redacts secrets,
  env values, grant ids, unsafe paths, endpoints, raw manifests/logs, raw
  nested failures/provenance blobs, and private implementation details.
- Runtime grant derivation and pre-handler authorization were extended only for
  the two read-only procedural state operations. Provider guidance names only
  those read operations and explicitly excludes create/update/delete/activate,
  trigger firing, package install, execution, self-modification, autonomous
  behavior, and prompt injection.
- Regression tests cover list/inspect success and denial for missing grants,
  wildcard/broad authority, wrong session/workspace/scope, missing workspace,
  bad actor, wrong stored kind/schema/version, stale/archived/unsupported
  states, malformed payloads, bounded/truncated output, redaction of
  secret/grant/env/path/raw metadata, and rejection without echoing of
  malicious nonscalar, oversized, grant-like, secret-like, and path-like values
  in `eval.status`, `eval.lastRunAt`, and `contentHash`. Additional tests prove
  `packages/agent/skills/` and skill-copy/bootstrap prompt wiring remain
  absent.
- Validation completed before commit: `cargo fmt --manifest-path
  packages/agent/Cargo.toml --all -- --check`, `cargo check --manifest-path
  packages/agent/Cargo.toml`, focused procedural tests, runtime-grant and
  provider-guidance tests, SACB, HRA, TMB, TPC, PCC, BPRC, SSARR, DESI,
  public-protocol, performance-resource, and CSD static gates all passed.
  `scripts/personal-info-guard.sh`, `git diff --check`,
  `git diff --cached --check`, and `git ls-files -ci --exclude-standard` were
  clean. DRC was run for regression context and still fails only on the known
  non-procedural UTC allow-list gap in goals, web, and tool-source tests; the
  failure list contains no procedural files.
- Deferred scope: actual skill/rule/hook/procedure activation, trigger
  registration/firing, prompt inclusion, learned behavior, autonomous
  execution, scheduler work, tool execution, worker/package/job/process/network
  launch, MCP lifecycle, package install/catalog registration, trust promotion,
  public `/engine` APIs, settings/profile migrations, browser/search/crawl/
  login scope, native fixed procedural UI, result merge into conversation
  state and disable/edit/delete behavior.

## Accepted Slice 12: Scheduling, Reminders, Automations, And Background Work

Branch:
`codex/phase-2-slice-12-scheduling-reminders-automations-background-work-fix1`

Baseline HEAD:
`20f24624913e1b9a8ffe9c4ecdf3a0180a5918e5`

Accepted status: current baseline after implementation worker
`019efe6e-e218-7910-889b-3e50c5387639`, review worker
`019efea0-8930-76a1-9e6a-70da59bf1199`, focused fix worker
`019efea4-166a-7661-bbe9-1d739bfe6aa2`, and accepting re-review worker
`019efeb3-38be-76d3-af75-f8c520923a94`. Accepted commits are
`2ae31c48e0ba8246e61bf6b2b63ed67cd7de88ee` and
`7e5a3a85d21eecef7ea3fa1b73bbdcae0c111c88`.

Scope implemented:

- Added `domains/scheduler` as the owner for durable scheduling records,
  missed-run policy, explicit due evaluation, cancellation, retention, and
  bounded list/inspect projections.
- Added built-in `schedule` and `schedule_run` resource schemas with lifecycle
  states, authority requirements, retention/redaction rules, and run-record
  link relations.
- Added `schedule_create`, `schedule_list`, `schedule_inspect`,
  `schedule_cancel`, and `schedule_fire_due` operation values behind the
  existing single `capability::execute` primitive.
- Required trusted current-session/workspace context, explicit
  `scheduler.read`/`scheduler.write`/`scheduler.fire` scopes as appropriate,
  idempotency for writes/fire, explicit `evaluationAt` for provider-visible
  fire-due evaluation, bounded non-wildcard target resource kind/action/selectors,
  and resource leases while mutating due schedules.
- Added deterministic `Clock` injection for fire-due evaluation and focused
  tests for catch-up firing, missed-run skip evidence, cancellation terminality,
  missing authority, wildcard target rejection, and resource schema
  registration.
- Focused review fix hardened inspect projection redaction, bounded
  fire/inspect scans before provider-visible collection, fail-closed
  no-context scheduler service calls, and BPRC/README pending-review wording
  before acceptance.
- Kept Slice 12 narrow: no hidden cron tables, no uncontrolled background loop,
  no feature-work execution, no process/worker/network launch, no APNs/device
  notification delivery, no public scheduler API expansion, no native fixed iOS
  UI, no autonomous planning, and no result merge into conversation state.

### Accepted Slice 13: Notifications, APNs, Device Broker, And Inbox

Accepted branch:
`codex/phase-2-slice-13-notifications-apns-device-broker-inbox-fix5`.

Baseline HEAD:
`ffb83eb28f5172e4d6ff83ae094f1876f3251e74`

Accepted status: current baseline after discovery worker
`019efec3-9be4-7961-a73a-8b7bbfadc85f`, implementation worker
`019efec8-4361-7673-a1aa-3bd5a07cf045`, review worker
`019eff0f-4720-73c1-a116-861f0c173f87`, focused fix workers
`019eff15-cba9-7131-b9a3-7630a0f01429`,
`019eff2a-a552-73d0-bd03-0e661c4b37c9`,
`019eff3f-9ccb-74f3-bb01-68e666ee777f`,
`019eff50-2696-7bd0-b46c-ff7f7b0e48af`, and
`019eff60-829b-7e70-9e6c-776a05ef2657`, plus accepting re-review worker
`019eff66-5f54-7b02-83a5-83cda0fe6f45`. Accepted commits are
`0b4896da73e8c026e6efbbd8ffd2cc25d444dc5e`,
`e5eedd8058c0ccd14842520b8e314c3c0433bf7a`,
`47ff7c214b3dcc058eeaf7be5d2c2c7fbeeeb102`,
`e84723a86880bc461e5238ac54ddd3c69d491e5e`,
`7197d05732ab27e878b589609cedd9cd731b998e`, and
`1c09fa2f0a4ed849cd13dfc9e1d8694af0ecad44`.

Scope implemented:

- Added `domains/device` as the server owner for durable
  `device_registration` records, explicit APNs environment policy, hash-only
  token custody, opt-in push policy, retention defaults, redacted projections,
  and `device.lifecycle` stream evidence.
- Added `domains/notifications` as the server owner for durable
  `notification` and `notification_delivery` records: inbox/read-state data,
  unread-count badge semantics, delivery evidence, source/replay refs,
  retention defaults, and `notifications.lifecycle` stream evidence.
- Added built-in resource definitions for `device_registration`,
  `notification`, and `notification_delivery`.
- Added execute-only operation values `device_register`, `device_unregister`,
  `device_list`, `device_inspect`, `notification_send`, `notification_list`,
  `notification_inspect`, `notification_mark_read`, and
  `notification_mark_all_read` behind the existing single
  `capability::execute` primitive.
- Required trusted current-session/workspace context, explicit non-wildcard
  resource-kind selectors, bounded selectors, derived non-bootstrap grants,
  idempotency for writes, and push-requested sends gaining only
  `device.read`/`device_registration` authority in addition to notification
  resource authority.
- Kept Slice 13 narrow: live APNs transport disabled, no APNs entitlement, no
  native iOS inbox/deep link, no public notification API, no hidden background
  loop, no fake local inbox, no package install/catalog registration, and no
  production network side effect.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Formatting passed for the notification/device foundation. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Rust crate checked after notification/device/capability/resource wiring; only pre-existing provider/resource dead-code warning classes remained. |
| `cargo test --manifest-path packages/agent/Cargo.toml device::tests -- --nocapture` | exit 0 | 6 device tests passed: register/unregister, APNs token redaction, explicit environment handling, opt-in defaults, authority denial, wildcard denial, list behavior, and scope isolation. |
| `cargo test --manifest-path packages/agent/Cargo.toml notifications::tests -- --nocapture` | exit 0 | 5 notification tests passed: send/list/read/mark-all, badge semantics, retention defaults, trace/replay refs, no-device/policy-disabled/transport-disabled delivery evidence, token redaction, authority denial, push device-read gating, and scope isolation. |
| `cargo test --manifest-path packages/agent/Cargo.toml grant_ -- --nocapture` | exit 0 | 26 grant tests passed, including least-privilege notification/device grants and push-requested device-read gating. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::capability::contract -- --nocapture` | exit 0 | 3 provider schema tests passed after adding notification/device operation values and schemas. |
| `cargo test --manifest-path packages/agent/Cargo.toml clarification_includes_capability_execution_guidance -- --nocapture` | exit 0 | 1 message-converter guidance test passed with the new execute operation families included. |
| `cargo test --manifest-path packages/agent/Cargo.toml clarification_forbids_probe_calls_when_user_supplies_exact_payload -- --nocapture` | exit 0 | 1 provider-behavior guard passed, preserving the no-probe-call policy for exact execute payloads. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants --test ios_affordance_restoration_map_invariants --test security_authority_capability_boundaries_invariants --test hierarchical_rearchitecture_invariants --test true_modularity_boundary_invariants --test true_primitive_cleanup_invariants --test primitive_code_cleanup_invariants --test documentation_evidence_scorecard_integrity_invariants --test concurrency_scheduling_discipline_invariants --test public_protocol_api_contract_discipline_invariants --test performance_resource_governance_invariants --test self_updating_worker_runtime_foundation_invariants -- --nocapture` | exit 0 | BPRC, IARM, SACB, HRA, TMB, TPC, PCC, DESI, CSD, public-protocol, performance-resource, and SUWRF static gates passed with the narrow accepted Slice 13 carve-outs. Closeout re-ran the static gates after acceptance wording, inventory status, and tracker updates. |
| `scripts/personal-info-guard.sh` | exit 0 | No personal-info literals were introduced. |
| `git diff --check` | exit 0 | Closeout docs and static assertion diffs contain no whitespace errors. |
| `git ls-files -ci --exclude-standard` | exit 0 | No ignored files are staged or tracked by the closeout. |
| `git ls-files -oi --exclude-standard \| sed -n '1,120p'` | exit 0 | Ignored untracked audit showed only local build/system artifacts, including `.worktrees/.DS_Store` and `packages/agent/target/...`. |
| `test ! -e packages/agent/skills` | exit 0 | Repo-managed first-party skills remain absent. |
| iOS/APNs validation | not run | No iOS source, entitlement, native inbox, deep-link, or live APNs transport was added in Slice 13; physical-device APNs validation remains deferred with live delivery. |

### Accepted Slice 14A: Media Artifact And Voice Note Resource Foundation

Candidate branch:
`codex/phase-2-slice-14a-media-artifact-voice-note-foundation-fix1`.

Baseline HEAD:
`d756f2ff3dc04c52693801166a99a34574f1fa8d`

Accepted status: implementation thread Mencius
`019eff78-a9f6-7333-9f5f-c33b34ddd8ed` completed
`implementation complete` at implementation commit
`aae9d8d0910338989da0914d9030b6da106411b6`; independent review
Heisenberg `019effa7-3ba1-74b0-a27e-3cc6acb5b77a` returned
`changes required`; focused fix Averroes
`019effaa-4f98-7c73-a27e-6cb1eccfe5f6` completed
`fix ready for review` at
`0792a9ef35352f1a51ea65adb8605cceffa5bce3`; Codex re-review thread
`019effb6-2963-7361-975e-3eb1d776dbb1` returned exact verdict
`slice accepted`.

Scope implemented:

- Added `domains/media` as the server owner for durable `media_artifact`
  records with blob refs, bounded metadata, retention fields, source/evidence
  refs, trace/replay refs, lifecycle evidence, and local transcription metadata.
- Added the built-in `media_artifact` resource definition with blob-ref-only
  materialization, append-only versions, active/archived lifecycle states,
  bounded redaction policy, and explicit media/resource capability requirements.
- Added execute-only operation values `media_create`, `media_list`,
  `media_inspect`, and `media_archive` behind the existing single
  `capability::execute` primitive.
- Required trusted current-session/workspace context, exact non-wildcard
  `media_artifact` resource selectors, `media.read`/`media.write` plus
  resource scopes, idempotency for writes, expected-version freshness for
  archive, and `networkPolicy: none`.
- Kept Slice 14A narrow: no native iOS voice-note UI, no microphone/camera
  permission changes, no live capture validation, no server transcription model
  changes, no public `/engine` media API, no imports/session trees, no update
  diagnostics, and no provider-visible raw audio.

Focused validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Rust formatting passed after the media contract split and TPC inventory summary update. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Agent crate checked successfully; existing provider/resource dead-code warnings remain unrelated to Slice 14A. |
| `cargo test --manifest-path packages/agent/Cargo.toml media_ --lib -- --nocapture` | exit 0 | 6 focused media tests passed after the fix, covering resource schema/lifecycle, deterministic timestamps, retention, list/inspect/archive, lifecycle stream evidence, MIME/size/raw payload rejection, redacted projections, authority selector and network-policy denial, scope isolation, idempotency fingerprint evidence, and raw-key leak regression coverage. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::capability::contract::tests::execute_schema_exposes_primitive_operations_not_catalog_targets -- --nocapture` | exit 0 | Provider schema includes media operation values and fields while preserving the single `capability::execute` surface. |
| `cargo test --manifest-path packages/agent/Cargo.toml clarification_includes_capability_execution_guidance -- --nocapture` | exit 0 | Provider instruction guidance names media operations and raw-audio/base64 rejection boundaries. |
| `cargo test --manifest-path packages/agent/Cargo.toml resource_kernel_builtin_definitions_keep_core_kinds_and_relations -- --nocapture` | exit 0 | Resource kernel definition coverage passed with `media_artifact` registered alongside existing built-in resource kinds. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants --test ios_affordance_restoration_map_invariants --test security_authority_capability_boundaries_invariants --test hierarchical_rearchitecture_invariants --test true_modularity_boundary_invariants --test true_primitive_cleanup_invariants --test primitive_code_cleanup_invariants --test documentation_evidence_scorecard_integrity_invariants --test concurrency_scheduling_discipline_invariants --test public_protocol_api_contract_discipline_invariants --test performance_resource_governance_invariants --test provider_model_boundary_discipline_invariants -- --nocapture` | exit 0 | BPRC, IARM, SACB, HRA, TMB, TPC, PCC, DESI, CSD, public-protocol, performance-resource, and provider-model boundary gates passed after Slice 14A acceptance wording, tracker, inventory, and invariant updates. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | exit 101 | DRC failed only on the known non-media `goals`, `web`, and `tool_sources` direct `Utc::now()` allow-list gap; there were no media file findings, and media paths use injected operation timestamps. |
| `scripts/personal-info-guard.sh` | exit 0 | Full personal-info guard found no source leaks. |
| `git diff --check` | exit 0 | Whitespace check passed. |
| `git ls-files -ci --exclude-standard` | exit 0 | No ignored tracked files were reported. |
| `test ! -e packages/agent/skills` | exit 0 | Repo-managed first-party skills remain absent. |
| iOS/media capture validation | not run | No Swift source, microphone/camera permission, native voice-note UI, capture flow, or physical-device media path changed in Slice 14A. |

### Accepted Slice 14B: Import And Session/Resource Graph Foundation

Accepted branch:
`codex/phase-2-slice-14b-import-session-resource-graph-foundation`.

Baseline HEAD:
`495881c1e4f30604640cf91761515ac9f3a97279`

Accepted commits:
`ae2d44b7e35f73dcec2be7ca6ac72dd9bd3b0be1` and
`e34fb0a9747ff2cfd176fa75499e61b48138cfe6`.

Thread evidence: discovery thread `019effd6-4548-7991-b9ce-cefee80394be`
selected Slice 14B; implementation thread `019effd9-089b-7f41-a035-3ec11620f1ae`
completed exact status `implementation complete`; independent review thread
`019effff-c021-7be2-940b-3843e1ed5d68` returned exact verdict
`changes required` for UTF-8-unsafe projection truncation; focused fix thread
`019f0007-29a4-7c52-8fd2-3417b60a29c6` completed exact status
`fix ready for review`; accepting re-review thread
`019f000b-4d47-7791-81c3-59396ae34ed5` returned exact verdict
`slice accepted`.

Scope accepted:

- Adds `domains/import_history` as the server owner for durable
  `import_history_record` resources containing bounded generic
  session/resource lineage refs, retention metadata, trace/replay refs,
  lifecycle evidence, and fingerprinted idempotency evidence only.
- Adds the built-in `import_history_record` resource definition with append-only
  versions, active lifecycle state, generic-graph-only rendering policy, and
  explicit import-history/resource capability requirements.
- Adds execute-only operation values `import_history_record`,
  `import_history_list`, and `import_history_inspect` behind the existing
  single `capability::execute` primitive.
- Requires trusted current-session/workspace context, exact non-wildcard
  `import_history_record` resource selectors, `import_history.read` /
  `import_history.write` plus resource scopes, idempotency for writes, and
  `networkPolicy: none`.
- Keeps Slice 14B narrow: no raw import payloads, no repository trees, no
  import preview/execute behavior, no repository visualization, no update
  diagnostics, and no native iOS session/import/tree UI.

Accepted validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Formatting passed on the accepted branch. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Agent crate checks passed after import-history implementation and UTF-8-safe truncation fix; only unrelated existing warnings remained. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib import_history_projections_truncate_multibyte_utf8_without_panicking -- --nocapture` | exit 0 | Regression proves provider-visible list/inspect truncation is UTF-8 safe for multi-byte text. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib import_history -- --nocapture` | exit 0 | Focused import-history domain tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture` | exit 0 | BPRC/Phase 2 inventory invariants passed for accepted Slice 14B state. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | DESI evidence and scorecard integrity passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | known caveat only | DRC reported only the pre-existing non-selected `goals`/`web`/`tool_sources` UTC allow-list gap; no import-history findings were present. |
| `scripts/personal-info-guard.sh` | exit 0 | Personal-info guard passed. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git ls-files -ci --exclude-standard` and `test ! -e packages/agent/skills` | exit 0 | No ignored tracked files and no repo-managed first-party skills were present. |

### Accepted Slice 14C: System Update Diagnostics Resource Foundation

Accepted branch:
`codex/phase-2-slice-14c-update-diagnostics-resource-foundation`.

Baseline HEAD:
`a019d083ea2af3dff7f7ce2ddefd7c42c9630c7f`

Accepted commits:

- Implementation `9521cb13b241a9a0c0c759dbdcdae9b199e2eb28`
  (`feat: add update diagnostics resource foundation`).
- Selector-enforcement fix `63177bb4646fbec9cab9489b1fc8fc47ff2851c4`
  (`fix: enforce update diagnostic resource selectors`).
- SACB inventory fix `c3f434686b1eeed6a60e262c46c1498d8c4fd42c`
  (`docs: cover update diagnostics grant test in sacb`).

Thread evidence: discovery thread `019f001b-bd16-77a0-a880-7da7df5e8afc`
selected Slice 14C; implementation thread
`019f0022-dae1-78c0-85a3-03d8f225cf47` completed the implementation; review
thread `019f0044-6f18-7f51-ba1c-f66d009c1536` returned `changes required`;
focused fix thread `019f0047-95af-7eb2-a1ba-1e715b35ef10` fixed
`updateDiagnosticResourceId` engine-level selector enforcement; re-review
thread `019f0051-7173-7aa1-bf76-88b9bcd57270` returned `changes required`
for missing SACB inventory coverage; focused fix thread
`019f0055-54d9-7990-a4a9-9b1ae9ab0b78` added the missing inventory row; and
accepting re-review thread `019f005b-0dbc-7c53-89a9-a41a6c1dfda7` returned
exact verdict `slice accepted`.

Accepted scope:

- Adds `domains/update_diagnostics` as the server owner for durable
  `update_diagnostic_record` resources containing bounded release identity,
  diagnostic status, signature status, signed-release provenance refs,
  source/evidence refs, retention metadata, trace/replay refs, lifecycle
  evidence, and fingerprinted idempotency evidence only.
- Adds the built-in `update_diagnostic_record` resource definition with
  append-only versions, active lifecycle state, metadata-only materialization,
  and explicit update-diagnostics/resource capability requirements.
- Adds execute-only operation values `update_diagnostic_record`,
  `update_diagnostic_list`, and `update_diagnostic_inspect` behind the existing
  single `capability::execute` primitive.
- Requires trusted current-session/workspace context, exact non-wildcard
  `update_diagnostic_record` resource selectors, `update_diagnostics.read` /
  `update_diagnostics.write` plus resource scopes, idempotency for writes, and
  `networkPolicy: none`.
- Keeps Slice 14C narrow: no raw update payloads, no package bytes, no
  production endpoint details, no installer or restart commands, no deploy
  automation, no live production update checks, no package/catalog
  registration, no public update APIs, and no native iOS update panel.

Acceptance validation:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml update_diagnostic --lib -- --nocapture` | exit 0 | Focused update-diagnostic domain, projection, idempotency, validation, and runtime-grant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml update_diagnostic_resource_id_is_selector_enforced --lib -- --nocapture` | exit 0 | Regression proved `updateDiagnosticResourceId` is extracted by the generic engine authorization scanner and a grant scoped to one `update_diagnostic_record` denies another same-kind resource. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | exit 0 | SACB inventory includes `grant_update_diagnostics_tests.rs` and passed after Fix 2. |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` and `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Formatting and Rust check passed; existing provider dead-code warnings were unchanged. |
| BPRC, DESI, IARM, HRA, TMB, TPC, PCC, CSD, public-protocol, performance-resource, and PMBD gates | exit 0 | Static inventories and provider/protocol surfaces matched accepted Slice 14C scope. |
| `scripts/personal-info-guard.sh`, `git diff --check`, `git ls-files -ci --exclude-standard`, and `test ! -e packages/agent/skills` | exit 0 | No personal-info literals, whitespace errors, ignored tracked files, or repo-managed first-party skills were present. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | known non-selected failure only | DRC still reports the pre-existing non-selected `goals`/`web`/`tool_sources` `Utc::now` allow-list gap; accepting re-review found no update/system DRC findings. |

## Slice 14D Review Candidate: Repository Tree Snapshot Resource Foundation

Implementation thread: active Codex thread from orchestration
`019efe16-09d7-73d3-9708-6c6ba5bc6493`.

Review-candidate branch:
`codex/phase-2-slice-14d-repository-tree-snapshot-foundation`.

Baseline HEAD:
`da1955d73c5a6244805afbde54d9adc7a1760f11`

Review-candidate scope:

- Adds `domains/repository_tree` as the server owner for durable
  `repository_tree_snapshot` resources containing content-free repository/root
  refs, optional head refs, tree object refs, bounded normalized relative path
  metadata, aggregate counts, source/evidence refs, retention metadata,
  trace/replay refs, lifecycle evidence, and fingerprinted idempotency evidence.
- Adds the built-in `repository_tree_snapshot` resource definition with
  append-only versions, active lifecycle state, metadata-only materialization,
  and explicit repository-tree/resource capability requirements.
- Adds execute-only operation values `repository_tree_snapshot`,
  `repository_tree_list`, and `repository_tree_inspect` behind the existing
  single `capability::execute` primitive.
- Requires trusted current-session/workspace context, exact non-wildcard
  `repository_tree_snapshot` resource selectors, `repository_tree.read` /
  `repository_tree.write` plus resource scopes, idempotency for writes, and
  `networkPolicy: none`.
- Keeps Slice 14D narrow: no raw file contents, no blob bytes, no absolute
  paths, no unbounded repository tree dumps, no repository visualization, no
  import preview/execute behavior, no native iOS tree UI, and no git mutation
  workflows.

Review-candidate validation so far:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Rust check passed; existing provider dead-code warnings were unchanged. |
| `cargo test --manifest-path packages/agent/Cargo.toml repository_tree --lib -- --nocapture` | exit 0 | Focused repository-tree domain, projection, idempotency, validation, authorization, and runtime-grant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml repository_tree_resource_id_is_selector_enforced --lib -- --nocapture` | exit 0 | Regression proved `repositoryTreeResourceId` is extracted by the generic engine authorization scanner and a grant scoped to one `repository_tree_snapshot` denies another same-kind resource. |
| `cargo test --manifest-path packages/agent/Cargo.toml clarification_includes_capability_execution_guidance --lib -- --nocapture` | exit 0 | Provider prompt guidance includes repository-tree operations and metadata-only/raw-content rejection language. |

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
