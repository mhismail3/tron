# Phase 3 Modular Self-Adapting Engine Evidence Manifest

Status: **complete**
Current score: **100/100**

Scorecard:
[`phase-3-modular-self-adapting-engine-scorecard.md`](phase-3-modular-self-adapting-engine-scorecard.md)

Inventory:
[`phase-3-modular-self-adapting-engine-inventory.md`](phase-3-modular-self-adapting-engine-inventory.md)
and
[`phase-3-modular-self-adapting-engine-inventory.tsv`](phase-3-modular-self-adapting-engine-inventory.tsv)

## Source Audit

The Phase 3 plan is derived from repository artifacts instead of chat-only
state. The audit covered:

- the historical feature index comparing the primitive baseline with
  `origin/next/modular-capability-engine`;
- the Phase 1 iOS affordance progress ledger;
- the completed Phase 2 agent-execution restoration scorecard, evidence
  manifest, narrative inventory, and TSV;
- current README sections for primitive engine scope, capabilities, resources,
  iOS runtime shell, event system, database schema, settings, and proof
  artifacts;
- SSARR and SUWRF docs for successor self-adapting-agent readiness and worker
  lifecycle boundaries;
- TMB, SACB, DESI, BPRC, CPE, DISD, DRC, SOL, PCC, and TPC scorecards and
  inventories as applicable to module/core boundaries;
- AGENTS.md rules for docs/tests, README accuracy, settings parity,
  no-managed-skills, deployment restrictions, and personal-info hygiene.

## Planning Evidence

| Row | Status | Evidence | Validation anchor |
| --- | --- | --- | --- |
| P3MSA-0 | passed | The scorecard records the current Phase 2 closeout baseline and the historical modular-engine comparison commit. | Scorecard Planning baseline and Historical comparison baseline. |
| P3MSA-1 | passed | The scorecard defines the engine-owned primitive set and requires module ownership by default. | Scorecard Core Boundary and Modular Ownership Rule. |
| P3MSA-2 | passed | Slice 23A defines a manifest/registry foundation with provider-safe list/inspect and no execution. | Scorecard Slice 23A and TSV P3MSA-INV-001. |
| P3MSA-3 | passed | Slices 23B through 23E define authoring, validation, review, install, enable, disable, quarantine, and rollback flow. | Scorecard slices 23B through 23E and TSV rows P3MSA-INV-002 through P3MSA-INV-005. |
| P3MSA-4 | passed | Slices 23D, 23F, and 23G require scoped authority, approval, dependency, sandbox, and rollback policy. | Scorecard slices 23D, 23F, 23G and Shared Validation. |
| P3MSA-5 | passed | Slices 24A through 24C activate file/git, jobs/program execution, and subagents only through module contracts. | Scorecard slices 24A through 24C and TSV rows P3MSA-INV-009 through P3MSA-INV-011. |
| P3MSA-6 | passed | Slices 24D and 24E separate memory retrieval and procedural learning from core behavior. | Scorecard slices 24D and 24E and TSV rows P3MSA-INV-012 and P3MSA-INV-013. |
| P3MSA-7 | passed | Slice 23H makes generic autonomous-work visibility the first UI surface and rejects fixed old panels until contracts prove the need. | Scorecard Slice 23H and TSV P3MSA-INV-008. |
| P3MSA-8 | passed | The execution protocol defines discovery, implementation, review, fix, re-review, integration, summary, next-discovery statuses, and first-principles/no-legacy acceptance rules. | Scorecard First-Principles Implementation Standard and Execution Protocol. |
| P3MSA-9 | passed | Shared validation names focused tests and static gates that implementation/review workers must select from, with explicit organization, deduplication, fallback, legacy, and dead-code rejection requirements. | Scorecard First-Principles Implementation Standard and Shared Validation. |
| P3MSA-10 | passed | Rejected shapes are explicitly listed and include old fixed panels, broad DTOs, speculative dependencies, repo-managed skills, and deployment behavior. | Scorecard Rejected Shapes. |

## Plan Creation Validation

