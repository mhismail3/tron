# Tron

**A persistent, event-sourced AI coding agent for macOS.**

Tron is a local-first AI coding agent that runs as a persistent background service. In the current primitive baseline, a Rust server handles provider communication, a single `execute` primitive, agent-owned state, and event-sourced session persistence. The Self-Updating Worker Runtime Foundation adds the first post-baseline host-owned lifecycle for local launchable packages while preserving provider minimality: the provider-visible model tool remains `execute`. The iOS app is a thin chat and generic runtime shell with an Agent cockpit; fixed product panels are absent from supported baseline behavior. Feature restoration follows an iii-aligned Worker / Function / Trigger contract: capabilities must enter as worker-owned functions and triggers in the live catalog, with package lifecycle tracked as resources and events rather than hardcoded harness features.

This README is the single, canonical reference for the project and is expected to stay in sync with the code. The Rust codebase is self-documenting: `packages/agent/src/lib.rs` declares the module tree, `mod.rs` files map submodules, and `// INVARIANT:` comments mark critical correctness constraints. iOS documentation lives in `packages/ios-app/docs/`. When you change anything described here — modules, CLI commands, capabilities, engine protocol methods, event types, settings fields, DB tables, install layout — update this file in the same commit.

---

## Table of Contents

- [Architecture](#architecture)
- [Living Architecture Docs](#living-architecture-docs)
- [Repository Structure](#repository-structure)
- [Rust Modules](#rust-modules)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Capabilities](#capabilities)
- [Engine Protocol API](#engine-protocol-api)
- [Event System](#event-system)
- [Settings](#settings)
- [Authentication](#authentication)
- [Context and Compaction](#context-and-compaction)
- [Database Schema](#database-schema)
- [iOS App](#ios-app)
- [Mac App](#mac-app)
- [Permissions](#permissions)
- [Deployment](#deployment)
- [Testing](#testing)
- [Core Invariants](#core-invariants)

---

## Architecture

```
+-----------------------------------------------------------------------------+
|                              iOS App (SwiftUI)                              |
|                           packages/ios-app                                  |
|              MVVM  -  Coordinators  -  Event Plugins  -  Swift 6            |
+-------------------------------+---------------------------------------------+
                                | WebSocket (`/engine`), port 9847
                                v
+-----------------------------------------------------------------------------+
|                          Rust Agent Server                                  |
|                         packages/agent                                      |
|                                                                             |
|  +-------------+  +------------+  +------------+  +------------------------+ |
|  |  Providers  |  | Capability |  |  Context   |  |     Orchestrator       | |
|  |  Anthropic  |  | execute    |  |  soul      |  |  Session lifecycle     | |
|  |  OpenAI     |  | state ops  |  |  state     |  |  Turn management       | |
|  |  Google     |  | file ops   |  |  compaction|  |  Event routing         | |
|  |  MiniMax    |  | process op |  |  messages  |  |  Turn recovery         | |
|  +-------------+  +------------+  +------------+  +------------------------+ |
+------------------------------------+----------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
|                         Event Store (SQLite)                                |
|   - Immutable event log with tree structure (fork/rewind)                   |
|   - Session state reconstruction via ancestor traversal                     |
|   - SQLite-backed sessions, events, blobs, logs, engine ledger/state        |
+-----------------------------------------------------------------------------+

```

### Data Path

1. Client connects to `/engine` and sends engine protocol messages
2. The `server` module validates framing and builds an `EngineTransportRequest`
3. The envelope invokes a canonical `namespace::function` engine capability through a transport trigger
4. Canonical functions call runtime, orchestrator, event store, or domain services as needed
5. Domain output is serialized at the transport boundary
6. Runtime events publish neutral `ServerEventPayload` records to engine streams, and `/engine` subscriptions deliver stream records

---

## Living Architecture Docs

The durable architecture docs live beside the code they describe. The root
README is the map; source files, `mod.rs` docs, `INVARIANT:` comments, and
concern-owned tests are the durable truth. One-off phase plans, migration
rubrics, and audit snapshots are not kept as source-of-truth docs because they
drift after the code changes.

Current living entry points:

- `packages/agent/src/lib.rs`: Rust crate/module tree.
- `packages/agent/src/engine/mod.rs`: engine fabric ownership.
- `packages/agent/src/engine/durability/resources/mod.rs`: resource substrate ownership.
- `packages/agent/src/engine/primitives/mod.rs`: primitive capability surface.
- `packages/agent/src/domains/capability/mod.rs`: model-facing `execute`
  primitive and provider export.
- `packages/agent/docs/primitive-engine-teardown-scorecard.md`: completed
  clean-break primitive engine teardown scorecard for stripping hard-coded
  capabilities, policies, skills, rules, helper launch products, and fixed iOS product
  surfaces down to the smallest provider loop, single `execute` primitive,
  agent-owned state workspace, event/ledger truth, and dynamic client shell.
- `packages/agent/docs/primitive-engine-teardown-evidence-manifest.md`:
  companion evidence manifest for the completed primitive engine teardown
  scorecard.
- `packages/agent/docs/primitive-engine-teardown-inventory.md`: PET-1
  source-audited deletion map for every current Rust domain, engine primitive
  worker, runner context plane, managed skill, doc, iOS source/view root, and
  settings surface.
- `packages/agent/docs/determinism-replayability-scorecard.md`: completed
  Determinism Replayability Campaign scorecard for proving offline audit and
  reconstruction replay from durable session, provider, trace, ledger, stream,
  queue, and hash records.
- `packages/agent/docs/determinism-replayability-evidence-manifest.md`:
  companion evidence manifest for DRC row checkpoints, verification logs, and
  residual replay risks.
- `packages/agent/docs/determinism-replayability-inventory.md`: DRC replay
  source, entropy, API, hash, and proof inventory.
- `packages/agent/docs/determinism-replayability-inventory.tsv`:
  machine-readable replay-critical source inventory used by DRC static gates.
- `packages/agent/docs/primitive-code-cleanup-scorecard.md`: completed whole-repo
  primitive cleanup scorecard for folder ownership, file budgets, generated
  artifact hygiene, and final retained-surface proof.
- `packages/agent/docs/primitive-code-cleanup-evidence-manifest.md`: companion
  evidence manifest for the completed primitive cleanup scorecard.
- `packages/agent/docs/primitive-code-cleanup-inventory.md`: PCC-1
  whole-repo tracked-file inventory, classification summary, and canonical
  cleanup target tree.
- `packages/agent/docs/primitive-code-cleanup-file-inventory.tsv`:
  machine-readable per-file cleanup classification used by static gates.
- `packages/agent/docs/true-primitive-cleanup-scorecard.md`: completed
  scorecard for the final strict primitive cleanup pass over oversized roots,
  residue review, dead state, provider/model ownership, iOS shell flattening,
  Mac/scripts helper scope, and closeout evidence.
- `packages/agent/docs/true-primitive-cleanup-evidence-manifest.md`: companion
  evidence manifest for the completed True Primitive Cleanup scorecard.
- `packages/agent/docs/true-primitive-cleanup-retention-inventory.md`: completed
  TPC retention inventory that classifies every tracked source/docs/script path
  in scope as primitive, implementation, support, test, docs, or delete.
- `packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv`:
  machine-readable TPC retention inventory used by static gates.
- `packages/agent/docs/true-modularity-boundary-scorecard.md`: completed
  scorecard for proving Rust and iOS boundaries are black-boxed by ownership,
  narrow APIs, and guarded dependency direction.
- `packages/agent/docs/true-modularity-boundary-evidence-manifest.md`:
  companion evidence manifest for the completed True Modularity Boundary campaign.
- `packages/agent/docs/true-modularity-boundary-inventory.md`: completed TMB
  boundary taxonomy, dependency-direction rules, and composition-root exception
  list.
- `packages/agent/docs/true-modularity-boundary-inventory.tsv`:
  machine-readable Rust/Swift source ownership inventory used by TMB static
  gates.
- `packages/agent/docs/failure-semantics-scorecard.md`: completed Failure
  Semantics Campaign scorecard for enforcing one canonical error envelope
  across provider/model errors, runtime turn failures, capability results,
  transport responses, durable events, replay, and iOS projections.
- `packages/agent/docs/failure-semantics-evidence-manifest.md`: companion
  evidence manifest for FSC row checkpoints, verification logs, and residual
  failure-contract risks.
- `packages/agent/docs/failure-semantics-inventory.md`: completed FSC inventory of
  server, engine, provider, runtime, transport, durable replay, and iOS failure
  surfaces.
- `packages/agent/docs/failure-semantics-inventory.tsv`: machine-readable FSC
  failure-surface inventory used by static gates.
- `packages/agent/docs/state-ownership-lifecycle-scorecard.md`: completed State
  Ownership And Lifecycle campaign scorecard proving every stateful server,
  engine, iOS, script/CI, and docs-owned state claim has one owner, lifecycle
  class, mutation boundary, hydration path, retirement path, and concurrency or
  task guard.
- `packages/agent/docs/state-ownership-lifecycle-evidence-manifest.md`:
  companion evidence manifest for SOL row checkpoints, verification logs, and
  residual lifecycle risks.
- `packages/agent/docs/state-ownership-lifecycle-inventory.md`: completed SOL
  state-surface lifecycle taxonomy and inventory notes.
- `packages/agent/docs/state-ownership-lifecycle-inventory.tsv`:
  machine-readable SOL state ownership inventory used by static gates.
- `packages/agent/docs/concurrency-scheduling-discipline-scorecard.md`: completed
  Concurrency Scheduling Discipline scorecard proving task ownership, bounded
  queues/streams, timer fairness, blocking isolation, agent/session concurrency,
  engine worker scheduling, iOS transport/update scheduling, and deterministic
  scheduling tests.
- `packages/agent/docs/concurrency-scheduling-discipline-evidence-manifest.md`:
  companion evidence manifest for CSD row checkpoints, verification logs, and
  closed scheduling findings.
- `packages/agent/docs/concurrency-scheduling-discipline-inventory.md`: completed
  CSD taxonomy and scheduling-surface proof notes.
- `packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv`:
  machine-readable CSD scheduling inventory used by static gates.
- `packages/agent/docs/security-authority-capability-boundaries-scorecard.md`:
  completed Security Authority Capability Boundaries scorecard for public
  transport auth, authority grants, capability execution, worker isolation,
  secrets, redaction, and pairing lifecycle proof.
- `packages/agent/docs/security-authority-capability-boundaries-evidence-manifest.md`:
  companion evidence manifest for SACB row checkpoints, verification logs, and
  security boundary findings.
- `packages/agent/docs/security-authority-capability-boundaries-inventory.md`:
  completed SACB boundary taxonomy and security-surface proof notes.
- `packages/agent/docs/security-authority-capability-boundaries-inventory.tsv`:
  machine-readable SACB security boundary inventory used by static gates.
- `packages/agent/docs/observability-diagnostics-auditability-scorecard.md`:
  completed Observability Diagnostics Auditability scorecard for proving
  session events, provider audits, primitive trace records, engine ledger rows,
  logs, diagnostics bundles, runtime decisions, and CLI/dev diagnostics remain
  inspectable through stable IDs without leaking secrets.
- `packages/agent/docs/observability-diagnostics-auditability-evidence-manifest.md`:
  companion evidence manifest for ODA row checkpoints, verification logs, and
  residual observability risks.
- `packages/agent/docs/observability-diagnostics-auditability-inventory.md`:
  completed ODA source inventory taxonomy and proof notes.
- `packages/agent/docs/observability-diagnostics-auditability-inventory.tsv`:
  machine-readable ODA source inventory used by static gates.
- `packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-scorecard.md`:
  completed cleanup scorecard for removing the off-plan authorship work before
  continuing the original primitive-engine hardening meta-slices.
- `packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-evidence-manifest.md`:
  companion evidence manifest for cleanup row checkpoints, verification logs,
  and residual risks.
- `packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.md`:
  cleanup source inventory taxonomy and proof notes.
- `packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv`:
  machine-readable cleanup inventory used by static gates.
- `packages/agent/docs/data-integrity-storage-evolution-migration-discipline-scorecard.md`:
  completed Data Integrity Storage Evolution Migration Discipline scorecard for
  SQLite storage ownership, schema drift rejection, generation/archive rules,
  WAL/checkpoint behavior, runtime hygiene, and closeout proof.
- `packages/agent/docs/data-integrity-storage-evolution-migration-discipline-evidence-manifest.md`:
  companion evidence manifest for DSEMD command results and residual risks.
- `packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.md`:
  completed storage surface taxonomy and ownership notes.
- `packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv`:
  machine-readable DSEMD storage inventory used by static gates.
- `packages/agent/docs/public-protocol-api-contract-discipline-scorecard.md`:
  completed Public Protocol API Contract Discipline scorecard for `/engine`
  public methods, wire schemas, context boundaries, response/error/event
  payloads, DTO parity, iOS transport decoders/encoders, and closeout proof.
- `packages/agent/docs/public-protocol-api-contract-discipline-evidence-manifest.md`:
  companion evidence manifest for PPACD command results and corrected findings.
- `packages/agent/docs/public-protocol-api-contract-discipline-inventory.md`:
  completed public protocol surface taxonomy and ownership notes.
- `packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv`:
  machine-readable PPACD public protocol inventory used by static gates.
- `packages/agent/docs/provider-model-boundary-discipline-scorecard.md`:
  completed Provider / Model Boundary Discipline scorecard for provider/model
  request, stream, auth, retry, error, catalog, token, audit, and redaction
  boundaries across OpenAI, Anthropic, Google, Kimi, MiniMax, and Ollama.
- `packages/agent/docs/provider-model-boundary-discipline-evidence-manifest.md`:
  companion evidence manifest for PMBD lineage, stale-branch quarantine,
  verification commands, and residual risks.
- `packages/agent/docs/provider-model-boundary-discipline-inventory.md`:
  completed PMBD provider/model boundary taxonomy and proof notes.
- `packages/agent/docs/provider-model-boundary-discipline-inventory.tsv`:
  machine-readable PMBD provider/model boundary inventory used by static gates.
- `packages/agent/docs/performance-resource-governance-scorecard.md`:
  completed Performance / Resource Governance scorecard for queue,
  concurrency, stream, payload, timeout, shutdown, retention, startup,
  runtime/iOS boundary, docs, CI, and verification hardening.
- `packages/agent/docs/performance-resource-governance-evidence-manifest.md`:
  companion evidence manifest for PERF lineage, stale-branch quarantine,
  resource-boundary proofs, verification commands, and residual risks.
- `packages/agent/docs/performance-resource-governance-inventory.md`:
  completed PERF resource-governance taxonomy and proof notes.
- `packages/agent/docs/performance-resource-governance-inventory.tsv`:
  machine-readable PERF resource-governance inventory used by static gates.
- `packages/agent/docs/configuration-profile-environment-discipline-scorecard.md`:
  completed Configuration / Profile / Environment Discipline scorecard for
  settings schema/default parity, sparse overlays, profile recovery, env
  ownership, iOS settings parity, docs, CI, and verification.
- `packages/agent/docs/configuration-profile-environment-discipline-evidence-manifest.md`:
  companion evidence manifest for CPE lineage, stale-branch quarantine,
  settings/profile/env proofs, verification commands, and residual risks.
- `packages/agent/docs/configuration-profile-environment-discipline-inventory.md`:
  completed CPE settings/profile/env taxonomy and proof notes.
- `packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv`:
  machine-readable CPE settings/profile/env inventory used by static gates.
- `packages/agent/docs/release-install-upgrade-rollback-discipline-scorecard.md`:
  completed Release / Install / Upgrade / Rollback Discipline scorecard for Mac
  app install/update, LaunchAgent/SMAppService ownership, `tron dev`,
  contributor deploy, rollback, setup/uninstall, generated projects, docs, CI,
  and verification.
- `packages/agent/docs/release-install-upgrade-rollback-discipline-evidence-manifest.md`:
  companion evidence manifest for RIURD lineage, stale-branch quarantine,
  source findings, command results, and residual risks.
- `packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.md`:
  completed RIURD release/install lifecycle taxonomy and proof notes.
- `packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.tsv`:
  machine-readable RIURD release/install inventory used by static gates.
- `packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md`:
  completed iOS Thin Client / Generic Runtime Shell scorecard for proving the
  iOS app remains a thin `/engine` client with robust settings, pairing, logs,
  chat, generic primitive/result display, server errors, simulator evidence,
  generated-project discipline, docs, CI, and source guards.
- `packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md`:
  companion evidence manifest for IOSTC lineage, stale-branch quarantine,
  source findings, simulator commands, verification commands, and residual
  risks.
- `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md`:
  completed IOSTC iOS client surface taxonomy and ownership notes.
- `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv`:
  machine-readable IOSTC inventory used by static gates.
- `packages/agent/docs/developer-experience-repo-hygiene-automation-scorecard.md`:
  completed Developer Experience / Repo Hygiene / Automation scorecard for
  setup, dev server, local/GitHub CI parity, generated projects, docs upkeep,
  ignored artifacts, version helpers, branch handoff, and closeout hygiene.
- `packages/agent/docs/developer-experience-repo-hygiene-automation-evidence-manifest.md`:
  companion evidence manifest for DXRHA source findings, verification commands,
  stale-branch quarantine, and residual workflow risks.
- `packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.md`:
  completed DXRHA contributor workflow taxonomy and ownership notes.
- `packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv`:
  machine-readable DXRHA workflow inventory used by static gates.
- `packages/agent/docs/documentation-evidence-scorecard-integrity-scorecard.md`:
  completed Documentation / Evidence / Scorecard Integrity scorecard for
  active-doc truthfulness, command-evidence provenance, scorecard arithmetic,
  inventory coverage, local/GitHub gate parity, branch handoff, and closeout
  proof.
- `packages/agent/docs/documentation-evidence-scorecard-integrity-evidence-manifest.md`:
  companion evidence manifest for DESI source findings, verification commands,
  stale-branch quarantine, and residual documentation/evidence risks.
- `packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.md`:
  completed DESI documentation/evidence taxonomy and ownership notes.
- `packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv`:
  machine-readable DESI artifact inventory used by static gates.
- `packages/agent/docs/self-sufficient-agent-runtime-readiness-scorecard.md`:
  completed Self-Sufficient Agent Runtime Readiness scorecard for auditing
  clean extension points for generated workers, learned rules/memory, tool
  synthesis, and agent-authored state without implementing successor features.
- `packages/agent/docs/self-sufficient-agent-runtime-readiness-evidence-manifest.md`:
  companion evidence manifest for SSARR lineage, source audit, term
  classification, verification commands, iOS no-touch rationale, and residual
  readiness risks.
- `packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.md`:
  completed SSARR readiness taxonomy and extension-point ownership notes.
- `packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.tsv`:
  machine-readable SSARR readiness inventory used by static gates.
- `packages/agent/docs/primitive-minimality-closure-scorecard.md`: completed
  Primitive Minimality Closure scorecard for the post-SSARR teardown pass over
  dead provider helpers, stream residue, proof-layer parity, retained
  suspicious surfaces, and final regression proof.
- `packages/agent/docs/primitive-minimality-closure-evidence-manifest.md`:
  companion evidence manifest for PMC baseline checks, removal batches, failed
  attempts and fixes, retained-contract rationale, and final verification.
- `packages/agent/docs/primitive-minimality-closure-inventory.md`: completed PMC
  classification of removed runtime residue, retained provider/engine
  contracts, historical evidence, and static gates.
- `packages/agent/docs/primitive-minimality-closure-inventory.tsv`:
  machine-readable PMC minimality inventory used by static gates.
- `packages/agent/docs/baseline-pre-restoration-closure-scorecard.md`: completed
  Baseline Pre-Restoration Closure scorecard for certifying the current
  primitive baseline, iii-style worker/function/trigger alignment, restoration
  backlog, active-doc cleanup, absence guards, entry contract, and final
  pre-restoration verification.
- `packages/agent/docs/baseline-pre-restoration-closure-evidence-manifest.md`:
  companion evidence manifest for BPRC lineage, restoration backlog proof,
  active-doc cleanup, gate wiring, validation commands, and residual risks.
- `packages/agent/docs/baseline-pre-restoration-closure-inventory.md`:
  completed BPRC classification of baseline artifacts, foundational substrate,
  restoration backlog rows, and the pre-restoration entry contract.
- `packages/agent/docs/baseline-pre-restoration-closure-inventory.tsv`:
  machine-readable BPRC inventory and restoration backlog used by static gates.
- `packages/agent/docs/self-updating-worker-runtime-foundation-scorecard.md`:
  completed Self-Updating Worker Runtime Foundation scorecard for local package
  lifecycle ownership, manifest validation, authority-derived launches,
  conformance proof, resource/event evidence, rollback semantics, and
  no fixed iOS/product-panel restoration.
- `packages/agent/docs/self-updating-worker-runtime-foundation-evidence-manifest.md`:
  companion evidence manifest for SUWRF source changes, focused tests, static
  gates, final closeout commands, iOS no-touch rationale, and failed
  attempt/fix records.
- `packages/agent/docs/self-updating-worker-runtime-foundation-inventory.md`:
  completed SUWRF classification of new artifacts, lifecycle source files,
  typed worker resource kinds, preserved boundaries, and validation gates.
- `packages/agent/docs/self-updating-worker-runtime-foundation-inventory.tsv`:
  machine-readable SUWRF inventory used by static gates.
- `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-scorecard.md`:
  completed iOS Self-Adapting Agent Cockpit Baseline scorecard for the
  user-facing worker lifecycle catalog, package actions, runtime `ui_surface`
  rendering, and neutral glass cockpit shell; Phase 2 Slice 1 extends that
  shell with catalog discovery and report evidence.
- `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-evidence-manifest.md`:
  companion evidence manifest for focused Swift tests, simulator validation,
  static gates, and closeout commands.
- `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-inventory.md`:
  completed IOSAC retained/absent surface inventory.
- `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-inventory.tsv`:
  machine-readable IOSAC inventory used by static gates.
- `packages/agent/docs/ios-affordance-restoration-map-scorecard.md`:
  completed iOS Affordance Restoration Map scorecard for exhaustively
  classifying removed old iOS affordances before any Phase 1 restoration
  implementation.
- `packages/agent/docs/ios-affordance-restoration-map-evidence-manifest.md`:
  companion evidence manifest for IARM old-tree coverage, failed-attempt
  policy, validation commands, and Phase 1 handoff.
- `packages/agent/docs/ios-affordance-restoration-map-inventory.md`:
  completed IARM taxonomy, first-principles review rubric, historical Phase 1
  queue, and original Phase 2 agent-execution anchor.
- `packages/agent/docs/ios-affordance-restoration-map-inventory.tsv`:
  machine-readable IARM coverage map used by static gates.
- `packages/agent/docs/ios-affordance-restoration-progress.md`:
  active execution ledger for completed iOS affordance restoration slices,
  accepted off-plan UI/runtime work, validation evidence, deferred behavior, and
  the Phase 1 closeout state.
- `packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md`:
  completed planning scorecard for the Phase 2 agent-execution restoration
  roadmap, primitive-vs-capability classifications, memory architecture, slice
  ordering, validation gates, and handoff packet.
- `packages/agent/docs/phase-2-agent-execution-restoration-evidence-manifest.md`:
  companion evidence manifest for the Phase 2 planning scorecard.
- `packages/agent/docs/phase-2-agent-execution-restoration-inventory.md`:
  narrative inventory for Phase 2 feature families and current gaps.
- `packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv`:
  machine-readable Phase 2 feature-family inventory used by future slice
  handoffs.
- `packages/agent/docs/restoration-retrospective-audit-status.md`: active
  retrospective audit tracker for the ordered completed-slice queue, audit
  constraints, first-audit target, accepted deferred scope, and current
  Phase 2 Slice 5A, accepted Slice 6A through Slice 6E source-control
  foundations, accepted Slice 7A goal/question foundation, and accepted Slice
  8A web fetch/source provenance foundation, and the accepted Slice 8B web
  source citation/inspection foundation.
- `packages/agent/docs/hierarchical-rearchitecture-scorecard.md`: completed
  whole-repo hierarchical rearchitecture scorecard for server, iOS, Mac,
  scripts, docs, inventories, and static gates.
- `packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md`:
  companion evidence manifest for the completed hierarchical rearchitecture
  scorecard.
- `packages/agent/docs/post-hra-adversarial-hardening-scorecard.md`: completed
  closeout campaign for adversarial audit findings after hierarchical
  rearchitecture completion.
- `packages/agent/docs/post-hra-adversarial-hardening-evidence-manifest.md`:
  companion evidence manifest for the post-HRA adversarial hardening campaign.
- `packages/agent/docs/post-hra-adversarial-hardening-plan-summary.md`:
  redacted in-repo digest of the operator post-HRA adversarial hardening plan.
- `packages/agent/docs/post-aha-adversarial-closeout-scorecard.md`: completed
  closeout campaign for adversarial audit findings after AHA completion.
- `packages/agent/docs/post-aha-adversarial-closeout-evidence-manifest.md`:
  companion evidence manifest for the post-AHA adversarial closeout campaign.
- `packages/agent/docs/hierarchical-rearchitecture-inventory.md`: HRA
  live-tree inventory summary and target architecture notes.
- `packages/agent/docs/hierarchical-rearchitecture-plan-summary.md`: in-repo
  summary of the operator HRA handoff plan and provenance boundary.
- `packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv`:
  machine-readable tracked-file inventory for the hierarchical rearchitecture
  campaign.
- `packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv`:
  machine-readable current ownership map for the hierarchical rearchitecture
  campaign.
- `packages/agent/docs/hierarchical-rearchitecture-ios-current-ownership-map.tsv`:
  HRA-8 source/test Swift current ownership map for the iOS hierarchy phases.
- `packages/agent/docs/hierarchical-rearchitecture-ios-project-map.md`:
  HRA-8 XcodeGen, ShareExtension, SourceGuard, and iOS phase-ownership map.
- `packages/agent/tests/primitive_engine_teardown_plan_invariants.rs`:
  absence, traceability, schema, registration, and documentation gates for the
  primitive branch.
- `packages/agent/tests/determinism_replayability_invariants.rs`: completed DRC
  gates for scorecard state, replay source inventory, entropy scan coverage,
  provider request audit wiring, replay manifest hashing, stable ordering,
  cross-record replay references, offline roundtrip proof, docs parity, and
  closeout.
- `packages/agent/tests/primitive_code_cleanup_invariants.rs`: cleanup
  scorecard, folder-justification, file-budget, deleted-term, and tracked-junk
  gates.
- `packages/agent/tests/hierarchical_rearchitecture_invariants.rs`: completed
  hierarchy scorecard, inventory, path-shape, broad-bucket, mirrored-test, and
  large-file-budget gates.
- `packages/agent/tests/post_hra_adversarial_hardening_invariants.rs`: completed
  post-HRA adversarial hardening gates for source identity, deleted-doc
  residue, CI parity, Rust ownership, iOS transport, inventory, and provenance.
- `packages/agent/tests/post_aha_adversarial_closeout_invariants.rs`: completed
  post-AHA closeout gates for Mac project policy, docs/runtime parity, Mac/iOS
  ownership, Rust docs/budgets, CI parity, provenance, privacy, and residue.
- `packages/agent/tests/true_primitive_cleanup_invariants.rs`: completed TPC
  scorecard, evidence, initial red-finding, and tracked-source setup gates.
- `packages/agent/tests/true_modularity_boundary_invariants.rs`: completed TMB
  scorecard, boundary inventory, responder, facade, domain, storage, transport,
  iOS engine-access, boundary-error, and final closeout gates.
- `packages/agent/tests/failure_semantics_invariants.rs`: completed FSC scorecard,
  inventory, failure-surface, canonical-envelope, event-emission, transport,
  provider, iOS parity, replay, and closeout gates.
- `packages/agent/tests/state_ownership_lifecycle_invariants.rs`: completed SOL
  scorecard, inventory, stateful-marker coverage, runtime task lifecycle,
  iOS local-state classification, owner-private settings/auth writes, and final
  closeout gates, with focused modules under
  `packages/agent/tests/state_ownership_lifecycle/`.
- `packages/agent/tests/observability_diagnostics_auditability_invariants.rs`:
  completed ODA scorecard, evidence, inventory, source guard, logs filter,
  diagnostics bundle, provider audit, runtime decision, CLI/dev UX, and final
  closeout gates, with focused modules under
  `packages/agent/tests/observability_diagnostics_auditability/`.
- `packages/agent/tests/concurrency_scheduling_discipline_invariants.rs`:
  completed CSD scorecard, inventory, scheduling-marker coverage, spawn/task
  ownership, bounded channel/stream, Swift banned-pattern, stored-task
  cancellation, timer/deadline, blocking-isolation, and closeout gates, with
  focused modules under `packages/agent/tests/concurrency_scheduling_discipline/`.
- `packages/agent/tests/security_authority_capability_boundaries_invariants.rs`:
  completed SACB scorecard, inventory, CI wiring, and security boundary gates, with
  focused modules under
  `packages/agent/tests/security_authority_capability_boundaries/`.
- `packages/agent/tests/off_plan_saa_authorship_teardown_cleanup_invariants.rs`:
  cleanup scorecard, evidence, inventory, provider execute narrowing,
  memory/rule removal, static target, README, and predecessor-inventory gates.
- `packages/agent/tests/data_integrity_storage_evolution_migration_discipline_invariants.rs`:
  completed Data Integrity Storage Evolution Migration Discipline gates for
  scorecard/evidence, inventory coverage, README/CI wiring, storage source
  contracts, negative corruption guards, and final closeout claims.
- `packages/agent/tests/public_protocol_api_contract_discipline_invariants.rs`:
  completed Public Protocol API Contract Discipline gates for scorecard/evidence,
  inventory coverage, README/CI wiring, public `/engine` method/schema shape,
  iOS context/decoder narrowness, predecessor inventory rows, and final closeout
  claims.
- `packages/agent/tests/provider_model_boundary_discipline_invariants.rs`:
  completed Provider / Model Boundary Discipline gates for scorecard/evidence,
  inventory coverage, README/CI wiring, provider-native import confinement,
  provider wire marker confinement, provider audit redaction/bounding, retry and
  failure redaction, provider family test anchors, and predecessor inventory rows.
- `packages/agent/tests/performance_resource_governance_invariants.rs`:
  completed Performance / Resource Governance gates for scorecard/evidence,
  resource inventory coverage, README/CI wiring, queue burst and payload
  rejection, stream/frame/accumulator/WebSocket bounds, cancellation, shutdown,
  retention, startup, runtime/iOS boundary, and predecessor inventory rows.
- `packages/agent/tests/configuration_profile_environment_discipline_invariants.rs`:
  completed CPE gates for scorecard/evidence, inventory coverage, default drift,
  strict schema, sparse overlay, env ownership, iOS settings parity, Mac sparse
  seed, README/CI wiring, and predecessor inventory rows.
- `packages/agent/tests/release_install_upgrade_rollback_discipline_invariants.rs`:
  completed RIURD gates for scorecard/evidence, inventory coverage, port/process
  ownership, hidden deploy absence, setup/install/uninstall preservation,
  fail-closed deploy/rollback, generated project policy, README/CI wiring, and
  predecessor inventory rows.
- `packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs`:
  completed IOSTC gates for scorecard/evidence, inventory coverage, README/CI
  wiring, deleted iOS product panels, successor/server-ownership residue,
  settings parity references, generated project policy, focused simulator
  evidence, and predecessor inventory rows.
- `packages/agent/tests/developer_experience_repo_hygiene_automation_invariants.rs`:
  completed DXRHA gates for scorecard/evidence, inventory coverage, local and
  GitHub static-gate parity, generated/ignored artifact policy, setup/dev
  runtime-state docs, version/release helper checks, branch handoff, and
  predecessor inventory rows.
- `packages/agent/tests/documentation_evidence_scorecard_integrity_invariants.rs`:
  completed DESI gates for active scorecard/evidence/inventory integrity,
  present-tense docs, command provenance, predecessor inventory coverage,
  local/GitHub closeout target parity, stale branch quarantine, and final
  closeout proof.
- `packages/agent/tests/self_sufficient_agent_runtime_readiness_invariants.rs`:
  completed SSARR gates for readiness scorecard/evidence/inventory integrity,
  successor-term classification, negative generated-worker/learned-memory/tool
  synthesis guards, local/GitHub target parity, README wiring, stale branch
  quarantine, and final closeout proof.
- `packages/agent/tests/primitive_minimality_closure_invariants.rs`:
  completed PMC gates for minimality scorecard/evidence/inventory integrity,
  deleted provider helper absence, retained-contract classification,
  local/GitHub target parity, README wiring, predecessor inventory rows, and
  no public protocol/iOS behavior expansion.
- `packages/agent/tests/baseline_pre_restoration_closure_invariants.rs`:
  completed BPRC gates for pre-restoration scorecard/evidence/inventory
  integrity, iii-style worker/function/trigger alignment, restoration backlog
  coverage, active-doc current-baseline wording, old product-surface absence,
  provider-visible execute minimality, and local/GitHub target parity.
- `packages/agent/tests/self_updating_worker_runtime_foundation_invariants.rs`:
  completed SUWRF gates for scorecard/evidence/inventory integrity, package
  lifecycle separation from `/engine/workers`, worker resource-kind coverage,
  provider-visible execute minimality, local/GitHub target parity, and no fixed
  product-panel restoration.
- `packages/agent/tests/ios_self_adapting_agent_cockpit_baseline_invariants.rs`:
  completed IOSAC gates for cockpit scorecard/evidence/inventory integrity,
  worker lifecycle client function ids, dynamic `ui_surface` rendering,
  protocol/repository boundaries, neutral glass theme tokens, focused Swift
  test coverage, README/iOS docs, and local/GitHub static-gate parity. Phase 2
  catalog discovery coverage is recorded in the P2AER inventory/evidence.
- `packages/agent/tests/ios_affordance_restoration_map_invariants.rs`:
  completed IARM gates for old iOS tree coverage, affordance classification
  vocabulary, Phase 1 review queue, Phase 2 deferral anchor, README/iOS docs,
  and local/GitHub static-gate parity.
- `packages/ios-app/docs/architecture.md`: iOS thin-client architecture.
- `packages/mac-app/docs/architecture.md`: Mac wrapper architecture.

Historical scorecard artifacts are retained as evidence only; live architecture
guidance is owned by the current README, package docs, source module docs, and
the completed HRA/AHA/PCC/TPC/TMB/DRC/FSC/SOL/CSD/SACB/ODA/DSEMD/PPACD/PMBD/PERF/CPE/RIURD/IOSTC/DXRHA/DESI/SSARR
scorecards, the PMC and BPRC closure scorecards, the SUWRF foundation
scorecard, the IOSAC cockpit baseline scorecard, the IARM restoration map
scorecard, and the OPSAA cleanup scorecard.

Capability-backed truth means durable facts that affect agents or operators are
owned by resources, decisions, evidence, invocations, grants, queues, leases, or
generated UI resources; domain-owned hidden files or tables are acceptable only
as explicitly documented low-level cache/substrate boundaries with static gates,
and they are not policy, lineage, or product truth.

---

## Repository Structure

```
tron/
+-- VERSION.env             Canonical release version + Apple build source of truth
+-- packages/
|   +-- agent/              Rust agent server (single `tron` crate, modular layout)
|   +-- ios-app/            SwiftUI iOS application
|   +-- mac-app/            SwiftUI Mac menu-bar wrapper (Tron.app) — install wizard + server lifecycle
+-- scripts/
|   +-- tron                CLI dispatcher for build, manual deploy, service management
|   +-- tron.d/             Workspace CLI command-family modules
|   +-- tron-version        Version print/check/sync helper used by CI + releases
|   +-- tron-release-notes  Deterministic tagged-release changelog generator
|   +-- tron-lib.sh         Shared bash configuration and module loader
|   +-- tron-lib.d/         Runtime CLI service/log/auth/bundle modules
|   +-- tron-cli            Contributor CLI helper for local service management
|   +-- tron-ios-beta       Local physical-device build/install/stop helper for iOS app variants
|   +-- benchmarks/         Performance benchmark runner and baselines
|   +-- asc-jwt             Local App Store Connect JWT helper
|   +-- install-hooks.sh    Installs repo-managed commit hooks
|   +-- personal-info-guard.sh
|   +-- reset-db            Local database reset helper
+-- .github/
|   +-- workflows/          CI + Mac/iOS release pipelines
|   +-- ISSUE_TEMPLATE/     Structured bug/feature report forms
|   +-- dependabot.yml      Weekly Cargo + GitHub Actions updates, monthly Swift
|   +-- pull_request_template.md
```

---

## Rust Modules

The agent is a single `tron` crate (see `packages/agent/Cargo.toml`). The crate tree now mirrors the pure engine model: app/bootstrap, thin transports, the engine fabric, worker-owned domains, platform integrations, and shared foundation/protocol helpers. Dependencies flow inward: transports build engine requests, domains own behavior, and the engine owns policy/ledger/streams/queues/workers.

```
app/
├── cli/          CLI parsing and auth subcommand dispatch
├── bootstrap/    Runtime assembly, database open, service wiring, server bind
├── health/       Health, deep-health, disk checks, and metrics
└── lifecycle/    Onboarding, bearer-token state, and shutdown coordination
transport/
├── http/         HTTP-adjacent auth helpers
├── engine/       /engine contracts, request routing, socket session, stream cursors
└── runtime/      Runtime services, external-worker socket, stream projection, setup
engine/
├── authority/    Grants, leases, and compensation audit records
├── catalog/      Discovery, capability client, live registry, catalog changes
├── durability/   Ledger, queue, resources, state, streams, and SQLite codecs
├── invocation/   Invocation model, host, handles, dispatch, idempotency flow
├── kernel/       IDs, errors, policy, schemas, and core catalog type contracts
├── primitives/   Model-facing primitive worker definitions and handlers
├── runtime/      External-worker runtime, worker protocol, trigger runtime
└── tests/        Subsystem-mirrored engine tests and shared fixtures
domains/          Worker-owned behavior slices, contracts, services, and tests
platform/         OS/vendor integrations retained by the primitive loop
shared/
├── foundation/   Constants, IDs, paths, profiles, retry/text helpers, shared errors
├── protocol/     Content, events, memory, messages, and model capability DTOs
├── server/       Runtime context, validation, params, and capability errors
├── storage/      Unified SQLite storage helpers
└── observability/ tracing subscriber and SQLite log transport
main.rs           Thin binary entry point
```

| Module | Purpose | Key Types |
|--------|---------|-----------|
| `app` | CLI, startup/bootstrap, health, metrics, onboarding, and shutdown | `Cli`, `TronServer`, `ServerConfig`, `ShutdownCoordinator` |
| `transport` | Thin protocol surfaces over the engine envelope | `EngineTransportRequest`, `run_engine_ws_session`, `BearerTokenStore` |
| `engine` | Live capability fabric, primitive workers, local worker protocol, typed resource kernel | `LiveCatalog`, `EngineHostHandle`, `FunctionDefinition`, `WorkerDefinition`, `Invocation`, `InvocationRecord`, `EngineResource`, `EngineResourceTypeDefinition` |
| `domains` | Worker-owned Tron behavior and implementation code, including the collapsed capability harness and the post-baseline worker lifecycle owner | `DomainRegistrationContext`, `DomainWorkerModule`, per-domain contracts/deps/handlers |
| `platform` | OS/vendor integrations | paired-device broker |
| `shared` | Foundation vocabulary, protocol DTOs, server context/errors, observability, and neutral storage helpers | `Message`, `TronError`, `StreamEvent`, `SessionId`, `StorageRuntime`, `ServerRuntimeContext`, `CapabilityError` |

The domain package is intentionally vertical. A domain root is only docs,
exports, and crate-private worker registration. Shared worker registration
types live in `domains::registration::worker`; transport setup enters the
crate-private startup aggregator in `domains::registration`, which iterates
each domain's `worker_module(...)`.
`contract.rs` owns canonical function ids, schemas, authority, risk, and stream
topics; each domain then keeps executable bodies under behavior owners rather
than a shared boilerplate shape. Examples: `domains/agent/prompt`,
`domains/agent/loop`, `domains/agent/context`, `domains/auth/oauth`,
`domains/auth/credentials`, `domains/filesystem`, `domains/model/routing`,
`domains/model/protocol`, and `domains/session/lifecycle`,
`domains/session/query`, `domains/session/reconstruction`. Runtime support is
split the same way in domain-owned folders such as `domains/agent/runtime/*`,
`domains/session/event_store/*`, and
`domains/agent/loop/primitive_surface.rs`. Provider-native stream/function-call
argument parsing and provider-specific invocation id remapping are isolated
under `domains/model/protocol/*` before canonical capability history reaches
the loop, ledger, audit, or iOS DTO layers.
`domains/model/responder` is the non-provider composition boundary: it builds
provider-neutral stream options, opens provider streams, applies retry, maps
provider errors to canonical failure envelopes, and redacts/bounds
`model.provider_request` audit payloads before persistence.
`domains/approval` owns durable `approval_request` and `approval_decision`
resources plus the reusable fail-closed freshness check consumed by future tool
packages. Approval evidence is never an authority grant; existing engine
authority grants remain the execution-permission primitive.
`domains/memory` owns the Phase 2 memory foundation: source-backed memory
engine/policy/record/prompt-trace/eval-run/migration resource contracts,
explicit disabled/active/shadow/compare policy state, redacted record audit, and
provider-safe prompt trace text. Memory policy resolves by session, then
workspace, then system scope; prompt-trace audit writes use trace-specific
idempotency so later turns do not replay stale memory status. Retained
`bodyRef` payloads are pointer-only and reject inline body-like keys at any
nested depth on retain, edit, and migration import. Direct
record-id operations fail closed when the addressed resource is outside the
caller memory scope. It does not implement semantic retrieval, embeddings,
ranking, summarization, procedural rules, or automatic prompt memory.
`domains/filesystem` owns two separate surfaces: the iOS workspace-browser
functions for home/list/create-dir selection and the Phase 2 agent filesystem
toolbox. Agent operations resolve only from trusted working-directory metadata,
deny traversal and symlink escapes, bound read/search/diff output, omit binary
content bodies, return provider-visible paths relative to the authorized root,
and record mutating previews/commits as patch proposal and materialized-file
resources.
`domains/worker_lifecycle` owns local package proposals,
`tron.worker_package.v1` manifest validation, install/enable/disable/launch/
stop/retire functions, verified source-tree package digests, scoped token
minting, conformance reports, and `worker_package` resource/event evidence.
It is host lifecycle infrastructure, not a provider-visible toolbox, and it
does not add fixed iOS product panels.
`domains/goals` owns the accepted Slice 7A backend foundation for durable
goal, user-question, and answer provenance records. It uses existing engine
resources, streams, traces, replay refs, and the execute idempotency ledger; it
does not run autonomous goals, plan task decomposition, schedule reminders,
launch subagents, create notification inboxes, or add native Work/question UI.
`stream.rs` publishes only that domain's declared topics. Cross-domain access
goes through explicit domain services or shared DTOs, so an engineer can follow
a capability by reading one domain folder instead of a central dispatch table.

Rust tests mirror the production owners. Root `packages/agent/tests` contains
only cross-crate integration/static gates, while engine unit tests live under
`engine/tests/{authority,catalog,durability,invocation,kernel,runtime}` with
shared fixtures isolated in `engine/tests/fixtures`.

---

## Quick Start

### End Users (recommended)

1. Install [Tailscale](https://tailscale.com) and sign in on the Mac that will host the agent.
2. Download the latest `tron-v*.dmg` from the configured GitHub Releases page and drag `Tron.app` into `/Applications`.
3. Launch `Tron.app`. The wizard handles Tailscale detection, required permissions, server install, and the iOS handoff.
4. On iPhone, scan the wizard's Tron iOS Beta QR code to open the public TestFlight invite, install the latest available Tron beta, then scan the Mac pairing QR or enter the pairing fields manually.

The wizard and menu bar surface runtime actions such as pairing info, logs, feedback, restart, pause, resume, and uninstall — you never need the CLI unless you want to.

### Contributors (build from source)

Prerequisites:

- **Rust**: `rustup` + `cargo` (stable toolchain)
- **Xcode 26+** for the iOS app; **Xcode 16+** for the Mac app
- **XcodeGen**: `brew install xcodegen`

First-time setup:

```bash
./scripts/tron setup       # Check prerequisites, build, create ~/.tron/
./scripts/tron login       # Authenticate with Claude (OAuth browser flow)
```

Build and run:

```bash
# Build the server
cd packages/agent
cargo build --release

# Development mode (foreground, auto-rebuild)
./scripts/tron dev

# Or install as launchd service
./scripts/tron install
```

iOS app:

```bash
cd packages/ios-app
brew install xcodegen
xcodegen generate
open TronMobile.xcodeproj
```

Mac app wrapper (optional; for DMG development):

```bash
cd packages/mac-app
xcodegen generate
open TronMac.xcodeproj
```

Build with the `Tron` scheme for optimized production builds, `Tron Fast` for
debug-speed builds that install over the production app, or `Tron Beta` for the
side-by-side beta variant. The app starts without a server until the user pairs
a Mac through onboarding.

Codex app local actions are checked in under
`.codex/environments/environment.toml`. Open this project root in the Codex app
to get toolbar actions for starting `scripts/tron dev -bdt`, stopping the dev
server with `scripts/tron dev --stop`, and clear physical-device iOS actions.
`Rebuild + Install + Launch ...` actions call `scripts/tron-ios-beta install`,
which regenerates the Xcode project, builds current source, installs the fresh
app bundle, and launches it. `Just Launch Installed ...` actions call
`scripts/tron-ios-beta launch`, so they only open the app that is already on
the device.
The install helper installs the requested configuration's `iphoneos` product, so
production actions do not accidentally launch a stale Beta or ProdDebug build
from DerivedData. Production rebuild actions call `install`, not `launch`, so
source changes are built into the app before it is installed and post-install
launched.
The iPhone environments are Beta (`Tron Beta`/`Beta`), Prod Fast (`Tron
Fast`/`ProdDebug`), and Prod Release (`Tron`/`Prod`). Because the two
production builds share `com.tron.mobile`, there is one deduplicated production
just-launch action; it opens whichever production-bundle binary is currently
installed. iPad currently has Beta rebuild/install/launch and just-launch
actions.
The iOS actions pass generic `TRON_IOS_DEVICE_NAME=iPhone` or
`TRON_IOS_DEVICE_NAME=iPad` selectors so the repo does not store personal device
details. Post-install launch is bounded by the helper's launch timeout so a
stuck `devicectl` launch exits cleanly. The matching launch action relaunches
the already-installed app without rebuilding.

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, TDD expectations, and release workflows.

---

## CLI Reference

The `scripts/tron` CLI manages workspace development and contributor service workflows. The dispatch table is at the bottom of `scripts/tron` (the `case "$1" in` block); command-family bodies live in `scripts/tron.d/`, while runtime service/log/auth/bundle helpers loaded by both `scripts/tron` and the installed `tron-cli` live in `scripts/tron-lib.d/`. When adding or renaming a subcommand, update the dispatcher and the owning module together.

### Development (workspace only)

| Command | Description |
|---------|-------------|
| `tron dev` | Start the dev-profile server in the foreground (`-b` build first, `-t` test first, `-d` launchd-backed background takeover). Stops the installed `com.tron.server` job before binding port `9847`, defaults dev logging to `RUST_LOG=info,ort=error` unless the caller already set `RUST_LOG`, waits up to 30 seconds for `/health` in background mode by default, writes startup/exit output to `~/.tron/internal/run/tron-dev-background.log`, and restores the installed helper through `/Applications/Tron.app` on exit/stop only after `/health` passes. Agent automation should use `tron dev -bd --json --wait <seconds>` so the final stdout object reports the actual listener PID and health state. |
| `tron ci` | CI checks: any subset of `fmt`, `check`, `clippy`, `test`, `bench`, `doc`; the `test` step runs serial lib/bin tests, closeout invariant targets, primitive trace, database-path, and serial integration targets |
| `tron bench` | Performance benchmarks (`run`, `bless`, `compare`) |
| `tron version` | Central release version helper (`print`, `check`, `sync`, `bump`). `VERSION.env` is the only hand-edited release identity source; platform files are generated mirrors. |
| `tron setup` | First-time project setup |

### Manual Deployment (workspace only)

| Command | Description |
|---------|-------------|
| `tron preflight` | Pre-deploy infrastructure check |
| `tron manual-deploy` | Manual contributor deploy: build, test, swap binary, restart, health-check, and fail-closed rollback (`--force` skips confirms; `--ci` is non-interactive). `deployed-commit` and the restart sentinel advance only after `/health` passes. No automatic deploy watcher or shorter deploy alias is retained. |
| `tron install` | Contributor-only shell install for workspace testing. The distributed Mac app does not call this; real installs use `/Applications/Tron.app` + `SMAppService`. |
| `tron uninstall [--reset-settings] [--reset-credentials]` | Remove launchd service/runtime bundles and reset Mac onboarding. Preserves the database and workspace; optional flags remove `profiles/user/profile.toml` settings overrides and/or `profiles/auth.json`. |

### Runtime

| Command | Description |
|---------|-------------|
| `tron start` | Start `com.tron.server`. When `/Applications/Tron.app` is installed, this enters the wrapper's `--tron-start-server-and-quit` path so `SMAppService` owns production registration and success is reported only after `/health` passes; the older contributor `~/Library/LaunchAgents` path is used only when no installed Release wrapper is available. |
| `tron stop` | Stop the service |
| `tron restart` | Stop and start the service through the same health-gated path as `tron start`. |
| `tron status` | Show service/dev-takeover status, PID, port, health, uptime, and stale dev pid-file diagnostics. Use `tron status --json` for deterministic automation. |
| `tron rollback` | Restore the previous binary from backup (`--yes` skips confirm); success requires the restored helper to pass `/health` |
| `tron login` | Authenticate with a provider (`--label <name>` for multi-account) |
| `tron auth rotate` | Rotate the WebSocket bearer token (forces every paired iOS device to pair again) |
| `tron logs` | Query unified `~/.tron/internal/database/tron.sqlite` logs with bounded level/search/session/workspace/trace filters (`-h` for options; `--json` emits machine-readable rows with session/workspace/trace IDs) |
| `tron errors` | Show recent errors |

### Build Profiles

```bash
cd packages/agent
cargo check                        # Fast correctness check (no binary)
cargo build --profile dev-server   # Dev server (thin LTO, fast iteration)
cargo build --release              # Production (fat LTO, maximum optimization)
cargo test                         # Run the full test suite
cargo clippy --workspace --all-targets # Lint with Cargo.toml policy
```

---

## Capabilities

The current restoration baseline keeps the server-side model surface collapsed
to one provider-visible function while restored backend capabilities enter as
operation values behind that single `execute` provider surface:

| Provider tool | Engine function | Purpose |
|---------------|-----------------|---------|
| `execute` | `capability::execute` | Run one primitive host operation and return a bounded observation/result to the turn loop. |

`capability::execute` is a direct primitive operation endpoint. Its request
schema requires an `operation` field and accepts only operation-specific
primitive fields such as `input`, `scope`, `namespace`, `key`, `value`,
`path`, `content`, `command`, `traceId`, `traceRecordId`, `limit`,
`timeoutMs`, `maxOutputBytes`, `jobResourceId`, `state`, `cleanupAfterSeconds`,
`goalResourceId`, `questionResourceId`, `objective`, `prompt`, `answerText`,
`expectedQuestionVersionId`, `expiresAt`, `allowFreeForm`, `successCriteria`,
`constraints`, `queueRefs`, `planRefs`, `evidenceRefs`, `kind`, `id`, catalog search filters,
`idempotencyKey`, and `reason`.
Agent-launched `execute` invocations carry provider type, provider call id,
run/turn ids, canonical working directory, and trace parentage as trusted engine
runtime metadata under a per-call derived authority grant. The child grant is
scoped to the exact primitive function, no
namespace authority, state read/write support, and `networkPolicy: none`; the
worker rejects bootstrap grants, public caller contexts, and system-scoped
state. File and process operations additionally require trusted working
directory metadata before resolving paths. Trace records use those trusted facts
directly instead of inferring provider ownership from model id strings.
`replay_manifest` is the read-only exception: it returns the current session
replay manifest without creating a trace record, so the read does not mutate
the manifest it exports.

Agent backend observability is native to this primitive surface. Prompt runs,
turns, provider requests, streaming, capability invocation waves, and primitive
`execute` operations emit structured logs with `component` and `agent_event`
fields such as `agent.runtime`, `agent.loop`, `agent.turn`, `agent.provider`,
`agent.stream`, `agent.capability`, and `agent.execute`. INFO logs mark durable
lifecycle boundaries and include session/workspace/run/turn/trace/invocation
IDs where available. TRACE logs add high-volume sequencing and size metadata for
stream deltas and argument deltas without logging prompt text, generated text,
tool arguments, or file content. The SQLite log transport redacts known
credential/token patterns from server-side messages, structured data, and error
fields before persistence, but call sites still treat logs as lifecycle metadata
rather than content storage. Authorized content and effect evidence remain in
session events, trace records, blobs, resources, provider audits, and replay
manifests; retained logs are the searchable agent/backend trace that points back
to those canonical artifacts.

Current primitive operations:

| Operation | Effect |
|-----------|--------|
| `observe` | Record text as an assistant-visible observation. |
| `state_get` | Read an agent-owned state value. |
| `state_set` | Write an agent-owned state value. |
| `state_list` | List agent-owned state entries for a scope/namespace. |
| `filesystem_read` | Read a bounded text preview under the trusted working-directory root; binary content bodies are omitted. |
| `filesystem_list` | List bounded directory entries under the trusted working-directory root. |
| `filesystem_find` | Walk bounded entries matching a simple name/path pattern without following symlinks. |
| `filesystem_glob` | Walk bounded entries matching a glob-style pattern without following symlinks. |
| `filesystem_search_text` | Search bounded UTF-8 file previews under the trusted root while skipping binary content. |
| `filesystem_diff` | Produce a bounded preview diff between current file content and proposed text. |
| `filesystem_write` | Create a patch proposal by default, or commit UTF-8 content with idempotency and a verifiable expected hash for existing files. |
| `filesystem_edit` | Apply an exact single text replacement as preview or commit with patch/resource evidence; truncated file previews are refused. |
| `filesystem_apply_patch` | Alias the exact-text patch flow for provider-facing patch operations; truncated file previews are refused. |
| `git_status` | Inspect trusted-root repository state: branch or detached HEAD, upstream/ahead-behind, dirty summaries, and bounded porcelain evidence. |
| `git_diff` | Return bounded staged and unstaged diff evidence plus read-only repository dirty summaries without invoking external diff/textconv helpers. |
| `git_branch_inventory` | Return bounded read-only local branch inventory evidence: current/detached state, sorted local branch refs, OIDs, upstream/ahead-behind when locally available, and last-commit metadata. |
| `git_stage` | Stage one explicit relative path into the Git index after idempotency, reason, expected-HEAD, trusted-root, and conflict checks; records bounded before/after evidence. |
| `git_unstage` | Remove one explicit relative path from the Git index after idempotency, reason, expected-HEAD, trusted-root, and conflict checks; records bounded before/after evidence. |
| `git_commit` | Accepted Slice 6C operation that creates one guarded single-parent commit from the already-staged index on the current named branch after idempotency, reason, expected-HEAD, and expected-index-tree checks; records commit resource and stream evidence. |
| `git_branch_start` | Slice 6D operation that creates one new local branch at `expectedHead`, moves symbolic `HEAD` to it after a guarded ref/OID check without checkout, preserves index/worktree content, and records branch-start resource and stream evidence. |
| `process_run` | Run a bounded local shell command with timeout, output limits, and fail-closed no-network enforcement. |
| `job_start` | Start a non-interactive local command as a durable `job_process` resource with bounded output, lifecycle stream evidence, and fail-closed `networkPolicy: none`. |
| `job_status` | Inspect one durable `job_process` resource in the current session scope. |
| `job_list` | List durable `job_process` resources in the current session scope, optionally filtered by lifecycle state. |
| `job_log` | Read bounded stdout/stderr previews and output-resource refs for one durable job. |
| `job_cancel` | Request cancellation for a running durable job; runtime finalization records terminal cancellation with bounded output evidence after signalling the owned process group. |
| `goal_create` | Create a scoped durable `goal` record with bounded objective, owner/scope, queue/plan/evidence refs, trace/replay refs, lifecycle state, and resource evidence. |
| `goal_list` | List scoped goal records with bounded summaries and explicit truncation metadata. |
| `goal_inspect` | Inspect one scoped goal record with current resource/version refs and lifecycle evidence. |
| `goal_cancel` | Cancel one nonterminal goal idempotently with required reason, lifecycle stream evidence, and resource-version freshness. |
| `question_create` | Create a scoped durable `user_question` record, optionally associated with a goal, with prompt/options/free-form/expiry and trace/replay evidence. |
| `question_list` | List scoped user questions with bounded summaries and explicit truncation metadata. |
| `question_inspect` | Inspect one scoped user question with current resource/version refs, lifecycle state, and answer summary when present. |
| `question_answer` | Record one idempotent `goal_answer` handoff for a pending question after expected-version and expiry checks, with required reason, authority/freshness evidence, stream refs, and no authority minting. |
| `web_fetch` | Fetch one explicit URL as bounded source provenance after declared network authority checks, producing redacted `web_source` resource/cache evidence with readable HTML/XHTML text extraction when applicable. |
| `web_source_list` | List current-session `web_source` records as bounded citation-ready summaries without network access. |
| `web_source_inspect` | Inspect one current-session `web_source` resource/version as bounded citation-ready source metadata and redacted snippet evidence without network access. |
| `trace_list` | List durable Agent Trace-style records for the current session, optionally filtered by trace id. |
| `trace_get` | Read one durable trace record by id within the current session. |
| `log_recent` | Read bounded recent log evidence, optionally filtered by trace id, through the same `execute` primitive. |
| `memory_status` | Read the current session memory policy/mode, active engine identity, and prompt-inclusion contract with explicit disabled fallback. |
| `memory_list` | List redacted memory records for the current session; record body refs stay redacted. |
| `memory_inspect` | Inspect one redacted memory record and its version history within the current session. |
| `replay_manifest` | Export the current session's canonical `tron.replay.v1` replay manifest, including replay hashes and cross-record references, without provider/tool/process/file/resource side effects. |
| `catalog_search` | Inspect visible workers, functions, schemas, health, protected omission counts, runtime surfaces, and report evidence without invoking catalog targets. |
| `catalog_inspect` | Inspect one visible function, worker, trigger type, or trigger definition with schema/conformance hints and no target execution. |
| `catalog_conformance` | Create an idempotent, resource-backed `catalog_discovery_report` plus stream evidence for visible catalog conformance and protected omission checks. |

Legacy `file_read` and `file_write` operation names are not part of the
provider-visible execute surface; file access goes through the hardened
`filesystem_*` operation package.

The accepted startup-registration baseline keeps only loop infrastructure domains:
`system`, `capability`, `catalog_discovery`, `approval`, `memory`, `jobs`, `filesystem`, `blob`, `message`,
`settings`, `auth`, `agent`, `logs`, `session`, `transcription`,
`worker_lifecycle`, `web`, and model-provider modules. The
`filesystem` domain is deliberately split: workspace-browser functions remain
limited to `filesystem::get_home`, `filesystem::list_dir`, and
`filesystem::create_dir`, while agent-facing read/list/find/glob/search/diff/
write/edit/apply-patch behavior is exposed only as `capability::execute`
operation values with trusted root checks and resource-backed mutation
evidence. The `approval` domain is a backend evidence/freshness
gate with `approval::request`, `approval::decide`, and `approval::check`
engine functions; it does not add a provider-visible approval tool, native iOS
approval UI, or default risky-action policy. The post-baseline
`memory` domain is a backend contract/audit surface with `memory::status`,
`memory::configure_policy`, `memory::retain`, `memory::edit`,
`memory::tombstone`, `memory::list`, `memory::inspect`,
`memory::record_prompt_trace`, and migration import/export functions; the model
sees only read-only `execute` memory audit operations, and prompt assembly
receives only mode/count/trace facts, never retained memory body content.
The `jobs` domain owns durable non-interactive process lifecycle records:
`jobs::start`, `jobs::status`, `jobs::list`, `jobs::log`, `jobs::cancel`, and
`jobs::cleanup` create/update scoped `job_process` resources, bounded
`execution_output` resources, `jobs.lifecycle` stream rows, trace/replay refs,
process-group timeout/cancellation cleanup, terminal-state idempotency,
shutdown cancellation, and retention cleanup. Startup and lifecycle
read/cleanup reconciliation scans scoped running jobs internally so older
pre-startup stale records cannot be hidden behind a public list page of live or
post-startup rows; targeted status/log/cancel also rechecks the addressed
resource after scope validation without mutating unrelated scopes.
Provider-visible access remains the single `execute` tool through `job_*`
operation values; PTY sessions, interpreters, job-owned network behavior,
subagents, scheduling, native iOS process panels, and deployment behavior are
not part of this foundation.
The accepted Slice 7A `goals` domain owns durable backend records only.
Provider-visible access remains operation values behind the single
`capability::execute` primitive: `goal_create`, `goal_list`, `goal_inspect`,
`goal_cancel`, `question_create`, `question_list`, `question_inspect`, and
`question_answer`. Goal records use the generic `goal` resource kind with
bounded objective/success criteria/constraints, owner/scope, queue/plan/
evidence refs, lifecycle, trace refs, replay refs, and revisions. Question
records use `user_question` resources with pending/answered/expired/cancelled
lifecycle, prompt/options/free-form allowance, expiry, goal refs, trace/replay
refs, and answer summaries. Answers create `goal_answer` resources with the
question version they answered, answer text, required reason, actor,
authority/freshness evidence, idempotency details, trace/replay refs, and
bounded provider-visible refs. Answering requires a stable idempotency key and
`expectedQuestionVersionId`; stale, wrong-scope, expired, closed, malformed,
empty, oversized, missing-reason, or untrusted-context calls fail closed.
This foundation does not add an autonomous goal runner, planner, hidden prompt
queue, scheduler/reminder, notification/APNs behavior, subagents, public
`/engine` goal API expansion, settings fields, or native Work/question UI.
The accepted Slice 8A foundation adds the `web` domain as a source provenance
owner without adding direct public `web::*` catalog functions, and the accepted
Slice 8B foundation adds read-only source list/inspect operations for citation
assembly. Provider-visible access remains the single
`capability::execute` primitive with operation values `web_fetch`,
`web_source_list`, and `web_source_inspect`. Direct fetch requires a trusted
agent/system runtime context, current session, idempotency key, allowed
`web_source` write authority, and a derived grant with `networkPolicy:
declared`; grants with `networkPolicy: none` fail before any HTTP client is
built. The operation accepts one explicit URL, rejects
credentials, fragments, malformed or overlong URLs, unsupported schemes, and
unsafe local/internal targets except deterministic HTTP loopback test targets.
Fetches use `reqwest` with bounded timeout, redirects, captured response bytes,
provider-visible text bytes, content-type handling, deterministic truncation
metadata, captured-byte SHA-256 evidence, common secret redaction for previews
and error details, sanitized source/final URLs, replay refs, and idempotent
`web_source` resource/cache evidence on `web.lifecycle`. HTML/XHTML responses
derive bounded readable text before redaction/snippet generation, removing
script/style/noise blocks and recording extraction mode, extractor id/version,
safe title, extracted text bytes, and truncation metadata while preserving the
raw captured-byte SHA-256 as the durable source hash. `web_source_list` and
`web_source_inspect` require trusted current-session context plus `web.read`
and `resource.read` authority, inspect only scoped `web_source` resources, and
return bounded requested/final URLs, fetched time, status, content type,
captured SHA-256, byte/truncation/redaction/extraction metadata,
trace/replay refs, resource refs, and redacted snippets; they perform no
network I/O and remain valid under `networkPolicy: none`. Search providers,
browser automation, crawling, sitemap traversal, robots policy, login/cookies,
credential reuse, shell/process network side channels, native iOS web UI, and
public `/engine` web API expansion remain deferred to later slices.
The accepted Slice 6A read-only source-control foundation registers the `git`
domain with `git::status` and `git::diff` backend read contracts, while Slice
6B adds the narrow `git::stage` and `git::unstage` index-only write contracts.
Accepted Slice 6C adds the `git_commit` execute operation with backend
staged-index commit evidence; commit is not registered as a direct `git::*`
catalog function. Accepted Slice 6D adds the local-only
`git_branch_start` execute operation for creating one new local branch at the
current expected `HEAD` and moving symbolic `HEAD` to it after rechecking the
old symbolic ref and OID without checkout or file updates. Slice 6E adds the
read-only `git_branch_inventory` execute operation for bounded local branch
inventory evidence without branch mutation or remote access.
Provider-visible access remains operation values behind the single
`capability::execute` primitive: `git_status`, `git_diff`,
`git_branch_inventory`, `git_stage`, `git_unstage`, `git_commit`, and
`git_branch_start`. The implementation resolves only relative paths under
trusted working-directory metadata, rejects path traversal and worktree-root
escapes, reports branch/detached HEAD/upstream/ahead-behind/dirty summaries,
returns bounded status/diff and branch-inventory evidence, exposes the staged
index tree without writing repository tree objects, and requires idempotency
key, human/action reason, and expected HEAD for mutation. Successful stage/unstage
operations create `git_index_change` resources and publish `git.lifecycle`
stream evidence. Accepted Slice 6C `git_commit` creates exactly one single-parent commit
from the already-staged index on the current named branch after expected HEAD and
expected index tree freshness checks, rejects detached/conflicted/empty-index
and merge/sequencer states, rechecks the staged tree immediately before creating
the commit object, then advances the branch with a guarded `update-ref` compare
against the expected HEAD while symbolic `HEAD` is locked and reverified. The
`commit-tree` path does not invoke hooks or an editor and suppresses
pager/signing/credential prompts, creates a `git_commit` resource, and publishes
`git.commit_created` lifecycle evidence. Accepted Slice 6D `git_branch_start`
requires a safe new branch name, non-conflicted and sequencer-clean repository
state, trusted working-directory metadata, expected `HEAD`, reason, and explicit
idempotency. It creates a `git_branch_start` resource, publishes
`git.branch_started` lifecycle evidence, rejects detached HEAD, existing or
unsafe branch names, stale `expectedHead`, missing idempotency, nested/non-repo
misuse, and merge/rebase/cherry-pick/sequencer states, rolls back the newly
created branch ref if locked symbolic `HEAD` movement fails while it still
points at `expectedHead`, and proves checkout, hooks, remotes,
merge/rebase/reset, index mutation, and worktree file updates are not invoked.
Slice 6E `git_branch_inventory` enumerates only local `refs/heads/*`, reports
the current branch or detached HEAD, serializes sorted branch names/refs/OIDs,
computes ahead/behind only from already-present local upstream refs, retains
bounded last-commit metadata, keeps oversized metadata rows as truncated
evidence, and records explicit count/byte truncation metadata without adding a
durable resource kind.
Merges, rebases, resets, pushes, arbitrary branch checkout, branch
deletion/rename, conflict resolution
workflows, PR handoff, worktree graph resources, and native iOS SourceChanges
UI remain deferred.
Policy lookup is `session -> workspace -> system`, and prompt-trace audit
idempotency is keyed by trace so memory status can change across turns.
Direct record-id inspect/edit/tombstone operations reject cross-scope resources.
`worker_lifecycle` owner is the explicit exception for local package
proposal/apply/launch state. `transcription` is a local, opt-in composer
speech-to-text domain; composer voice input probes local model readiness before
recording, treats recording startup as cancellation-aware, cancels capture and
in-flight transcription when leaving chat, the server reports explicit
disabled/loading/ready/failed model state, and no media or voice notes are
stored. Product/tool domains such as
`process`, `program`, `worktree`, `browser`, `display`, `plan`,
`prompt_library`, `cron`, `mcp`, `skills`, `sandbox`, `self_extension`,
`worker`, `notifications`, `voice_notes`, and media/import surfaces are
not registered by default on this branch.

The agent namespace is prompt-loop infrastructure, not an extra model toolbox.
Public registered functions are limited to `agent::prompt`, `agent::abort`,
`agent::abort_invocation`, and `agent::status`. Hidden internal functions
`agent::prompt_apply` and `agent::run_turn` serialize accepted prompts into the
provider loop and keep session truth consistent.
Deleted product routes such as `agent::run_goal`, `agent::work_snapshot`,
`agent::ask_user`, `agent::spawn_subagent`, subagent status/result/cancel, and
public queue management are not registered.

The teardown scorecard is complete. Retained source is limited to the primitive
loop, generic shell, and evidence paths described here; deleted product routes
are not supported branch behavior.

## Engine Protocol API

Tron exposes one public client capability protocol: the authenticated `/engine`
WebSocket. Domain behavior is addressed only by live canonical
`namespace::function` capabilities discovered through the catalog and invoked
with engine protocol messages. Dotted domain method names are not registered.

### Connection

```
Engine clients:    GET /engine            ws://<host>:<port>/engine            Bearer-authenticated client capability protocol
Workers:           GET /engine/workers    ws://<host>:<port>/engine/workers    Loopback-only local engine workers
Health:            GET /health            http://<host>:<port>/health
Metrics:           GET /metrics           http://<host>:<port>/metrics
```

Engine protocol messages are JSON objects with a `type`, optional correlation
`id`, and camelCase fields:

```json
{"type":"hello","id":"h1","protocolVersion":1,"sessionId":"session-1"}
{"type":"invoke","id":"i1","functionId":"system::ping","payload":{"protocolVersion":1}}
{"type":"response","id":"i1","ok":true,"result":{"child":{"value":{"pong":true}}}}
```

`invoke` accepts only canonical function ids such as `system::ping`,
`agent::prompt`, or `settings::get`. Mutating calls must include an explicit
idempotency key. Message ids are correlation ids only.

Public clients cannot become the agent actor by invoking `capability::execute`
directly. Trusted agent runtime paths must use a derived least-privilege grant
and trusted working-directory runtime metadata; bootstrap grants are rejected by
the primitive worker. Public wire context does not accept `authorityScopes` or
`runtimeMetadata`; runtime metadata is reserved for trusted engine and
agent-owned execution paths. `execute` is the primitive operation boundary.

Hidden functions remain in the engine catalog for internal runtime effects such
as agent apply/run-turn and prompt-history capture. Normal discovery excludes
them and the public transport cannot invoke them directly.

The core request set is `hello`, `discover`, `inspect`, `watch`, `invoke`,
`promote`, `subscribe`, `poll`, `ack`, `heartbeat`, and `goodbye`. Every request
translates into an internal `EngineTransportRequest`, carrying actor,
authority, trace, scope, payload, and explicit idempotency.
Correlation ids are never command ids or idempotency keys. Stream clients should
persist delivered cursors locally and ACK the latest delivered cursor per
subscription, not every event in a burst; ACK responses use normal engine
backpressure so catch-up traffic does not become a socket-fatal overload.
Public `promote` is a user-owned `engine::promote` path, not a client-side catalog edit:
it requires a non-empty `idempotencyKey`, workspace/system authority, and
workspace context for workspace promotion. It is not a tool-synthesis or
generated-capability authoring API. Owner mismatch, idempotency, and invalid
visibility promotion failures return typed public error codes with structured
details.
Failed `/engine` responses expose the same canonical failure envelope used by
runtime events: stable `code`, `category`, sanitized `message`, `retryable`,
`recoverable`, `origin`, optional provider/model/status/error-type/retry-after
fields, safe `details`, and trace/session/invocation references when available.
The outer response keeps `traceId` for correlation; clients should prefer the
server envelope over local error-taxonomy inference whenever it is present.

`/engine/workers` is the local-first worker protocol. A worker performs a
versioned hello with `WorkerIdentity`, auth policy, registration mode, visibility
scope, heartbeat interval, and supported capability labels; then it registers
canonical function and trigger definitions with the same schema, authority,
effect/risk, idempotency, lease, compensation, visibility, and provenance
metadata as in-process domain workers. The hello must be loopback bearer
authenticated, register `WorkerKind::External`, bind session/workspace-visible
workers through the scoped token, and reference an active grant at the token
revision and policy hash. Namespace checks use exact segment/prefix matching,
not substring matching. Triggers must use the worker token grant and target
functions owned by the same accepted worker. Workers publish events by asking
the engine to invoke `stream::publish`; stream visibility, topic selectors, and
session/workspace scope are checked against the accepted token and connection.
There is no direct socket event bypass.

Volatile worker entries are removed on disconnect or missed heartbeat. Durable
local worker entries stay in the catalog but are marked unhealthy when the
worker disconnects, so invocation fails closed until the worker reconnects and
re-registers. On SQLite-backed server restart, durable external worker/function
definitions hydrate as stopped/unhealthy with no handler, so an unclean socket
loss cannot become an optimistic callable function. Worker
connect/register/disconnect/heartbeat-timeout events are stored on
`worker.lifecycle` through the stream primitive and are visible through retained
ledger/log records. Invocation
results are owned by the socket connection's pending invocation map; disconnects
and outbound backpressure drain or fail pending calls as worker transport
failures.

Agents do not receive a server-authored helper-launch loop. The retained
`/engine/workers` protocol is host infrastructure for already-running external
workers to register functions and triggers; it is not exported as a provider
tool. Model-created helper behavior must start as ordinary `execute` output,
agent-owned state, workspace files, or generic resources. If a future helper
needs to become a live worker, it must be introduced through explicit host
infrastructure rather than a checked-in product lifecycle.

`worker_lifecycle` is that explicit host infrastructure for local packages
under `workspace/workers`. A package change starts as an inert
`worker_package_proposal`, then a trusted non-bootstrap authority grant can
install a canonicalized local package only after the manifest `packageDigest`
matches a deterministic hash of every regular file under the source root,
enable it, launch it with an allowlisted environment and scoped
`TRON_WORKER_TOKEN_JSON`, conformance-check the live catalog, and record
`worker_package`, `worker_package_installation`, `worker_launch_attempt`, and
`worker_package_conformance_report` resources on `worker.lifecycle`. Stop
returns package/installation state to `enabled` for immediate relaunch, while
startup reconciliation runs before lifecycle requests and marks durable running
launch attempts `unhealthy` if process ownership was lost. A failed launch,
conformance mismatch, digest mismatch, or unowned stop is recorded or rejected
fail-closed. The
provider-visible model tool remains `execute`; package lifecycle operations are
engine capabilities invoked through the authenticated `/engine` protocol by
trusted host surfaces.

Engine substrate primitives provide host infrastructure behind the loop:
state, streams, queues, triggers, grants, generic resources, storage operations,
and bounded internal projections. They are not exported as model tools. The
agent-visible evidence path is `execute` with `trace_list`, `trace_get`,
`log_recent`, `replay_manifest`, `catalog_search`, `catalog_inspect`,
`catalog_conformance`, and the `job_*` lifecycle operations; trace operations read durable
`trace_records` emitted around effectful `execute` calls, while `log_recent`
reads bounded retained logs and `replay_manifest` reads the canonical replay
snapshot through the same single tool. Catalog discovery reads current
catalog/resource truth and writes only append-oriented `catalog_discovery_report`
evidence. Approval requests and decisions are generic resources with lifecycle
events on `approval.lifecycle`; replay/evidence explanations point back to
request, decision, trace, resource-selector, and replay refs for each approved,
denied, expired, pending, missing, malformed, stale, or scope-mismatch check
outcome. Durable jobs are generic `job_process` resources with bounded
`execution_output` artifacts and lifecycle events on `jobs.lifecycle`;
runtime cancellation first signals the owned process group and terminal
finalization then records bounded output evidence. If a nonterminal cancel
request wins the resource-version race, finalization reloads, preserves the
request metadata, and retries the terminal update so output refs stay attached.
Late cancel requests do not overwrite already-completed jobs. Goal/question
records are generic `goal`, `user_question`, and `goal_answer` resources with
lifecycle events on `goals.lifecycle`; answer handoff uses the execute
idempotency ledger and resource expected-version checks so replaying the same
answer key returns the same evidence without double-answering. The replay snapshot includes resolved
session events, provider request audits, trace records, engine idempotency
entries, engine invocations, engine stream rows, and engine queue rows. It adds
stable section hashes plus request/result/outcome/payload hashes where the
underlying durable rows carry replay-critical payloads or results.
Each trace record carries the causal trace id, invocation id, provider tool-call
id, session/workspace, turn, model id/provider, authority envelope, VCS revision
when available, result/error hashes, and file attribution with content hashes.
The retained substrate workers are covered by completed primitive cleanup,
state, scheduling, security, observability, storage, and resource-governance
scorecards.

Fixed helper-orchestration routes are not registered on the primitive teardown
branch. Any future parallel helper behavior must be created by the agent
through `execute` and recorded as agent-owned state or generic runtime
artifacts.

---

## Event System

The primitive branch event store uses an immutable, append-only log with **24 typed event variants**. Sessions remain tree-structured for forks, but the persisted event surface is limited to loop truth: session lifecycle, messages, provider request audits, provider streaming, primitive `execute` invocations, compaction/context boundaries, metadata, errors, and turn failure. Domain lifecycle streams such as `jobs.lifecycle`, `approval.lifecycle`, `git.lifecycle`, and `goals.lifecycle` live in the engine stream substrate, not in the transport-visible session event enum.

The event enum is generated by the `define_events!` macro in `packages/agent/src/domains/session/event_store/types/macros.rs`, invoked from `packages/agent/src/domains/session/event_store/types/generated.rs`. Transport-visible event DTOs and stream factories live under `packages/agent/src/shared/protocol/events/`. Adding a new event means editing `generated.rs` and adding a payload type only when the event is true loop infrastructure. Product events, fixed capability events, rules/skills/hooks, prompt queue events, worktree/repo events, push-token events, and config mutation events are intentionally absent on this branch.

Event-store ownership is folder-backed: `event_store/envelope`,
`event_store/factory`, `event_store/reconstruction`, `event_store/store`, and
`event_store/sqlite` expose normal Rust modules without `#[path]` aliases. The
high-level `EventStore` facade lives under `event_store/store/event_store`,
while SQLite repositories stay under `event_store/sqlite/repositories`.

### Event Categories

| Domain | Events |
|--------|--------|
| `session` | `session.start`, `session.end`, `session.fork` |
| `message` | `message.user`, `message.assistant`, `message.system`, `message.deleted` |
| `model` | `model.provider_request` |
| `capability` | `capability.invocation.started`, `capability.invocation.progress`, `capability.invocation.completed` |
| `stream` | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| `compact` | `compact.boundary`, `compact.summary_staging`; live `agent.compaction_started` / `agent.compaction` stream events show pre-turn compaction progress and terminal idle/failure state |
| `context` | `context.cleared` |
| `metadata` | `metadata.update`, `metadata.tag` |
| `error` | `error.agent`, `error.capability`, `error.provider` |
| `turn` | `turn.failed` |

`capability.invocation.started`, `capability.invocation.progress`, and
`capability.invocation.completed` are immutable primitive lifecycle labels for
model-requested `execute` calls. `completed` uses the canonical
`content`/`isError`/`duration` payload shape for both live and reconstructed
sessions. Failed capability completions preserve model-visible text and include
`details.failure`, the server-authored canonical failure envelope.
Active runtime/UI identity is primitive-execution native: payloads carry the
model-visible primitive name, invocation id, trace id, turn, operation
arguments, result content, error state, and duration. iOS renders active work
from those primitive fields and does not map deleted built-in names to
capability identity.
Live `agent.turn_failed` and `error` runtime events are emitted through
canonical server builders. New runtime emissions carry stable code/category,
retryability, recoverability, origin, and `details.failure`; provider-backed
failures also preserve provider/model/status/error-type semantics when known.
iOS decodes the same server-authored envelope through `CanonicalFailurePayload`
and prefers `details.failure` in live plugins, persisted projections, provider
error pills, session summaries, and capability error rows.

### Event Streaming

Runtime events are projected into neutral server event payloads and stored in
engine streams before `/engine` delivery:

```
TronAgent (run loop)  ->  EventEmitter  ->  Runtime event bus
                                                    |
EngineStreamEventPump  <------------------------------------------+
    |
    v
Engine stream (`events.session`, `catalog`, `jobs`, ...)
    |
    v
/engine subscriptions -> Per-connection WebSocket writers
```

Live `/engine` subscriptions are not history loaders. Session screens reconstruct
persisted history through `session::reconstruct`; their `events.session`
subscription then starts at the current topic tail and carries only future
records. Stateless stream polling and non-session catch-up remain explicit cursor
operations. Stream polling applies engine visibility before pagination, so a
session subscriber is never blocked behind older stream rows owned by unrelated
sessions.
`session::reconstruct` paginates with `beforeEventId` / `oldestEventId` event
IDs, not session-local sequence cursors. Forked sessions reconstruct from the
ordered ancestor chain ending at the child head so inherited parent history and
child events arrive in one server-authored timeline. `tree::get_ancestors`
returns resolved wire `events` for the same reason: clients inspect lineage
without maintaining a second tree-only event shape.
`session::replay_manifest` is a separate pure-read audit export. It returns
`format: "tron.replay.v1"` with resolved session events, provider request audit
events, trace records, `engineIdempotencyEntries`, engine invocation rows,
stream rows, queue rows, section hashes, and an overall `replayHash`.
Idempotency entries carry payload-fingerprint request hashes, outcome hashes,
and first/latest invocation refs; invocation, stream, and queue projections add
`resultHash` or `payloadHash` where applicable. Failed engine invocation rows
include `error.failure`, the canonical failure envelope, while retaining
replay-local diagnostic fields for postmortem inspection. It is for offline
audit/reconstruction and does not call providers, run tools, write files, spawn
processes, drain queues, publish streams, or mutate resources.
The replay manifest is a capability result, not a persisted event type, so iOS
does not need a separate replay event decoder.

Agent authority is declared before the loop starts through the causal authority
envelope and the one model-visible `execute` primitive. Approval records are
package-owned evidence/freshness gates, not authority grants or an engine-minted
permission ledger: schema, idempotency, resource leases, compensation
contracts, allowed scopes, existing grants, and the selected primitive
operation either validate before execution or return a normal policy error. The
trace record for that `execute` call captures the authority grant id, scopes,
provider/model metadata, request/result hashes, and
file/VCS attribution so the agent can inspect why an action did or did not run.

The `EngineStreamEventPump` routes retained neutral engine/session stream
records to subscribed clients. Runtime state observers consume the same
`TronEvent` stream through the shared `TronEventObserver` contract, so transport
code can fan out events without importing the domain implementation that owns
that state.

---

## Settings

**Location:** `~/.tron/profiles/`

Settings are loaded from three layers (highest priority last):

1. **Active profile settings** (`[settings]` in the resolved `profiles/<name>/profile.toml` chain)
2. **User overlay** (`~/.tron/profiles/user/profile.toml` `[settings]`, deep-merged over the active profile)
3. **Environment variables** (`TRON_DEFAULT_MODEL`, `TRON_DEFAULT_PROVIDER`, `TRON_HEARTBEAT_INTERVAL`, and `ANTHROPIC_CLIENT_ID`)

Settings are server-authoritative. Engine-native clients read the current valid `ProfileRuntime` snapshot by invoking `settings::get` and write sparse user overrides through `settings::update` / `settings::reset_to_defaults` with explicit idempotency keys. Missing overlays use profile defaults, but malformed TOML or non-object `[settings]` returns an engine/transport error instead of being repaired silently. Successful writes are serialized, validated, written atomically, and then swapped into the cached `Arc<TronSettings>` and `ProfileRuntime`. If the compiled profile runtime rejects the result, the sparse overlay is rolled back and the last valid runtime snapshot remains active.

The managed `profiles/default/profile.toml` is the auditable seeded baseline from `packages/agent/defaults/profiles/default/profile.toml`, compiled into the agent and written into `~/.tron/profiles/default/profile.toml` during startup seeding/recovery. `profiles/user/profile.toml` is intentionally sparse and high-signal: it stores only values the user/app explicitly changed under `[settings]`. If a managed profile default is missing, corrupt, or stale against the current strict profile schema, startup restores it from compiled defaults; malformed user settings, unknown nested settings keys, invalid TOML, and non-object `[settings]` fail fast. iOS decodes server-owned settings as authoritative fields instead of using local fallback defaults; device-only iOS preferences live in iOS storage/Keychain, not in the server settings profile.

The schema is defined in `packages/agent/src/domains/settings/profile/types/`. All field names are camelCase on the wire. **The WebSocket port is a CLI flag (`--port`, default 9847), not a settings field.**

### Key Configuration

```jsonc
{
  "version": "0.1.0",
  "name": "tron",

  "server": {
    "heartbeatIntervalMs": 30000,   // WebSocket heartbeat; 1000-600000 ms
    "defaultProvider": "anthropic",
    "defaultModel": "claude-sonnet-4-6",
    "defaultWorkspace": null,       // Optional quick-chat workspace path set by iOS onboarding/settings
    "tailscaleIp": null,            // Cached by the Mac wrapper after live Tailscale pairing resolution
    "transcription": {
      "enabled": false              // Opt-in local Parakeet/MLX composer speech-to-text
    }
  },

  "agent": {
    "maxTurns": 250
  },

  "context": {
    "compactor": {
      "maxTokens": 25000,           // Context budget
      "compactionThreshold": 0.85,  // Hard ceiling that triggers compaction
      "targetTokens": 10000,        // Target token count after compaction
      "charsPerToken": 4,           // Token estimation factor
      "bufferTokens": 4000,         // Response buffer
      "triggerTokenThreshold": 0.70,// Soft threshold for proactive compaction
      "preserveRecentCount": 5      // Always preserve N most recent messages
    }
  },

  "observability": {
    "logLevel": "info",                         // "trace" | "debug" | "info" | "warn" | "error"
    "verboseRetentionDays": 7                   // Short retention window for verbose diagnostics
  },

  "storage": {
    "retentionEnabled": true,                   // Startup/manual retention may prune low-signal diagnostics
    "maxDatabaseMb": 512                        // Soft cap surfaced by storage reports
  },

  "retry":  { "maxRetries": 1 },

  "session": {}
}
```

---

## Authentication

**Storage:** `~/.tron/profiles/auth.json` (mode 600)

The auth system supports OAuth 2.0 (PKCE), API keys, and multi-account selection. OAuth tokens auto-refresh before expiry. The schema is defined in `packages/agent/src/domains/auth/credentials/types/mod.rs` (`AuthStorage` → per-provider `accounts` + `apiKeys` + `activeCredential`).

Fresh Mac installs seed `auth.json` as the exact empty JSON object `{}`. That sentinel is valid only as pristine install state: first server boot materializes it through the normal atomic `0o600` auth writer into `version`, `providers`, `lastUpdated`, and `bearerToken`. Invalid JSON, unsupported versions, and non-empty partial auth objects remain hard errors and are not overwritten. Writers load through the malformed-file-preserving write helper and persist with a same-directory temp file, `sync_all`, and atomic rename, so provider credentials and the bearer token never pass through a wider-permission file.

OAuth refresh is owned by `domains/auth/credentials/`: Anthropic, OpenAI, and Google refresh paths take a process-local refresh mutex, acquire the auth-file `flock`, re-read `auth.json` after the lock, persist refreshed tokens while holding the lock, and fail the refresh if persistence fails. Model providers receive ephemeral token copies for request execution and do not write durable auth state directly.

Provider-derived errors, retry events, client logs, and provider request audit
payloads share the same server redaction policy. Audit payloads are body-only,
versioned as `tron.model_provider_request.v1`, classified as exact provider
envelopes or provider-independent snapshots, redacted recursively, and rejected
if they exceed the provider-audit payload bound before the provider stream
opens.

OpenAI credential selection is owned by auth credentials through `OpenAIAuthPath`: ChatGPT OAuth accounts route model metadata and requests to the Codex backend, while OpenAI API keys route to Platform metadata and `/v1/responses`.

### Providers

| Provider | Module | Auth Methods | Notes |
|----------|--------|--------------|-------|
| Anthropic | `domains/model/providers/anthropic/` | OAuth (primary), API key | PKCE OAuth flow; cache pruning supported |
| OpenAI    | `domains/model/providers/openai/`    | OAuth, API key            | OAuth uses ChatGPT/Codex metadata; API keys use Platform `/v1/responses` metadata |
| Google    | `domains/model/providers/google/`    | OAuth, API key            | Cloud Code Assist OAuth, Gemini API key |
| MiniMax   | `domains/model/providers/minimax/`   | API key only              | - |
| Kimi      | `domains/model/providers/kimi/`      | API key only              | - |
| Ollama    | `domains/model/providers/ollama/`    | None (local)              | Requires Ollama running locally on the same Mac as the agent |

### Multi-Account

```bash
tron login --label work
tron login --label personal
```

`auth.json` stores accounts under `providers.<name>.accounts[]` (named OAuth entries) and `providers.<name>.apiKeys[]` (named API keys). The active credential per provider is selected by `providers.<name>.activeCredential`, which is `{type: "oauth"|"apiKey", label}`. Manage from the iOS app, CLI, or canonical `auth::*` capabilities through `/engine` `invoke`. When an API key is saved without a custom label, Tron stores it as `Default`.

OpenAI uses the `openai-codex` provider key for both auth modes. ChatGPT OAuth credentials route to `chatgpt.com/backend-api/codex` and use Codex catalog limits such as `gpt-5.5` and `gpt-5.3-codex` at 272K context. OpenAI API keys route to `api.openai.com/v1/responses` and use Platform limits such as `gpt-5.5` at 1.05M context and `gpt-5.3-codex` at 400K context. `model.list` is auth-path-aware: OAuth shows the live Codex catalog plus documented Codex previews, while API keys show all streaming text/image-in-to-text-out Responses models Tron can serve without a separate image, audio, video, embedding, moderation, realtime, or background provider path. Dated snapshots like `gpt-5.5-2026-04-23` are accepted as hidden aliases and preserve the exact request model ID. Retired OpenAI models remain listed with replacement metadata, but `model.switch` rejects them so they cannot be newly selected; non-streaming models such as `gpt-5.5-pro`, `o3-pro`, and `o1-pro` stay hidden and are rejected by the streaming provider.

### Auth Precedence

1. A session-pinned credential, when present
2. The provider's `activeCredential` from `auth.json` (OAuth or API key, by label)
3. The provider's first OAuth account
4. The provider's first API key

### WebSocket Bearer Token

**Storage:** `~/.tron/profiles/auth.json` top-level `bearerToken` (mode 600, atomic writes)

Stored beside provider auth in the same secure file. This single 32-byte URL-safe-base64 token gates every WebSocket upgrade request. The same token is shared across all paired iOS devices for a given server (per-device tokens are deferred to a future version).

The token is generated during first server startup and written as `bearerToken` inside `~/.tron/profiles/auth.json`. If the installer seeded `{}`, startup rewrites that sentinel into the full auth schema at the same time. The Mac onboarding wizard and iOS pairing flow both display it for the user to copy into the iOS pairing step.

```bash
# Rotate the token (forces every paired iOS device to pair again)
tron auth rotate

# Then use the iOS re-pair action for each affected server to scan or paste the fresh token.
```

Rotation is serialized through a process-wide mutex and the on-disk write is atomic (`tempfile + sync_all + rename`), so a concurrent rotate from the menu bar and CLI cannot corrupt the file. After rotation the daemon's in-memory token cache picks up the new value within a few seconds via mtime comparison; iOS clients carrying the old token receive HTTP 401 on next connect and fall into `ConnectionState.unauthorized`.

The first-run sentinel `~/.tron/internal/run/.onboarded` is created by the Mac wizard at the end of its install flow OR on the first successful WS auth, and is reported via the `paired` field of the canonical `system::get_info` capability (so an iOS device pointed at a fresh server can distinguish "never been onboarded" from "ready to pair").

See [`packages/agent/src/app/lifecycle/onboarding/mod.rs`](packages/agent/src/app/lifecycle/onboarding/mod.rs) for the full token + sentinel lifecycle.

---

## Context and Compaction

The context system manages the LLM's input window for the primitive loop. Each
turn assembles only the agent soul/system prompt, the compact agent-owned state
projection, an explicit memory prompt-trace audit, environment metadata,
conversation history, and any pending `execute` results. The memory audit
records disabled/active/shadow/compare mode, considered/included/excluded
counts, and the prompt-trace resource id; retained memory body content is never
injected. The audit is recorded per turn trace, not reused as a session-stable
idempotency result. Built-in rules, skills, worker guides, hooks, and profile policy
primers are not model-context planes on this branch.

The prompt loop records context totals in session events and trace metadata.
Before a provider call this is the chars/4 local component estimate; after a
provider call it uses the exact provider-reported context count. When provider
tokenizer/cache accounting is higher than the sum of local sections, trace
metadata carries a provider adjustment so clients can show the attributed
sections plus the provider tokenizer delta without guessing.

### Compaction Pipeline

When context crosses the proactive trigger (default
`triggerTokenThreshold: 0.70` of the model context window), compaction runs
before the next provider call:

1. **Summarize**: A deterministic keyword summarizer condenses older messages.
2. **Stage**: A `compact.summary_staging` event durably records the summary before commit.
3. **Boundary**: A `compact.boundary` event commits the cutoff and carries the summary used by server-side reconstruction.
4. **Trim**: Messages before the boundary are replaced with the summary on runtime reconstruction.
5. **Preserve recent**: The most recent `preserveRecentCount` turns always survive the cut.

If a triggered compaction produces no durable token reduction, the server does
not persist `compact.summary_staging` or `compact.boundary`. It still emits a
terminal live `agent.compaction` event with `success=false` so connected
clients can retire any in-progress compaction indicator without reconstructing
a false boundary.

Compaction is internal prompt-loop infrastructure. It is observable through
session events and primitive trace records, not through public `context::*`
capabilities.

### Context Assembly Order

```
Agent soul / system prompt
  + Agent-owned state summary
  + Memory prompt trace audit
  + Environment metadata
  + History reconstructed from session truth
  + Pending user prompt and execute results
```

---

## Database Schema

Default production server storage lives in `~/.tron/internal/database/tron.sqlite`; explicit developer/test homes such as the Mac isolated install use the same `internal/database/tron.sqlite` path under their resolved Tron home. WAL mode stays enabled at runtime with a 5 s busy timeout, foreign keys, bounded auto-checkpointing, and a shutdown checkpoint; `storage::export_snapshot` creates a portable single-file copy when needed. The active DB carries a `storage_generation = "modular-engine-v4"` marker in `storage_metadata`; if startup sees a `tron.sqlite` without the current marker, it archives `tron.sqlite`, `tron.sqlite-wal`, and `tron.sqlite-shm` into `internal/database/archive/modular-engine-v4-*` and starts fresh. Non-current product/session data is archived, not migrated or read by the new runtime. Pre-unified database artifacts are archived the same way and are never read as active storage.

The unified database has one fresh migration surface for primitive session/log/blob tables: `packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql`, with migration tests under `packages/agent/src/domains/session/event_store/sqlite/migrations/tests/`. The migration runner registers only that schema; deleted product follow-up migrations are not active on this clean-break branch. Every retained session-store constraint is declared inline on `CREATE TABLE`: `UNIQUE(session_id, sequence)` on events, `CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)` on events, and foreign-key checks on session/workspace/blob relationships.

Retained session rows, event rows, Agent Trace-style records, bounded
server/iOS logs, and compressed content-addressed blobs share that same SQLite
file. Large correctness and audit payloads flow through blob refs where the
owning row needs them; compact rows keep human/agent-readable JSON inline. The
model-visible evidence read path is `capability::execute` with `trace_list`,
`trace_get`, `log_recent`, `replay_manifest`, `catalog_search`,
`catalog_inspect`, `catalog_conformance`, and `job_*` lifecycle operations;
trace/log/replay/job reads require trusted current-session context, and catalog
conformance plus mutating job operations require idempotency.
Trace reads are backed by `trace_records`; effectful `execute` calls insert a
running record before the effect runs and update that same record with status,
duration, result/error hashes, authority, provider/model metadata, VCS revision
when available, and file attribution/content hashes after completion. The
agent backend logs run/turn/provider/stream/capability/execute lifecycle
metadata to the `logs` table with stable `component`, `agent_event`, session,
workspace, trace, run, turn, invocation, resource, and status fields where those
facts exist; verbose stream logs record sizes and sequencing rather than
content, and the SQLite transport redacts known credential/token patterns from
server-side messages, structured data, and error fields before persistence. The
`replay_manifest` operation is read-only and does not insert a trace record; it
reads session events, provider
audits, trace records, idempotency entries, invocation ledger rows, stream rows,
and queue rows through owner APIs and returns canonical section hashes plus the
overall `replayHash`. The direct `logs::recent` worker and `tron logs` CLI both
return bounded rows and can narrow by stable session, workspace, and trace IDs
without exposing bearer/API/OAuth secrets.

### Tables

| Table | Purpose |
|-------|---------|
| `schema_version` | Migration version tracking |
| `workspaces` | Project/directory contexts (id, path, name, timestamps) |
| `sessions` | Session metadata: head pointer, title, model, working directory, turn/token counts, tags, and fork lineage |
| `events` | Immutable append-only event log. Denormalized columns (`role`, `model_primitive_name`, `invocation_id`, `turn`, token counts, `model`, `latency_ms`, `stop_reason`, `provider_type`, `cost`, ...) extracted from payloads for indexed queries |
| `blobs` | Content-addressable deduplicated storage (hash, compressed content, MIME type, uncompressed/compressed size metadata) |
| `logs` | Application logs (level, component, message, error fields, session/workspace/trace IDs) |
| `trace_records` | Agent Trace-style durable records for primitive `execute` calls, including trace/session/invocation/provider ids, model primitive name, operation, status, timestamps, duration, and full JSON `record_json` |
| `engine_invocations` | Engine invocation ledger: function, worker, trace, parent, idempotency, status, result/error summaries |
| `engine_grants`, `engine_grant_events` | Engine-owned authority model: parent/child grants, subject binding, allowed capabilities/namespaces/resource selectors/file roots/network/risk/budget/expiry/delegation, plus lifecycle events |
| `engine_stream_events` | Engine stream publication history with cursor, topic, visibility, trace, and compact payload |
| `engine_catalog_changes`, `engine_catalog_workers`, `engine_catalog_functions` | Live catalog audit trail plus reopened worker/function snapshots for registration, health, visibility, and lifecycle changes |
| `engine_idempotency_entries` | Durable idempotency reservations and replay records |
| `engine_state_entries`, `engine_queue_items`, `engine_resource_leases`, `engine_compensation_records` | Primitive worker state owned by the engine runtime |
| `engine_resource_type_definitions`, `engine_resources`, `engine_resource_versions`, `engine_resource_links`, `engine_resource_events` | Generic typed resource substrate for agent-owned artifacts, generated UI surfaces, execution outputs, durable `job_process`, goal, `user_question`, `goal_answer`, and `web_source` source-provenance records, memory engine/policy/record/prompt-trace/eval-run/migration contracts, and agent results; resource versions carry `available`, `quarantined`, `damaged`, or `discarded` state |
| `storage_metadata`, `storage_payload_refs` | Storage generation marker plus owner refs for blob-backed payloads (owner kind/id, field, preview, hash, size, retention, trace/session/workspace) |
| `storage_checkpoints`, `storage_exports`, `storage_retention_runs` | Storage operations audit records for checkpoint/export/retention capabilities |

The events table enforces correctness with `UNIQUE(session_id, sequence)` and a single ordering index on `(session_id, sequence)`; most other access patterns are intentionally allowed to scan/filter at our volumes. Session views are reconstructed from the canonical event log. Fresh storage contains no branches, push-token tables, cron tables, constitution audit tables, session profiles, worktree overrides, prompt queue events, config mutation events, rules/skills/hooks events, or deleted product catalog tables.

---

## iOS App

**Minimum iOS:** 26.0 | **Swift:** 6.0 | **Build system:** XcodeGen

### Architecture

The app uses MVVM with coordinators, event plugins, and SwiftUI's `@Observable` macro. The authoritative architecture document is `packages/ios-app/docs/architecture.md`.

```
packages/ios-app/Sources/
+-- App/                  Lifecycle entry point, delegates, scene phases
+-- Engine/               Engine transport, protocol DTOs, event handling,
                         local persistence, repositories
+-- Session/              Chat workflow, attachments, parsing, timeline
                         messages, reconstruction, activity, and tokens
+-- Support/              Composition, diagnostics, feedback, foundation,
                         pairing, share, storage
+-- UI/                   Theme, chat, settings, onboarding, runtime
                         surfaces, capabilities, components, system sheets
+-- Resources/            Fonts and generated app-icon source layers
+-- Assets.xcassets/      Icons and images
+-- Resources/Fonts/      Bundled typography assets
+-- Resources/IconLayers/ Source layers for the app icon
+-- Info.plist            App metadata
+-- PrivacyInfo.xcprivacy Apple privacy manifest
```

### Key Patterns

- **Feature-owned state slices**: Chat state, coordinators, navigation, messaging, and timeline projection live under `Session/Chat` and `Session/Timeline` owners.
- **Coordinator pattern**: Stateless logic in coordinators, state in view models via context protocols
- **Event plugins**: Live engine events arrive through `SessionEventRepository`, are parsed by plugins, and are dispatched by `EventDispatchCoordinator`.
- **History transformer**: stored events reconstructed into `ChatMessage` arrays by `Session/Timeline/Reconstruction/UnifiedEventTransformer.swift`
- **Primitive chat shell**: the app keeps connection/onboarding/settings,
  collapsible workspace-grouped session navigation with compact one-line rows
  that use inset liquid-glass interactive containers, prefer generated session
  titles before prompt fallbacks, and show untitled rows as `New Session`,
  server-backed new-session workspace selection with configured/recent
  shortcuts, paired-Mac directory browsing, hidden-folder visibility, and
  inline folder creation, prompt input with clearable
  device-local recent-input reuse, the
  functional-only native composer attachment menu that preserves keyboard
  focus while layering native camera/photo/file pickers above it, composer mic
  input backed by the local transcription domain after a readiness check and
  cancellation-aware through startup and cancelled with any in-flight
  transcription when leaving chat,
  a blank empty/loading chat, app-global connection toasts, ephemeral in-chat
  local error notifications, streamed thinking content with one app-owned
  neural-spark fallback indicator, one-line generic capability evidence chips,
  local reconstruction, diagnostics, and generic runtime surfaces.
  Fixed product panels,
  repository-specific panels, media workflow surfaces, assistant-management
  panels, extension-source surfaces, voice-note storage, memory-retain, rules,
  skills, prompt-library panels, prompt queues, and parallel tree-only
  projections are removed from the primary source tree.
- **Agent cockpit**: Servers -> Diagnostics exposes a compact Runtime Cockpit
  row that opens the cockpit sheet. The sheet renders live worker lifecycle
  catalog rows, capability discovery families, schema/health gaps, durable
  `catalog_discovery_report` history, package/resource status,
  redacted memory resource status through generic resource facts,
  confirmation-backed lifecycle actions, activity, and active `ui_surface`
  resources through generic engine data using the standard liquid-glass sheet
  chrome and shared segmented tab control. Refresh failures render as a degraded
  cockpit status while preserving the last good server facts, and malformed
  catalog entries surface catalog decode degradation instead of disappearing
  from projected counts. The primary chat shell does not mount a passive
  worker-runtime banner.
- **Dependency injection**: All services via SwiftUI `@Environment(\.dependencies)`; SwiftUI/session layers consume repository protocols and view models, while concrete engine clients are wired in `Support/Composition`.
- **Generic runtime rendering**: server/agent-authored runtime data renders through `GeneratedRuntimeSurfaceView`; iOS does not map fixed feature names into custom sheets.
- **Onboarding sheet**: `TronMobileApp.readyContent()` always mounts `ContentView`; first-run setup, Settings-launched server pairing, and pairing URLs all present the same large-detent `OnboardingFlowView` through the central onboarding presenter. Settings can reopen the flow at the Connect page for another server or token refresh, with a dismiss button, and posts that launch only after the Settings sheet has dismissed so SwiftUI presents a single modal at a time. New-server onboarding requires a scanned/pasted/manual token and a bare DNS, IPv4, or unbracketed IPv6 host before Connect is enabled; full URLs, paths, query strings, userinfo, bracketed hosts, malformed IPs, and malformed DNS labels are rejected before any probe. An already paired server row can reuse that server's Keychain token unless the user edits its host or port. Successful repair of an existing server closes after the probe/settings refresh when the host and port still match; new or edited server origins continue into setup. Setup pages require a pairing probe plus engine invocations for `settings::get` and setup hydration.
- **Local paired-server model**: `PairedServerStore` keeps the paired Mac list and active server id in iOS storage, while `PairedServerTokenStore` stores each server's bearer token in Keychain. Pairing commit rollback restores the previous token for a failed re-pair or removes the candidate token for a failed new-server pairing. The server never stores the iOS pair list in `profiles/user/profile.toml`.
- **Live engine stream state**: Engine-owned transport treats subscription ids as WebSocket-local. UI/session code sees only repository connection state and parsed event streams; the engine layer clears active subscriptions on disconnect, recreates the current session subscription at the live topic tail after reconnect/reconstruction, and coalesces stream ACKs to the latest cursor.
- **Setup hydration**: after QR/manual pairing, onboarding reads the active Mac's `settings::get` response and best-effort `auth::get` masked credential state before unlocking setup pages. Pairing a previously forgotten Mac therefore shows the server's existing workspace/model choices and credential hints without storing server settings or secrets on iOS; OAuth/API-key saves refresh those cards immediately from the returned `AuthState`.
- **Forgetting a server**: Settings → Servers → menu → "Forget" removes the server's Keychain token before removing local metadata and surfaces a Keychain error without forgetting metadata if token deletion fails. If another paired server remains, the app switches locally; if none remain, Settings shows the onboarding CTA.
- **Local diagnostics + feedback**: Tron ships no outbound analytics SDKs and `PrivacyInfo.xcprivacy` declares no collected data. iOS registers `MetricKitDiagnosticsStore` for Apple MetricKit payloads, stores them locally with bounded retention, and includes them only when the user taps Settings -> Send Feedback. `DiagnosticsBundleBuilder` creates one redacted JSON attachment with app/server state, recent local/server logs, session/event summaries, and MetricKit payloads; Settings opens the native Mail composer with the runtime-configured `TRON_FEEDBACK_EMAIL` recipient, subject, body, and JSON attachment, including a body time range when real log timestamps are available. The tracked default is blank and may be supplied by `Local.xcconfig`, CI secrets, or release build settings. Settings also exposes the Logs sheet in every iOS build configuration from the toolbar and the Servers page Diagnostics section so production installs can inspect or copy redacted local iOS logs without enabling verbose production logging. When connected to a paired server, iOS automatically ingests deduplicated client logs into the server `logs` table through `logs::ingest` with client send-boundary redaction, server-side ingestion redaction for bearer/API/OAuth fields, deterministic batch idempotency, and client-side entry fingerprints, so server and client logs share the same durable query surface during normal execution without resending unchanged local buffers. Successful `logs::ingest` transport chatter is filtered at the client-ingestion boundary to prevent self-feeding diagnostics loops while preserving ingestion failures and reconnect warnings. If Mail is unavailable or recipient config is unresolved, Settings shows an alert instead of a share-sheet alternate path. App Store/TestFlight crash diagnostics remain available through Apple's Xcode Organizer path, and release builds keep `dwarf-with-dsym`.
- **IOSTC proof**: `packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md`,
  `packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md`,
  `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md`,
  `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv`, and
  `packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs`
  are the current static proof that iOS stays a generic runtime shell.
- **IOSAC proof**:
  `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-scorecard.md`,
  `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-evidence-manifest.md`,
  `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-inventory.md`,
  `packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-inventory.tsv`,
  and
  `packages/agent/tests/ios_self_adapting_agent_cockpit_baseline_invariants.rs`
  are the baseline static proof for the Agent cockpit, worker lifecycle catalog
  bridge, package action confirmations, dynamic `ui_surface` rendering, and
  neutral glass baseline; P2AER Slice 1 adds catalog discovery evidence on top.
- **IARM proof**:
  `packages/agent/docs/ios-affordance-restoration-map-scorecard.md`,
  `packages/agent/docs/ios-affordance-restoration-map-evidence-manifest.md`,
  `packages/agent/docs/ios-affordance-restoration-map-inventory.md`,
  `packages/agent/docs/ios-affordance-restoration-map-inventory.tsv`, and
  `packages/agent/tests/ios_affordance_restoration_map_invariants.rs` are the
  current static proof for the functional-only iOS affordance restoration map.
  The map exhaustively classifies deleted or renamed old iOS paths and preserves
  the original Phase 1 review queue as historical planning evidence. It does
  not mean those affordances are restored.
  `packages/agent/docs/ios-affordance-restoration-progress.md` tracks Phase 1
  closeout, shipped slices, accepted off-plan work, validation, and deferred
  behavior. The durable Phase 2 agent-execution restoration plan is recorded in
  `packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md`,
  `packages/agent/docs/phase-2-agent-execution-restoration-evidence-manifest.md`,
  `packages/agent/docs/phase-2-agent-execution-restoration-inventory.md`, and
  `packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv`.
  Retrospective audit ordering and review-only constraints are tracked in
  `packages/agent/docs/restoration-retrospective-audit-status.md`.

### Data Flow

```
Live:    Engine transport -> SessionEventRepository -> EventRegistry -> Plugin -> EventDispatchCoordinator -> ChatViewModel
Stored:  EventDatabase -> Session/Timeline/Reconstruction -> [ChatMessage] -> ChatViewModel -> ChatView
Prompt:  InputBar -> ChatViewModel -> AgentRepository -> agent::prompt
Recent:  successful text agent::prompt -> InputHistoryStore -> native attachment menu -> RecentInputHistorySheet -> InputBar
Attach:  InputBar -> native attachment menu -> nested platform picker -> Attachment -> agent::prompt
Surface: Generated runtime data -> GeneratedRuntimeSurfaceView
Cockpit: Settings Diagnostics -> WorkerLifecycleRepository -> AgentCockpitProjection -> AgentCockpitSheet
```

The camera child sheet mounts before AVFoundation warm-up and uses the viewport
as the sheet surface, with controls layered at the bottom. The live/captured
camera image is installed through `immersiveCameraSheetPresentation` as the
modal presentation background, not just foreground content, so iOS 26
partial-sheet safe-area material cannot show through below the viewport. The
foreground layer stays controls-only with no bottom fade, keeping the camera
view as one continuous surface, and it uses a full-height geometry root so the
controls align to the bottom of the sheet instead of their intrinsic content
area. The row adds the runtime bottom safe-area inset back into its padding so
controls stay low without clipping into the rounded sheet edge. The sheet edge
stays flat and does not add foreground glass, refraction, or decorative border
layers over the live camera feed.
`CameraCaptureSheet` defers `AVCaptureSession` and `AVCapturePhotoOutput`
creation/configuration to its dedicated session queue so camera startup cannot
block the initial sheet presentation. The flashlight, shutter, and switch
controls share native interactive circular Liquid Glass surfaces with larger
hit targets than their visual glass buttons; the shutter stays a minimal
white-tinted frosted glass circle without a separate ring. After capture, the
same center control animates into a green-tinted use-photo check button, the
switch-camera control animates into the go-back-to-capture control, and the
flashlight control fades out while the row geometry stays stable. Entering
captured-photo preview stops the live `AVCaptureSession`; retake is the path
that leaves preview and restarts the session. Torch toggles and camera
switching run through the session queue, restore UI state on AVFoundation
failure, turn off active torch before replacing the video input, and remove the
old video input before validating the replacement input. Camera lookup uses
`AVCaptureDevice` discovery so front/back switching works across wide-angle,
TrueDepth, dual, and triple camera device variants.

### Build Configurations

| Config | Use |
|--------|-----|
| Beta | Debug build, side-by-side bundle ID |
| ProdDebug | Debug build, production bundle ID |
| Prod | Release build, production bundle ID |

### Documentation

Detailed iOS documentation lives in `packages/ios-app/docs/`:

- `architecture.md` — App architecture, patterns, file placement
- `development.md` — Xcode setup, builds, testing
- `events.md` — Event plugin system
- `onboarding.md` — First-run onboarding sheet, QR/deep-link handling, local paired servers, and bearer persistence

---

## Mac App

**Minimum macOS:** 15 Sequoia | **Swift:** 6.0 | **Bundle ID:** `com.tron.mac` | **Build system:** XcodeGen

`Tron.app` is a SwiftUI wrapper around the headless Rust agent. It ships as a notarized DMG via `.github/workflows/release-mac.yml`; production installs run only from `/Applications/Tron.app`. The app bundles signed helpers under `Contents/Library/LoginItems/` (`Tron Server.app` for production/local Release and `Tron Server Dev.app` for isolated Debug install testing), bundled LaunchAgent plists, and profile defaults under `Contents/Resources/Constitution/`. Each helper app contains the `tron` agent binary. The wizard registers the active helper through `SMAppService`, confirms permissions, presents the Tron iOS Beta TestFlight QR, and reveals pairing info for iOS. After the wizard, the app transforms into a menu-bar icon (`LSUIElement = YES`) that checks server health by invoking `system::ping` through `/engine` `invoke`.

```
packages/mac-app/Sources/
+-- App/
|   +-- Lifecycle/             App entry, runtime variant, and startup maintenance
|   +-- CommandMode/           Internal start/uninstall command modes
|   +-- Composition/           Sendable environment setup and live/test DI
+-- Server/
|   +-- LaunchAgent/           SMAppService-backed LaunchAgent boundary
|   +-- Health/                Server ping, health wait, and status polling
|   +-- Paths/                 TronPaths and profile settings TOML cache
|   +-- PairingToken/          Bearer-token reader
|   +-- ProcessControl/        Dev stopper, process probe, lock, uninstall
+-- MenuBar/
|   +-- Controller/            NSStatusItem lifecycle
|   +-- Actions/               Menu command handlers and feedback action
|   +-- Presentation/          Menu descriptors, log reader, logs window
+-- Wizard/
|   +-- Flow/                  Wizard state machine and shell view
|   +-- Steps/                 Welcome, Tailscale, Install, Permissions, iOS Beta, Pairing, Done
|   +-- Components/            Window and visual layout primitives
+-- Support/
|   +-- Diagnostics/           Redaction for diagnostics and logs
|   +-- Feedback/              GitHub issue composer
|   +-- Foundation/            Shared foundation helpers, subprocess, and display formatting
|   +-- Onboarding/            Wizard models, probes, install planning
|   +-- Pairing/               Pairing URL, QR, local computer-name helpers
|   +-- Theme/                 Colors, font loading, typography
+-- Resources/
+-- Assets.xcassets/
+-- Info.plist
```

### Wizard Steps

1. **Welcome** — introduces Tron.
2. **Tailscale prerequisite** — detects `/Applications/Tailscale.app` or the Tailscale CLI, then reads `tailscale status --peers=false --json` for a running backend and 100.x IPv4.
3. **Install** — detects whether the bundled Login Item is registered, but treats that as registered-not-ready until the user presses Install/Start and `system::ping` answers through `/engine` `invoke`. It validates that release builds are running from `/Applications/Tron.app`, validates the helper/plist/signature, registers or refreshes `com.tron.server` through `SMAppService`, handles macOS Login Items authorization by opening Settings when needed, and polls `system::ping` after the initial `hello.ok` frame.
4. **Permissions** — Full Disk Access only. Deep-links to System Settings, labels the exact wrapper app entry to enable, polls wrapper-owned TCC state, starts a short-lived fast-probe watcher after the wizard-opened Settings pane, and keeps Re-check as a non-restarting probe.
5. **iOS Beta** — shows the public Tron TestFlight invite (`https://testflight.apple.com/join/xbuX1Grx`) as a QR code for the iPhone camera, with copy/open alternatives. TestFlight then owns beta availability and update selection.
6. **Pairing** — reads the agent-issued bearer token, confirms the local server heartbeat, resolves this Mac's Tailscale IP live (then caches it in `profiles/user/profile.toml`), detects the Mac's user-facing computer name, and displays host + port + token + server name with copy buttons and a QR code encoding `tron://pair?host=<ip>&port=<port>&token=<token>&label=<server-name>`. The QR builder uses the same bare-host and `1...65535` port contract as iOS, so it does not emit URL/path/userinfo/bracketed-host payloads.
7. **Done** — touches `.onboarded` sentinel, transforms to menu-bar mode.

### Menu-bar Actions

| Item | Action |
|------|--------|
| Custom status header | Shows `Tron`, the Tailscale endpoint, color-coded state, PID, normalized live uptime, and a `Dev Server active` marker when `tron dev` owns port 9847 |
| Show pairing info | Opens a pairing-only window that shows one emerald resolving spinner directly on the window background until the QR + manual copy buttons for host, port, token, and server name crossfade in; copy actions quickly show a checkmark for two seconds on success |
| Restart / Pause / Resume server | `SMAppService.register` repair/load before restart or resume, then `launchctl kickstart` when the label was already loaded; start-like actions post success only after `/health` passes |
| Update finalization | On the first menu-bar launch or command-mode start for a new app build, refreshes stale SMAppService metadata and restarts the bundled server once; the app-version marker is recorded only after `/health` passes, and `tron dev` takeover defers this until the production server is active again |
| Stop dev server | Appears with the server controls whenever `Tron-Dev.app` owns port 9847; stops the dev process and resumes the installed Login Item through the same health-gated path. Pause, restart, and uninstall are disabled while dev takeover is active. |
| Show logs | Opens the native logs window backed by the read-only `logs::recent` capability |
| Send feedback | Opens a prefilled GitHub issue with app/server context and redacted recent logs |
| Uninstall Tron | Confirm dialog + `SMAppService.unregister`; clears `internal/run/` runtime state; optional checkboxes remove `profiles/user/profile.toml` settings overrides and/or `profiles/auth.json`. The database and workspace are always preserved. |
| Quit Tron | Quits wrapper; server keeps running via LaunchAgent |

### Variants & Workflows

The wrapper coexists with local Release testing, Xcode Debug UI dogfood, an isolated Xcode install sandbox, and the `tron dev` agent-only workflow. Production workflows share `port 9847` and the `~/.tron/internal/` data tree; the isolated install scheme deliberately uses `port 9848`, `~/.tron-dev`, `com.tron.server.dev`, and the separate `Tron Server Dev.app` helper whose bundle identifier matches that LaunchAgent label.

| Workflow | Build product | Bundle ID | Lives at | What it is |
|---|---|---|---|---|
| **Production (DMG)** | `Tron.app` | `com.tron.mac` | `/Applications/Tron.app` | Notarized SwiftUI wrapper + bundled headless agent — what end users install |
| **Local Release test** (Xcode Release copied into place) | `Tron.app` | `com.tron.mac` | `/Applications/Tron.app` | Same installed-release path as the DMG; useful for validating local changes before packaging |
| **Debug companion** (default Xcode Run) | `TronMac.app` | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/TronMac.app` | SwiftUI wrapper dogfood that coexists with `/Applications/Tron.app`; it observes the production server but does not register, pause, restart, or uninstall it |
| **Isolated install test** (`TronMac Isolated Install` scheme) | `TronMac.app` | `com.tron.mac.dev` | DerivedData | First-run/reinstall sandbox with separate LaunchAgent label, port, and data root |
| **Agent dev** (`tron dev`) | `Tron-Dev.app` (no SwiftUI — just a `.app` wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/internal/run/Tron-Dev.app` | Headless agent only — used by contributors iterating on the Rust server without rebuilding the wrapper |

Mutual exclusion:
- Duplicate wrappers of the same bundle ID — guarded by `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` (`fcntl(F_SETLK, F_WRLCK)`). Release and Debug companion wrappers intentionally use different lock files so their menu icons can coexist.
- Production agents — guarded by `~/.tron/internal/database/tron.sqlite.lock` (cross-process exclusive `flock`).
- LaunchAgent ownership — installed Release is authoritative for `com.tron.server` and repairs stale Debug/DerivedData registrations before restart; default Xcode Debug is companion-only. The `TronMac Isolated Install` scheme owns `com.tron.server.dev` on port `9848` with `TRON_HOME_NAME=.tron-dev` and a Debug-first `AssociatedBundleIdentifiers` list so ServiceManagement attributes the job to `TronMac.app`.
- Port `9847` — `tron dev` calls `launchctl bootout com.tron.server` before binding, so the installed helper is paused while dev-mode runs.
- Direct server guard — if no LaunchAgent owns the service but port `9847` is already bound or `internal/database/tron.sqlite.lock` is held, the app reports another Tron server instead of registering a second helper or choosing a different port.

A contributor can have the DMG installed AND run the default Xcode Debug wrapper for menu/wizard UI work; both menu icons can coexist and both observe the production server. Running `tron dev` is still the explicit server-takeover path for Rust-agent iteration: the wrapper's menu bar keeps pinging port 9847, reports the `Tron-Dev.app` PID/uptime, and shows `Dev Server active` while dev owns the port. Quitting `tron dev` restarts the installed helper by invoking `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, which re-enters the same `SMAppService` registration path used by the app; the CLI reports the installed service as restarted only after `/health` passes, records the finalized app-version marker on success, and stale installed helpers that cannot parse current profile defaults must be updated rather than papered over. The menu-bar Stop Dev action follows the same rule, showing `Resume failed` when ServiceManagement loads an unhealthy installed helper instead of posting a false recovery. Pre-onboarding production cleanup uses the installed app's paired internal command `--tron-uninstall-and-quit` so stale Login Item registrations are removed by `SMAppService.unregister` instead of only being booted out of launchd; Debug companion command mode refuses to uninstall production. See [`packages/mac-app/docs/architecture.md` → Workflows & Variants](packages/mac-app/docs/architecture.md#workflows--variants) for the full breakdown including the on-disk artifacts each workflow shares.

### Documentation

- `packages/mac-app/docs/architecture.md` — wizard + menu bar + helper-binary lifecycle
- `packages/mac-app/docs/development.md` — workflow quick reference for Xcode Debug, local Release install testing, `tron dev`, and DMG release, plus XcodeGen/signing setup

---

## Permissions

The Mac wizard surfaces one system permission after the server is installed. Full Disk Access has an "Open System Settings" deep link when revoked, and the row names the exact wrapper app entry macOS expects in that pane.

| Permission | Why | Required | Probe |
|------------|-----|----------|-------|
| Full Disk Access | Agent reads/writes user-selected files and app data outside the sandbox | Yes | Wrapper process opens FDA-gated user data |

The install step validates the active signed helper (`Tron Server.app` for production/Release or `Tron Server Dev.app` for isolated Debug), registers the bundled LaunchAgent through `SMAppService`, and waits for the first heartbeat. Ordinary agent startup does not probe TCC or open System Settings, so macOS permission prompts cannot appear while the user is still on the install step. The LaunchAgent's `AssociatedBundleIdentifiers` lists the wrapper bundle IDs in the order appropriate for the active workflow, so macOS presents the helper's privacy grant under the responsible wrapper app: `Tron.app` in Release and `TronMac.app` in Debug. The wizard row therefore names the wrapper app, not the helper app. The settings button only opens System Settings; it never calls prompt APIs that would create a second modal over the already-open pane. Re-check/app activation use native non-prompting probes. Once Full Disk Access is green, Continue restarts the helper one time so launch-time-applied grants are visible to the server before pairing.

---

## Deployment

### Manual Contributor Deploy

```bash
tron manual-deploy          # Full pipeline with confirmations
tron manual-deploy --force  # Skip uncommitted-changes / test-failure prompts
tron manual-deploy --ci     # Non-interactive: any failure aborts
```

`tron manual-deploy` is a contributor-only script path and is not the production Mac distribution mechanism. Production releases are the notarized DMG pipeline below; end users replace `/Applications/Tron.app` from that DMG. The command has no shorter deploy alias.

The manual deploy process (`scripts/tron.d/manual-deploy.sh::cmd_manual_deploy`) is retained for local contributor workflows:

1. Aborts if a dev server is bound to the prod port.
2. Warns on uncommitted changes (errors out under `--ci`).
3. Builds the release binary (`cargo build --release`).
4. Runs `cargo test`. Failures prompt for continuation unless `--ci`.
5. Under `--ci`, also runs the benchmark gate.
6. Uses contributor-only artifacts directly under `~/.tron/internal/run/`.
7. Seeds managed defaults and runtime support.
8. Starts the contributor service and waits for `/health`.
9. Records `deployed-commit` and marks `restart-sentinel.json` complete only after health passes.
10. If start or health fails, attempts to restore `tron.bak`, waits for the restored helper to pass `/health`, marks the sentinel `rolled_back` or `failed`, writes `last-deployment.json`, and exits nonzero.

### Install Directory

Base directories for `profiles`, `workspace`, and `internal` in the tree below are resolved through helpers in `packages/agent/src/shared/foundation/paths/`. To rename one of those directories, change the constant in `dirs::*` there and every call site updates automatically. The engine ledger file is derived from the resolved event DB path in `packages/agent/src/engine/invocation/host/mod.rs`.

```
~/.tron/
+-- profiles/                     Agent execution specs and built-in auth
|   +-- active.toml                Active profile pointer
|   +-- auth.toml                  Readable credential-profile registry
|   +-- auth.json                  LLM provider OAuth tokens + API keys + bearerToken (mode 600)
|   +-- default/                   Managed, restorable base AgentExecutionSpec/manual
|   |   +-- profile.toml           Complete typed AgentExecutionSpec v3
|   +-- normal/                    Managed standard workspace/session profile
|   |   +-- profile.toml           Inherits default; profileClass = "normal"
|   +-- chat/                      Managed quick-chat profile
|   |   +-- profile.toml           Inherits default; profileClass = "chat"
|   +-- local/                     Managed local-provider profile
|   |   +-- profile.toml           Inherits default; profileClass = "local"
|   +-- user/                      Sparse user profile/settings overrides
|       +-- profile.toml           Sparse `[settings]` overrides
+-- workspace/                    Active work and generated artifacts
|   +-- projects/                  Project-local active work
|   +-- plans/                     Plan files and task lists
|   +-- reports/                   Analysis and investigation reports
|   +-- renders/                   Rendered pages displayed in chat
|   +-- screenshots/               Saved screenshots from runtime execution
|   +-- scratch/                   Downloads, temp files, experiments
|   +-- labs/                      Manifested experimental spaces
|   +-- archive/                   Archived workspace material
|   +-- knowledge/                 Curated wiki/research experiment
|   +-- vault/                     Local fast secret storage for agent-owned workspace state
|   +-- workers/                   Approved local worker-package root for `tron.worker_package.v1` manifests
+-- memory/                       User-authored memory/rule notes reserved for explicit future import
|   +-- rules/                     Reserved detail files; not auto-injected by the current memory contract
|   +-- sessions/                  Reserved session-scoped material; not a hidden prompt plane
+-- internal/                     Tron-owned runtime machinery
    +-- database/                  Unified SQLite engine storage and archives
    |   +-- tron.sqlite            Events, sessions, logs, blobs, engine ledger, streams, state, queues, typed resources, leases, compensation, workers
    |   +-- tron.sqlite.lock       OS-level flock sidecar; one Tron process owns it while running
    |   +-- archive/               One-way archive of non-current storage generations
    |   +-- journals/              Streaming journals for crash recovery of partial LLM output
    +-- run/                       Mutable runtime state and local contributor artifacts
    |   +-- auth.lock              Auth-file refresh lock
    |   +-- deploy.lock            Manual deploy concurrency lock
    |   +-- .mac-wrapper.*.lock    Per-wrapper menu app lock
    |   +-- .onboarded             First-run sentinel; presence drives `system::get_info.paired`
    |   +-- mac-app-version.json   Last app build whose menu-bar launch finalized the server
    |   +-- deployed-commit        Last contributor helper commit that passed `/health`
    |   +-- last-deployment.json   Last manual deploy/rollback result
    |   +-- restart-sentinel.json  Manual deploy restart state; `restarting` is a preflight blocker
    |   +-- Tron-Deploy.app        Contributor-only service bundle used by `tron install` / `manual-deploy`
    |   +-- Tron-Dev.app           Optional `tron dev` headless agent bundle
    +-- transcription/             Opt-in local composer speech-to-text runtime
        +-- worker.py              Parakeet/MLX Python worker
        +-- requirements.txt       Pip deps for the venv
        +-- venv/                  Auto-created when enabled and the sidecar starts
        +-- models/hf/             HuggingFace model cache (HF_HOME)
```

Notes:
- The seeded top-level homes are `profiles`, `workspace`, `memory`, and `internal`; for a clean reset, move `~/.tron` aside rather than deleting individual subtrees.
- Credentials for external CLIs (Google Workspace, etc.) live in `~/.tron/workspace/vault/`. Tron-owned provider auth and the bearer token live in `~/.tron/profiles/auth.json`.
- Pause/lock sentinels live under `~/.tron/internal/run/` with the rest of the runtime machinery. They are managed by the respective CLI subcommands, not user-edited at the Tron Home root.

### Service (SMAppService)

The production Mac app registers `com.tron.server` with `SMAppService.agent(plistName: "com.tron.server.plist")`. The notarized app must live at `/Applications/Tron.app`; the bundled LaunchAgent lives inside the app at `Contents/Library/LaunchAgents/com.tron.server.plist`, and its `BundleProgram` points at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` with `ProgramArguments` of `tron --port 9847 --quiet`. `AssociatedBundleIdentifiers` lists the wrapper bundle IDs (`com.tron.mac`, then `com.tron.mac.dev`) so Login Items/TCC attribution follows the responsible wrapper app. No production code writes `~/Library/LaunchAgents` or copies an app bundle into `~/.tron/internal/`. An enabled Login Item registration without a loaded launchd job is not treated as installed/running; the current app replaces that registration through SMAppService and still waits for the server heartbeat. If `launchctl print` reveals a stale event trigger pointing at a missing/mismatched helper executable, a stale parent bundle build number for the same installed app, stale launch constraints such as `needs LWCR update`, or a Debug/DerivedData parent owns the production label, the installed app boots it out, unregisters the stale registration, and re-registers `/Applications/Tron.app` before restarting.

Local Release builds use the same path rule: copy the built `Tron.app` to `/Applications/Tron.app` before testing install/registration. If a DMG build is already installed, the local Release build replaces that same slot; reopen `/Applications/Tron.app` or run `tron start`/`tron restart` so the wrapper repairs SMAppService before launchd executes the bundled server. Start-like menu actions, command-mode starts, contributor CLI start/restart, and update finalization wait for `/health` after ServiceManagement reports loaded; the app-version marker is recorded only after that health gate succeeds. Loaded-but-unhealthy helpers remain visible failures until `/Applications/Tron.app` is updated or reinstalled. Default Debug Xcode builds use bundle ID `com.tron.mac.dev`, may run from DerivedData, and are companion-only: they can show the menu bar and observe the production server, but server pause/restart/uninstall/install actions are disabled. Use the `TronMac Isolated Install` scheme when testing the first-run/reinstall wizard from Xcode; it registers `com.tron.server.dev`, points `BundleProgram` at `Tron Server Dev.app`, runs on port `9848`, and stores data under `~/.tron-dev`. For agent-only iteration, `tron dev` stops the production LaunchAgent, binds port `9847`, and later restores the installed helper through the wrapper's internal `--tron-start-server-and-quit` command so ServiceManagement remains the only production registration path.

### DMG Release Pipeline

End-users install `Tron.app` via a notarized DMG published to GitHub Releases. Release identity is centralized in `VERSION.env`: the first beta is canonical `0.1.0-beta.1`, Apple bundles receive numeric `MARKETING_VERSION = 0.1.0` / `CURRENT_PROJECT_VERSION = 1`, and human-facing UI renders `v0.1 (Beta 1)`. The pipeline lives at `.github/workflows/release-mac.yml` and triggers on a matching `server-v*` tag push:

1. Checkout + Rust toolchain/cache (`actions-rust-lang/setup-rust-toolchain`).
2. `scripts/tron version check` verifies `VERSION.env`, Cargo, Cargo.lock, Mac/iOS `project.yml`, custom bundle canonical version keys, and release docs agree before any artifact is built. A tag push must equal `server-v$(TRON_VERSION)`.
3. `cargo build --release --bin tron --locked` in `packages/agent/`.
4. Install XcodeGen + `create-dmg`.
5. `packages/mac-app/scripts/bundle-agent.sh --skip-build` stages `packages/agent/target/release/tron` into both bundled helpers (`Tron Server.app` and `Tron Server Dev.app`) and writes both LaunchAgent plists.
6. `xcodegen generate` inside `packages/mac-app/`.
7. Create an isolated release keychain from the signing/notarization secrets, or use dry-run ad-hoc signing when secrets are absent.
8. `xcodebuild archive` with `-scheme TronMac -configuration Release`.
9. Verify the bundled helper app, both helper executables, LaunchAgent plist, and profile defaults are present in the archive.
10. Sign the helper apps first, then sign `Tron.app` with hardened runtime + `TronMac.entitlements`; verify inside-out signatures before DMG packaging.
11. `xcrun notarytool submit` the signed `Tron.app` with `$NOTARIZE_PROFILE` (`tron-notarize`); staple the app on success.
12. Build the DMG with `create-dmg`, sign the DMG, submit that signed DMG to `notarytool`, then staple the DMG. The app and DMG require separate notary tickets.
13. Keep dSYMs in the Xcode archive/release artifacts for Apple crash diagnostics.
14. `scripts/tron-release-notes` writes a bounded draft changelog body from first-parent git history since the previous release tag, including the DMG filename, SHA256, and a full compare link. The body starts below GitHub's release title so the rendered page does not repeat the release name. The beta1-to-beta2 pump recognizes the historical Mac-scoped beta1 tag so the first `server-v*` release does not include the entire repo history.
15. `gh release create server-v0.1.0-beta.1 ./tron-v0.1.0-beta1.dmg` creates a draft GitHub pre-release titled `Tron Server v0.1 (Beta 1)` with the generated changelog; maintainers publish after installing and verifying the DMG.

A parallel dry-run job runs on every PR that touches `packages/mac-app/**` or the workflow itself. The dry-run stops before notarization (no cert needed) so PR contributors can verify the assembly pipeline without secrets.

The iOS TestFlight pipeline lives at `.github/workflows/release-ios.yml` and triggers on the same `server-v*` tag push. It regenerates `packages/ios-app/TronMobile.xcodeproj` from XcodeGen, verifies `VERSION.env` mirrors, runs the iOS simulator tests, archives the `Tron` scheme with the `Prod` configuration (`com.tron.mobile` / App ID `6761511764`), exports an App Store Connect IPA with Xcode's `app-store-connect` export method, uploads with `asc builds upload`, waits for the Apple build to become valid, resolves TestFlight export compliance, updates What to Test notes, submits TestFlight beta review when Apple requires it for external testing, and branches on the ASC review state. First external builds for a new marketing version normally enter `WAITING_FOR_BETA_REVIEW`; CI treats that as a successful pending-review checkpoint instead of timing out. Once Apple approves the version, rerunning the workflow or uploading later builds in the same version continues to group validation and assigns the build to the public external TestFlight group when one is configured or can be auto-discovered. The public group is the same TestFlight link shown by the Mac onboarding QR code. TestFlight group checks are warning-only after the build is uploaded and processed because successful public distribution must not be blocked by stale or renamed group variables that CI does not need to create the beta build. Reruns are idempotent: if the Apple build number already exists in App Store Connect, CI skips the binary upload and reuses that build for processing/distribution. Manual workflow runs default to `dry_run=true` and stop before ASC upload.

Required iOS release credentials are GitHub Actions secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8_BASE64`. `ASC_TESTFLIGHT_PUBLIC_GROUP_ID` and `ASC_TESTFLIGHT_INTERNAL_GROUP_ID` are optional repository variables used for group assignment diagnostics; CI can auto-discover a single public-link group and otherwise skips group assignment without failing an uploaded/processed build. CI can export with automatic Xcode cloud signing through the ASC key, or with local signing secrets when `IOS_DISTRIBUTION_CERT_P12_BASE64`, `IOS_DISTRIBUTION_CERT_PASSWORD`, `IOS_APPSTORE_PROFILE_BASE64`, and `IOS_SHARE_EXTENSION_APPSTORE_PROFILE_BASE64` are set. Local signing supports both manually managed App Store profiles and matching Xcode-managed App Store profiles. `ASC_KEY_ID` and the `.p8` path can be checked locally with `asc auth status --verbose` / `asc auth doctor`; `ASC_ISSUER_ID` is shown in App Store Connect under Users and Access -> Integrations -> App Store Connect API -> Team Keys. The iOS app and share extension declare `ITSAppUsesNonExemptEncryption=false`; CI verifies that key in the archive/export and can apply the same App Store Connect API build setting to already-uploaded builds that predate the plist key. TestFlight/App Store Connect remains the distribution and audit surface for iOS binaries. Do not create separate GitHub releases for iOS unless an iOS artifact is intentionally published through GitHub too; the shared `VERSION.env` keeps Mac/server and iOS version labels aligned without adding duplicate tags.

## Testing

### Rust Tests

```bash
cd packages/agent
cargo test                   # Full suite (single `tron` crate)
cargo test paths::           # Filter by module path
cargo test --quiet           # Quiet output
```

The agent is a single `tron` crate, so `cargo test` runs everything: library unit tests, app/bootstrap tests, integration tests, doc tests, and static gates. Test counts are intentionally not hardcoded in this README — they drift within days and mislead readers. Re-derive from `cargo test --quiet` output when you need the current number.

### iOS Tests

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### CI

```bash
tron ci                      # Run every check (fmt, check, clippy, test, bench, doc)
tron ci fmt check            # Subset: formatting + compilation
tron ci clippy test          # Subset: linting + tests
```

`tron ci test` runs Rust lib/bin tests serially first, then the named closeout targets:
`db_path_guard`, `primitive_engine_teardown_plan_invariants`,
`determinism_replayability_invariants`, `primitive_code_cleanup_invariants`,
`hierarchical_rearchitecture_invariants`,
`post_hra_adversarial_hardening_invariants`,
`post_aha_adversarial_closeout_invariants`,
`concurrency_scheduling_discipline_invariants`,
`security_authority_capability_boundaries_invariants`,
`observability_diagnostics_auditability_invariants`,
`off_plan_saa_authorship_teardown_cleanup_invariants`,
`data_integrity_storage_evolution_migration_discipline_invariants`,
`public_protocol_api_contract_discipline_invariants`,
`provider_model_boundary_discipline_invariants`,
`performance_resource_governance_invariants`,
`configuration_profile_environment_discipline_invariants`,
`release_install_upgrade_rollback_discipline_invariants`,
`ios_thin_client_generic_runtime_shell_invariants`,
`developer_experience_repo_hygiene_automation_invariants`,
`documentation_evidence_scorecard_integrity_invariants`,
`self_sufficient_agent_runtime_readiness_invariants`,
`primitive_minimality_closure_invariants`,
`baseline_pre_restoration_closure_invariants`,
`self_updating_worker_runtime_foundation_invariants`,
`ios_self_adapting_agent_cockpit_baseline_invariants`,
`ios_affordance_restoration_map_invariants`,
`primitive_trace_execution`, and
serial `integration`. GitHub's Rust static-gates job runs the same named target
set for docs, template, iOS, Mac, script, and CI changes.

Before restoring any feature from the primitive baseline feature index, the
feature slice must satisfy the BPRC pre-restoration entry contract: worker or
module owner, function/trigger contracts, resource/event schemas, authority
policy, iOS parity decision, tests, docs, migration and retention policy,
rollback strategy, and proof that the change is not a hardcoded harness
expansion.

Install the local hook once per clone with `scripts/install-hooks.sh`; it
blocks commits with staged Rust formatting drift and runs the personal-info
guard on staged changes.

Rust clippy CI uses the lint policy in `packages/agent/Cargo.toml`: correctness,
suspicious, performance, and a short list of footgun lints fail the build;
style/pedantic suggestions stay advisory so the signal is not buried.

---

## Core Invariants

These constraints are enforced in code with `// INVARIANT:` markers at the enforcement site.

1. **Canonical engine execution**: Production behavior is owned by canonical engine functions. The public `/engine` protocol is only transport; domain behavior is discovered and invoked by canonical `namespace::function` ids.

2. **Fail-fast on unknown models**: Unknown model or provider returns a typed `UnsupportedModel` error immediately. No silent substitution or default provider substitution.

3. **Deterministic event reconstruction**: Session state is always reconstructable from the immutable event log. No mutable session state stored outside events.

4. **Session-serialized writes**: All event appends are serialized per-session via in-process mutex locks. SQLite `UNIQUE(session_id, sequence)` enforces ordering at the DB level.

5. **Event ordering (iOS send button)**: `agent.ready` is emitted AFTER `agent.complete`. Clients see active work as `processing` and every terminal or between-turn window as `idle`; compaction and ledger state stay independent.

6. **Primitive context boundary**: model context contains soul, agent-owned state, environment, session history, and pending `execute` results. Built-in rules, skills, hooks, worker guides, and profile primers are not prompt planes.

7. **Compaction before provider calls**: threshold-triggered compaction runs before the next provider call and only persists a boundary when it reduces durable context.

8. **Database path guard**: Startup validates the database path is exactly `<resolved-tron-home>/internal/database/tron.sqlite`. Rejects alternate filenames, wrong directories, and symlinked paths.

9. **Single-process DB ownership**: Startup takes an OS-level `flock(2)` on `tron.sqlite.lock` before opening the connection pool. A second `tron` process pointed at the same database aborts with a clear error naming the holder's PID, instead of silently racing on `(session_id, sequence)` writes. Released on process exit (normal or abnormal). Enforced by `domains/session/event_store/sqlite/process_lock.rs::acquire_database_lock` called from startup database initialization.

---

## License

MIT
