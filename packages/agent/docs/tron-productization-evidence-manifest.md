# Tron Productization Evidence Manifest

Created: **2026-06-03**
Scorecard: [`tron-productization-scorecard.md`](tron-productization-scorecard.md)
Current score: **12/100**

This manifest records the evidence used to award productization scorecard
points. It is append-only within each coherent checkpoint: update the relevant
row, note command return codes, and keep open loops explicit.

## Boundaries

- No push, merge, release, deploy, notarization, or production rollout is
  allowed in this campaign.
- No remote package discovery, remote marketplace install, or remote package
  trust implementation is allowed.
- Clients must remain thin: no generated action target construction, approval
  truth, policy, source trust, model routing, or capability binding in iOS, Mac,
  or CLI.
- Product evidence must cite server-owned resources, invocations, catalog
  revisions, generated surfaces, source/trust decisions, screenshots, or logs as
  appropriate.

## Evidence Index

| Row | Status | Evidence |
|---|---|---|
| TPROD-A | passed_after_fix | This manifest and the master scorecard were created in `packages/agent/docs/`. README was updated to list both documents. `productization_scorecard_stays_formalized` was added to `packages/agent/tests/threat_model_invariants.rs`. Baseline audit commands and source references are listed below. |
| TPROD-B | passed_after_fix | Added the managed `self-extend` skill, synced it locally, and verified live worker protocol plus sample local worker flow with focused integration tests. Details below. |
| TPROD-C | pending | Product chat self-extension flow not yet proven. |
| TPROD-D | pending | Created-by-agent shelf/history not yet proven. |
| TPROD-E | pending | Local pack lifecycle product flow not yet proven. |
| TPROD-F | pending | Plain trust/promotion/revocation UX not yet proven. |
| TPROD-G | pending | Generated UI authoring product matrix not yet complete. |
| TPROD-H | pending | Model preset, automation, and subagent routing product proof not yet complete. |
| TPROD-I | pending | Flagship Tron-maintains-Tron loop not yet run. |
| TPROD-J | pending | Three polished local example packs not yet shipped. |
| TPROD-K | pending | Product user/operator/release-note docs not yet complete. |
| TPROD-L | pending | Full hardening, visual QA, soak, and closeout gates not yet run. |

## TPROD-A Evidence

### Inputs

- User supplied `/Users/moose/Downloads/PLAN.md` as the productization plan.
- The goal names
  `packages/agent/docs/tron-productization-scorecard.md`; that path was absent
  before this checkpoint.

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `git status --short --branch` | 0 | Confirmed branch `next/modular-capability-engine` was ahead of origin by one commit and had no unstaged changes at baseline. |
| `sed -n '1,260p' /Users/moose/Downloads/PLAN.md` | 0 | Read the provided plan source. |
| `wc -l /Users/moose/Downloads/PLAN.md` | 0 | Confirmed the plan has 125 lines. |
| `rg --files packages/agent/docs \| sort` | 0 | Confirmed no in-repo productization scorecard existed yet. |
| `sed -n '1,220p' packages/agent/src/lib.rs` | 0 | Audited top-level Rust module docs. |
| `sed -n '1,260p' packages/ios-app/docs/architecture.md` | 0 | Audited iOS thin-client and generated UI baseline docs. |
| `sed -n '1,240p' packages/mac-app/docs/architecture.md` | 0 | Audited Mac wrapper and managed-skill baseline docs. |
| `find packages/agent/skills -maxdepth 2 -type f \| sort` | 0 | Confirmed managed skills exist and `self-extend` is not present. |
| `rg -n "worker::protocol_guide\|ui_surface\|module::register_package\|subagent" README.md packages/agent/src packages/ios-app/Sources packages/mac-app/Sources scripts` | 0 | Located current substrate/product baseline references. |

### Source Evidence

- [`README.md`](../../../README.md): living architecture docs, generated UI,
  local module packages, source trust, worker protocol guide, sandbox-created
  capabilities, and subagent resource lineage.
- [`packages/ios-app/docs/architecture.md`](../../ios-app/docs/architecture.md):
  thin iOS client boundary, capability-native rendering, Engine Console
  projections, generated UI renderer, and disconnected fail-closed behavior.