| Command | Result | Evidence |
| --- | --- | --- |
| `git status --short --branch` | exit 0 | Current branch was clean on `main...origin/main` before Phase 3 planning edits. |
| `rg --files packages/agent/docs` | exit 0 | Existing restoration scorecards, evidence manifests, inventories, and Phase 1/2 planning artifacts were enumerated. |
| `sed -n '1,180p' packages/agent/docs/phase-2-agent-execution-restoration-inventory.md` | exit 0 | Phase 2 controlled vocabulary and execution roadmap shape were inspected before drafting Phase 3. |
| `sed -n '1,220p' packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md` | exit 0 | Phase 2 scorecard structure, closeout status, and slice evidence style were inspected. |
| `sed -n '1,80p' packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv` | exit 0 | Phase 2 machine-readable row format was inspected before creating the Phase 3 TSV. |
| `sed -n '1,180p' packages/agent/docs/ios-affordance-restoration-progress.md` | exit 0 | Phase 1 shipped user-facing work and deferred behavior were inspected. |
| `sed -n '320,430p' README.md` | exit 0 | README documentation index placement was inspected before wiring Phase 3 artifacts. |
| `sed -n '1,180p' packages/agent/tests/documentation_evidence_scorecard_integrity_invariants.rs` | exit 0 | DESI scorecard/evidence companion requirements were inspected before adding a new scorecard. |

## Implementation Evidence

### Accepted Slice 23A: Module Manifest And Registry Foundation

Discovery thread `019f059a-0ee3-7fb3-aed4-5c7048e297e8` selected Slice 23A
with exact final status `implementation may start` from baseline
`origin/main@710fa0e8dd2f160c0af04f8bbdc005094f0c4a1c`
(`docs: plan phase 3 modular self-adapting engine`).

Implementation branch:
`codex/phase-3-slice-23a-module-manifest-registry`

Implementation thread:
`019f05a1-12f9-7023-97d7-ab239b71abc0`

Independent review thread:
`019f05dd-4eb5-7ca2-a843-1989f9ccd8e7`

Focused fix thread:
`019f05e3-2163-7b93-ae96-7adbe6bf6a00`

Independent re-review thread:
`019f05f2-56e3-7c11-8002-ed3dd18a1835`

Baseline HEAD:
`710fa0e8dd2f160c0af04f8bbdc005094f0c4a1c`
(`docs: plan phase 3 modular self-adapting engine`)

Accepted implementation commit:
`47763bf52f341a336593d0c343b6ada6616e03df`
(`feat: add module manifest registry foundation`)

Accepted fix commit:
`6e1d3176cbe99acbef827b634e51b0076c8153be`
(`fix: narrow module registry grant projection`)

Mainline merge commit:
`a8b891e961f07ba410a0466f047b64103fb96eda`
(`merge: integrate phase 3 slice 23a branch`)

Accepted scope:

- Moves `P3MSA-INV-001` from `pending_review` to `current_baseline` after
  independent re-review accepted the module manifest registry foundation.
- Adds the inspect-only `domains/module_registry` owner with source-backed
  first-party `module_manifest` resources using existing generic resource
  definitions, not a new database table.
- Adds provider-safe `module_list` and `module_inspect` execute operation
  values with bounded identity, capability, resource, authority, settings,
  dependency, validation, provenance, lifecycle, and redaction-proof fields.
- Enforces explicit read-only `module_registry.read` plus `resource.read`
  authority, `module_manifest` resource kind, exact `kind:module_manifest`
  selectors, and exact inspect-resource selectors. Fix 1 removed inherited
  state write/read/list and `agent_state` runtime grant material from module
  registry operations.
- Keeps provider-visible projections metadata-only, with distinct
  `resourceLifecycle` and `manifestLifecycle` detail fields.
- Deliberately excludes module install, module execution, dependency
  restoration, repo-managed `packages/agent/skills`, public `/engine`
  expansion, marketplace UI, fixed iOS panels, broad DTO resurrection, fallback
  shims, production deploy/update behavior, and unrelated cleanup.

Validation evidence:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Rust formatting passed during implementation, fix, re-review, and mainline closeout. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Agent crate type-check passed; only existing provider/resource dead-code warnings were emitted. |
| Focused `module_registry`, `module_manifest`, execute schema, provider guidance, and capability invocation runtime-grant tests | exit 0 | Module manifest schema, seed registration, provider-safe projections, no-write behavior, exact authority/resource selectors, read-only runtime grants, and duplicate lifecycle regression coverage passed. |
| BPRC, DESI, SSARR, TMB, SACB, PPACD, PCC, and TPC invariant suites | exit 0 | Static inventories, provider/protocol boundaries, security/authority boundaries, primitive cleanup, and Phase 3 documentation evidence matched accepted Slice 23A scope. |
| `self_updating_worker_runtime_foundation_invariants` | known baseline failure only | The suite still fails only on the documented pre-existing `packages/agent/src/domains/program_execution` guard mismatch; that path existed at baseline and was not touched by Slice 23A. |
| `scripts/personal-info-guard.sh` | exit 0 | Full scan reported no personal-info leaks in source. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files were reported. |
| `test ! -e packages/agent/skills` | exit 0 | Repo-managed first-party skills directory remains absent. |
| Independent review thread `019f05dd-4eb5-7ca2-a843-1989f9ccd8e7` | exact verdict `changes required` | Review found runtime grant overreach and duplicate lifecycle projection keys before Fix 1. |
| Independent re-review thread `019f05f2-56e3-7c11-8002-ed3dd18a1835` | exact verdict `slice accepted` | Re-review verified branch/head cleanliness, baseline and implementation ancestry, full and fix diffs, read-only module-manifest-only runtime grants, distinct lifecycle fields, provider-safe execute-only scope, pending-review wording before acceptance, focused validation, hygiene checks, and no repo-managed skills. |

Deferred scope remains unchanged: module authoring workspace, validation report
resources, review/install gates, enable/disable/quarantine/rollback, runtime
supervisor, dependency policy execution, generic autonomous-work cockpit, and
feature-pack migration remain later Phase 3 slices.

SSARR classification: `self-sufficient-agent-runtime-readiness` treats this
Phase 3 evidence as planning plus accepted inspect-only module-registry
foundation evidence, not successor runtime execution completion proof.

## Accepted Slice 23B: Module Authoring Workspace Foundation

Discovery thread `019f0604-9ff0-71e0-8fbe-d00a1dd7aedf` selected Slice 23B
with exact final status `implementation may start` from baseline
`origin/main@2ceea2e5df1c367b8c41b6ed2ffa2cb9d0410f61`
(`docs: accept phase 3 slice 23a`).

Implementation branch:
`codex/phase-3-slice-23b-module-authoring-workspace`

Implementation thread:
`019f0609-bf3a-7823-a554-a56e4e7de8e8`

Independent review thread:
`019f062b-868a-7090-b369-ff97e8dcc887`

Focused fix threads:
`019f0631-bd1d-7272-87db-a3f8931b82f2`,
`019f0649-a88d-76f3-adee-2b8ab0006b8a`,
`019f0664-2e89-7181-bb10-d0d0632a1b10`, and
`019f0678-f812-7d61-947d-ec5b55fcf452`

Independent re-review threads:
`019f0640-0d16-7fb1-a4a6-ea5b0f8b1209`,
`019f065c-7840-7772-8c5e-a42ed5fd99c1`,
`019f0672-7da6-7011-a3a0-37343ad8c46e`, and
`019f0687-ce04-7993-8be3-b38734df2e01`

Baseline HEAD:
`2ceea2e5df1c367b8c41b6ed2ffa2cb9d0410f61`
(`docs: accept phase 3 slice 23a`)

Accepted implementation commit:
`34aa65c8869e20bd02f8a7a385e90f707c135f0a`
(`feat: add module authoring proposal foundation`)

Accepted fix commits:
`d6867d9d0b055d101d6c349d84a127ccf203585c`
(`fix: harden module proposal validation`),
`76979ebe9d3d0d978958a5cca131ce0050dd7e97`
(`fix: redact module proposal traces`),
`bd93ba13bbd8a0f1ca9b5456b4cbc774a7e38e3c`
(`fix: harden module proposal metadata tokens`), and
`b19fbfdb0f148335156bcf1eb3f7ee4bb7908554`
(`fix: detect embedded module proposal tokens`)

Mainline merge commit:
`31c61e18f21c7fd0f8a001d078dc61ab28ae3810`
(`merge: integrate phase 3 slice 23b branch`)

Accepted scope:

- Moves `P3MSA-INV-002` from `pending_review` to `current_baseline` after
  independent re-review accepted the module authoring workspace foundation.
- Adds focused `domains/module_authoring` custody for scoped, inert
  `module_proposal` resources using the existing generic resource store.
- Registers resource schema `tron.resource.module_proposal.v1` and payload
  schema version `tron.module_proposal.v1` without a new SQLite table.
- Adds provider-visible `capability::execute` operation values
  `module_proposal_record`, `module_proposal_list`, and
  `module_proposal_inspect`.
- Enforces explicit `module_authoring.read` / `module_authoring.write` plus
  `resource.read` / `resource.write` authority for record, read-only authority
  for list/inspect, `kind:module_proposal` selectors, exact inspect
  `resource:<id>` selectors, and `networkPolicy: none`.
- Stores bounded title/summary identity, intended module refs,
  source/doc/test refs, validation placeholder/status, lifecycle state,
  fingerprinted idempotency/runtime refs, and explicit no-install/no-execution
  proof.
- Rejects unsafe read/write payload fields, unsafe paths, raw prompts, raw code,
  raw commands, package/dependency install requests, and exact or embedded
  token-like provider-visible proposal metadata before storage/projection.
- Stores trace-safe metadata for module proposal execute attempts so rejected
  unsafe payloads, raw authority grant ids, and raw idempotency keys are not
  durable provider-visible trace content.
- Deliberately excludes module install, activation, execution, dependency
  restoration, package managers, physical module workspace directories,
  repo-managed `packages/agent/skills`, raw prompt/proposal/code/command/file
  payloads, unsafe paths, token-like provider-visible metadata, raw
  grant/authority ids, public `/engine` expansion, fixed iOS panels, and
  production deploy/update behavior.