- [`packages/mac-app/docs/architecture.md`](../../mac-app/docs/architecture.md):
  Mac wrapper boundary, managed skill sync, menu-bar server observation, and
  CLI dispatcher boundary.
- [`packages/agent/src/engine/primitives/worker.rs`](../src/engine/primitives/worker.rs):
  `worker::protocol_guide` primitive registration.
- [`packages/agent/src/engine/primitives/runtime/worker_protocol.rs`](../src/engine/primitives/runtime/worker_protocol.rs):
  worker protocol guide content owner.
- [`packages/agent/src/engine/primitives/ui.rs`](../src/engine/primitives/ui.rs):
  generated UI primitive lifecycle.
- [`packages/agent/src/engine/resources/ui_surface.rs`](../src/engine/resources/ui_surface.rs):
  fixed generated-UI resource validation.
- [`packages/agent/src/engine/primitives/module.rs`](../src/engine/primitives/module.rs):
  module package registration and activation function surface.

### Baseline Findings

- The low-level substrate for self-extension is present: generated workers,
  local worker spawning, catalog watch/inspect, generated UI resources, package
  registration, source trust, conformance evidence, activation lifecycle,
  promotion, cleanup, and subagent result resources.
- The product campaign is not complete. The repo lacked the master
  productization scorecard, evidence manifest, `self-extend` managed skill,
  chat-led self-extension product flow, created-by-agent shelf, plain trust
  labels, product model presets, example packs, visual QA, and soak evidence.
- TPROD-A is the only row currently awarded points.

### Open Loops

- Start TPROD-B by adding the covering test that requires the managed
  `self-extend` skill and prevents copied worker protocol details from drifting.
- After each row, update this manifest with exact commands, return codes,
  source references, screenshots or runtime ids where relevant, and the next
  open loop.

## TPROD-B Evidence

### Files

- [`packages/agent/skills/self-extend/.managed`](../skills/self-extend/.managed)
- [`packages/agent/skills/self-extend/SKILL.md`](../skills/self-extend/SKILL.md)
- [`packages/agent/tests/managed_skill_sources.rs`](../tests/managed_skill_sources.rs)

### Commands

| Command | Result | Purpose |
|---|---:|---|
| `cargo test --manifest-path packages/agent/Cargo.toml --test managed_skill_sources self_extend_skill_is_managed_and_uses_live_worker_protocol_guide -- --nocapture` | 101 then 0 | Red/green proof: first failed because `self-extend` was absent; after implementation passed and proved `.managed`, parseable frontmatter, `capability::execute`, required flow markers, and absence of copied worker protocol internals. |
| `rsync -a --delete --exclude=node_modules --exclude=.DS_Store packages/agent/skills/self-extend/ ~/.tron/skills/self-extend/` | 0 | Synced the managed repo skill into the local Tron skill directory. |
| `diff -qr packages/agent/skills/self-extend ~/.tron/skills/self-extend` | 0 | Verified installed local copy matches the repo-managed source. |
| `ls -la ~/.tron/skills/self-extend` | 0 | Verified installed `.managed` sentinel and `SKILL.md` are present. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration capability_self_modifying_lifecycle_execute_returns_worker_protocol_guide -- --nocapture` | 0 | Proved live `/engine` `capability::execute` path returns current `worker::protocol_guide` output. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration capability_self_modifying_lifecycle_inspects_session_worker_catalog -- --nocapture` | 0 | Proved sample local worker flow: guide, spawn, catalog watch, inspect, and cleanup through existing live integration harness. |

### Findings

- The skill is intentionally concise and does not embed worker protocol fields,
  socket paths, environment variable names, message shapes, or templates.
- The skill directs every run to fetch live `worker::protocol_guide`, then
  spawn with `worker::spawn`, watch `catalog::watch_snapshot`, inspect with
  `capability::inspect`, author generated UI through `ui::surface_for_target`,
  promote only through `engine::promote`, and clean up with
  `worker::disconnect` or `sandbox::stop_spawned_worker`.
- Existing live integration coverage is the sample local worker proof for this
  row; no new runtime harness was added.

### Open Loops

- TPROD-C must now productize this into chat-led UX: autonomy grant approval,
  capability chip progression, and plain-language creation/testing/repair
  status without requiring engine terms.