Validation evidence:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Rust formatting passed during implementation, fix, re-review, and mainline closeout. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Agent crate type-check passed; only existing model/provider dead-code warnings were emitted. |
| `cargo test --manifest-path packages/agent/Cargo.toml module_authoring -- --nocapture` | exit 0 | Module proposal registration, create/list/inspect, idempotent replay, read-operation unsafe payload denial, exact inspect selectors, token-like title/summary denial, exact and embedded token-like provider-visible metadata denial, safe ordinary metadata acceptance, bounded refs, and projection redaction passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_module_proposal_trace -- --nocapture` | exit 0 | Rejected unsafe module proposal execute attempts did not expose raw payloads through provider-visible `trace_list` / `trace_get` projections. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | exit 0 | Existing primitive execute trace behavior still passed after module proposal trace-safe request projection support. |
| SACB, PCC, TPC, TMB, PMBD, PPACD, ODA, SSARR, and DESI invariant suites | exit 0 | Authority/resource selector boundaries, cleanup inventories, hard file budgets, provider/model boundaries, public protocol boundaries, observability, readiness, and documentation/evidence scorecard integrity matched accepted Slice 23B scope during fix/re-review loops. |
| `scripts/personal-info-guard.sh` | exit 0 | Full scan reported no personal-info leaks in source. |
| `git diff --check` | exit 0 | No whitespace errors were reported. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files were reported. |
| `test ! -e packages/agent/skills` | exit 0 | Repo-managed first-party skills directory remains absent. |
| Independent review thread `019f062b-868a-7090-b369-ff97e8dcc887` | exact verdict `changes required` | Review found missing unsafe payload guards on list/inspect, insufficient token-like title/summary detection, and missing primitive cleanup inventory coverage. |
| Independent re-review thread `019f0640-0d16-7fb1-a4a6-ea5b0f8b1209` | exact verdict `changes required` | Re-review found rejected unsafe proposal payloads could still be stored in provider-visible capability traces before service validation. |
| Independent re-review thread `019f065c-7840-7772-8c5e-a42ed5fd99c1` | exact verdict `changes required` | Re-review found provider-visible metadata token denial did not cover proposal ids, validation status, and ref ids, and found missing SACB/PCC/TPC classification for the trace regression. |
| Independent re-review thread `019f0672-7da6-7011-a3a0-37343ad8c46e` | exact verdict `changes required` | Re-review found token-like material could still be embedded in otherwise safe-looking proposal ids and refs. |
| Independent re-review thread `019f0687-ce04-7993-8be3-b38734df2e01` | exact verdict `slice accepted` | Re-review verified branch/head cleanliness, baseline and fix ancestry, full and fix diffs, shared embedded token detection, provider-visible metadata protections, accepted scope, focused validation, hygiene checks, and no repo-managed skills. |

Deferred scope remains unchanged: validation report resources, review/install
gates, enable/disable/quarantine/rollback, runtime supervisor, dependency
policy execution, generic autonomous-work cockpit, and feature-pack migration
remain later Phase 3 slices.

## Accepted Slice 23C: Module Contract Test Harness

Discovery thread `019f0697-83fb-7ff2-b985-8f807ecb97b8` selected Slice 23C
with exact final status `implementation may start` from baseline
`origin/main@db560823c3737eed01fdae63425b24a9cf53c0de`
(`docs: accept phase 3 slice 23b`).

Implementation branch:
`codex/phase-3-slice-23c-module-contract-test-harness`

Implementation thread:
`019f069c-814e-7453-8563-a463c05499b3`

Independent review thread:
`019f06cf-4f80-7fe0-9193-6b145826df59`

Focused fix thread:
`019f06d7-f5fb-76a0-abb0-f869f7961d3f`

Independent re-review thread:
`019f0707-388d-7e43-9c45-3d9657e8586d`

Baseline HEAD:
`db560823c3737eed01fdae63425b24a9cf53c0de`
(`docs: accept phase 3 slice 23b`)

Accepted implementation commit:
`d2ba314b145c09f70c23ff3774b0075e52949f40`
(`feat: add module validation report harness`)

Accepted fix commit:
`a661175984dce70cdb8c974ddc691794c9df0d90`
(`fix: harden module validation evidence refs`)

Mainline merge commit:
`6e74b641f815de86f71a0c82798b1a2889f01d1a`
(`merge: integrate phase 3 slice 23c branch`)

Accepted scope:

- Moves `P3MSA-INV-003` from `pending_review` to `current_baseline` after
  independent re-review accepted the module contract test harness foundation.
- Adds focused `domains/module_validation` custody for scoped, inert
  `module_validation_report` resources using the existing generic resource
  store, not a new SQLite table.
- Registers resource schema `tron.resource.module_validation_report.v1` and
  payload schema version `tron.module_validation_report.v1`.
- Adds provider-visible `capability::execute` operation values
  `module_validation_record`, `module_validation_list`, and
  `module_validation_inspect`.
- Enforces explicit `module_validation.read` / `module_validation.write` plus
  `resource.read` / `resource.write` authority for record, read-only authority
  for list/inspect, `kind:module_validation_report` selectors, exact inspect
  `resource:<id>` selectors, and `networkPolicy: none`.
- Stores bounded module/proposal refs, manifest/resource/provider projection
  parity checks, required docs/tests evidence refs, deterministic command
  identity/result refs with non-shell summaries/fingerprints, failure evidence
  refs, validation status/check summaries, lifecycle state, fingerprinted
  idempotency/runtime refs, and explicit no-install/no-execution proof.
- Rejects unsafe read/write payload fields, unsafe paths, raw logs, raw
  commands, raw shell command-like command/result preview or summary text, raw
  env values, raw code, raw file contents, package/dependency install requests,
  raw grant/authority ids, prompt-injection-like material, credential-like
  strings, and exact or embedded token-like provider-visible metadata before
  storage/projection.
- Deliberately excludes module install, activation, execution, command
  execution, dependency restoration, package managers, physical module
  workspace directories, repo-managed `packages/agent/skills`, public
  `/engine` expansion, fixed iOS panels, and production deploy/update behavior.

Validation evidence:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Formatting gate passed after the raw-shell ref hardening and focused shell-ref regression split. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Type-check gate passed with existing provider/model dead-code warnings only. |
| `cargo test --manifest-path packages/agent/Cargo.toml module_validation -- --nocapture` | exit 0 | Module validation report registration, record/list/inspect, idempotent replay, lifecycle stream evidence, failed validation evidence retention, required docs/tests evidence, exact inspect selectors, unsafe read/write payload denial, token-like metadata denial, raw shell command preview/summary denial, safe ordinary evidence summaries, bounded projections, runtime grant scoping, and engine authorization tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml execute_schema_exposes_primitive_operations_not_catalog_targets -- --nocapture` | exit 0 | Provider-visible execute schema exposes the module-validation operation values while retaining the primitive operation boundary. |
| `cargo test --manifest-path packages/agent/Cargo.toml clarification_includes_capability_execution_guidance -- --nocapture` | exit 0 | OpenAI message-converter guidance includes module-validation metadata-only/no-execution wording. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture` | exit 0 | Phase 3 scorecard/evidence/inventory documentation structure remains consistent. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants` | exit 0 | SACB static gate passed with the refreshed 975-row authority/security inventory covering the Slice 23C module-validation paths. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants` | exit 0 | TMB static gate passed with the refreshed 1,290-row modularity inventory and Slice 23C classifications. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants` | exit 0 | PMBD static gate passed for provider/model boundary discipline. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants` | exit 0 | PPACD static gate passed; no public `/engine` expansion was introduced. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants` | exit 0 | PCC static gate passed with the refreshed 1,987-row primitive cleanup inventory and Slice 23C retain classifications. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants` | exit 0 | TPC static gate passed with the refreshed 1,942-row retention inventory and Slice 23C classifications. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants` | exit 0 | SSARR static gate passed; successor-runtime claims remain documentation-only. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants` | exit 0 | ODA static gate passed for bounded diagnostics/auditability boundaries. |
| `scripts/personal-info-guard.sh` | exit 0 | Full personal-info literal guard passed. |
| `git diff --check` | exit 0 | Whitespace check passed. |
| `git ls-files -ci --exclude-standard` | exit 0 | No tracked ignored files were present. |
| `test ! -e packages/agent/skills` | exit 0 | Repo-managed first-party skills directory remains absent. |
| Independent review thread `019f06cf-4f80-7fe0-9193-6b145826df59` | exact verdict `changes required` | Review found stale SACB/TMB/PCC/TPC inventories and evidence manifest entries, and found raw shell command text could be stored/projected through module validation command/result ref preview and summary fields. |
| Independent re-review thread `019f0707-388d-7e43-9c45-3d9657e8586d` | exact verdict `slice accepted` | Re-review verified branch/head cleanliness, baseline and implementation ancestry, full and fix diffs, raw-shell ref hardening, refreshed inventory counts, accepted scope, focused validation, hygiene checks, and no repo-managed skills. |

Deferred scope remains unchanged: review/install gates,
enable/disable/quarantine/rollback, runtime supervisor, dependency policy
execution, generic autonomous-work cockpit, and feature-pack migration remain
later Phase 3 slices.

## Accepted Slice 23D: Module Review Approval And Install Gate

Discovery thread `019f071a-01e7-79a0-b98c-99b945f05aeb` selected Slice 23D
with exact final status `implementation may start` from baseline
`origin/main@7c4ec8519394109ddef107aa5891d4875e5b14de`
(`docs: accept phase 3 slice 23c`).

Implementation branch:
`codex/phase-3-slice-23d-module-review-approval-install-gate`

Implementation thread:
`019f071f-c70a-7bc1-9634-1877509c3659`

Independent review thread:
`019f0751-eb41-75a0-859d-4a5cd8d62505`

Focused fix thread:
`019f075b-646f-7b61-989a-8a2a396cb7db`

Independent re-review thread:
`019f076f-2ab2-72d2-9e72-d6f0a15778d8`

Baseline HEAD:
`7c4ec8519394109ddef107aa5891d4875e5b14de`
(`docs: accept phase 3 slice 23c`)

Accepted implementation commit:
`7beea4cf3210d03ab747ed123cad4b239596693a`
(`feat: add module install approval gate`)

Accepted fix commit:
`96a5c1dd9e6b60e6545873c8789bf3858a440618`
(`fix: prepare slice 23d install gate for review`)

Mainline merge commit:
`5545265b893db1702c4dd7864867eb056f9fd3fc`
(`merge: integrate phase 3 slice 23d branch`)

Accepted scope:

- Moves `P3MSA-INV-004` from `pending_review` to `current_baseline` after
  independent re-review accepted the module review approval and install gate.
- Adds focused `domains/module_install` custody for scoped, inert
  `module_install_request` and `module_install_decision` resources using the
  existing generic resource store, not a new SQLite table.
- Registers resource schemas `tron.resource.module_install_request.v1` and
  `tron.resource.module_install_decision.v1`, with payload schema versions
  `tron.module_install_request.v1` and `tron.module_install_decision.v1`.
- Adds provider-visible `capability::execute` operation values
  `module_install_request_record`, `module_install_request_list`,
  `module_install_request_inspect`, `module_install_decision_record`,
  `module_install_decision_list`, and `module_install_decision_inspect`.
- Enforces explicit `module_install.read` / `module_install.write` plus
  `resource.read` / `resource.write` authority for record operations,
  read-only authority for list/inspect, non-wildcard
  `kind:module_install_request` and `kind:module_install_decision` selectors,
  exact inspect `resource:<id>` selectors, and `networkPolicy: none`.
- Requires a current-scope, current-version, passed `module_validation_report`
  prerequisite with bounded module refs, docs/tests evidence, and explicit
  no-install/no-execution proof before storing a review request.
- Requires fresh scoped approval, explicit derived authority, request/report
  revalidation, and denial evidence for rejected/denied decisions before
  storing decision metadata.
- Stores dependency policy linkage and rollback proof only as bounded metadata
  refs/status fields, with metadata lifecycle states such as `pending_review`,
  `install_candidate`, `rejected`, `superseded`, and `archived`.
- Deliberately excludes physical install, activation, execution, dependency
  restoration, package managers, network access, production update/deploy
  behavior, repo-managed `packages/agent/skills`, public `/engine` expansion,
  fixed iOS panels, raw logs/commands/env/code/file contents/unsafe paths, raw
  grant/authority ids, token-like material, and approval evidence minting
  authority by itself.

Validation evidence:

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | exit 0 | Rust formatting gate passed for Slice 23D source and tests. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | exit 0 | Agent crate type-check gate passed; existing provider/model dead-code warnings remained unchanged. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib module_install -- --nocapture` | exit 0 | Module install resource schemas, record/list/inspect, idempotent replay, lifecycle events, approval denials, validation prerequisite denials, unsafe payload denial, exact inspect selectors, runtime grants, engine authorization, and bounded projections passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib module_install_runtime_grants -- --nocapture` | exit 0 | Capability runtime grant derivation keeps explicit module-install/resource authority, exact selectors, `networkPolicy: none`, and no inherited `agent_state`. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib execute_schema_exposes -- --nocapture` | exit 0 | Provider-visible execute schema exposes only bounded module-install operation values and fields. |
| `cargo test --manifest-path packages/agent/Cargo.toml --lib clarification_includes_capability_execution_guidance -- --nocapture` | exit 0 | OpenAI message-converter guidance documents metadata-only install gate constraints. |
| DESI, SACB, TMB, PCC, TPC, PMBD, PPACD, SSARR, and ODA invariant suites | exit 0 | Documentation, authority/security, modularity, cleanup, provider/model, public protocol, readiness, and observability inventories passed after the Slice 23D updates. |
| `scripts/personal-info-guard.sh`, `git diff --check`, `git ls-files -ci --exclude-standard`, `test ! -e packages/agent/skills` | exit 0 | Hygiene, ignored-file, and no repo-managed-skills gates passed after final source edits. |
| Independent review thread `019f0751-eb41-75a0-859d-4a5cd8d62505` | exact verdict `changes required` | Review found pre-acceptance docs marked Slice 23D as accepted/current baseline and cleanup static gates failed for over-budget `module_install` source files. |
| Independent re-review thread `019f076f-2ab2-72d2-9e72-d6f0a15778d8` | exact verdict `slice accepted` | Re-review verified branch/head cleanliness, baseline/implementation/fix ancestry, full and fix diffs, pending-review wording before acceptance, hard-budget refactor without exception rows, accepted scope, focused validation, hygiene checks, and no repo-managed skills. |

Deferred scope remains unchanged: physical install, enable/disable/quarantine/
rollback, runtime supervisor, dependency policy activation, generic
autonomous-work cockpit, and feature-pack migration remain later Phase 3
slices.
