# Tron Productization Scorecard: Self-Extending Agentic Product

Created: **2026-06-03**
Initial score: **0/100**
Current score: **49/100**
Status: **active; TPROD-F passed after fix; TPROD-G next**
Evidence manifest: [`tron-productization-evidence-manifest.md`](tron-productization-evidence-manifest.md)

## Scope

North star: Tron becomes the place for all local agentic work currently done in
Codex. Chat is the primary experience; Engine Console and Inspect are
drill-down layers. Tron must be able to update Tron itself through local,
evidence-backed capabilities, packs, generated UI, model/subagent routing,
trust UX, examples, docs, visual QA, and soak testing.

This scorecard productizes existing substrate pieces into a coherent local
product flow. Points require current evidence, not implementation intent.

## Product Contracts

- Primary UX is chat-led. Capability chips, helper/subagent status, and plain
  trust states are the first surface. Engine identifiers stay behind Inspect.
- One workspace-local autonomy grant can cover hands-off local capability
  creation and repair. Promotion outside that grant interrupts for explicit
  user approval.
- Product vocabulary is **capabilities** and **packs**. Engine terms such as
  workers, resources, grants, leases, signatures, and traces are inspect-only.
- Extensibility uses the stable native generated-UI catalog. Custom web UI is
  outside this MVP.
- Local pack discovery is disk/local-first only. Remote package discovery,
  remote marketplace install, and publishing are deferred.
- User-facing model presets are `Local when possible`, `Balanced`, and `Deep`.
  Pack hints may recommend model tiers or subagent roles, but profile policy
  decides what is allowed.
- iOS, Mac, and CLI never own policy, generated action targets, source trust,
  approval truth, model routing truth, or capability binding. Generated UI
  actions submit stored surface/action coordinates only.

## Explicitly Out Of Scope

- Push, merge, release, deploy, notarize, publish, or production rollout.
- Remote package discovery, remote marketplace install, or remote package
  trust roots beyond explicit deferred documentation.
- Client-owned generated UI action templates, policy, approval truth, source
  trust, model routing, or capability binding.
- App-specific fixed shells that duplicate generated UI authoring rather than
  proving the native generated-UI catalog.

## Evidence Contracts

Each row must record:

- Commands and return codes.
- Exact source files, docs, tests, fixtures, database rows, resource refs,
  invocation ids, catalog revisions, generated surface ids, screenshots, logs,
  or soak summaries as relevant.
- A status of `pending`, `running`, `passed`, `passed_after_fix`, `blocked`,
  `failed_unfixed`, or `deferred_to_successor`.
- Open loops and the next test before moving to the next row.

Stop on the first failed evidence contract. Fix the owning layer, remove stale
fallback/dead compatibility code nearby, rerun the failed scenario, update this
scorecard plus the evidence manifest, and commit a coherent checkpoint.

## Scorecard

| ID | Lane | Weight | Status | Acceptance Evidence | Current Evidence | Open Loops |
|---|---:|---:|---|---|---|---|
| TPROD-A | Baseline, plan, and evidence harness | 5 | passed_after_fix | Scorecard + evidence manifest exist; current engine/iOS/Mac/CLI/docs baseline is audited; all out-of-scope boundaries are explicit. | Added this scorecard and companion evidence manifest from `/Users/moose/Downloads/PLAN.md`. Audited README, iOS architecture, Mac architecture, managed skills, engine generated UI, worker protocol guide, module package lifecycle, source trust, subagent docs, and existing static gates. Added `productization_scorecard_stays_formalized` to keep the scorecard discoverable and prevent early overclaiming. | Closed. |
| TPROD-B | `self-extend` managed skill | 7 | passed_after_fix | Skill is installed as a managed Tron skill, synced locally, tested against live `worker::protocol_guide`, and validated by a sample local worker flow. | Added `packages/agent/skills/self-extend/.managed` and concise `SKILL.md`; added `managed_skill_sources` coverage proving the skill parses, declares `capability::execute`, requires live `worker::protocol_guide`, and does not copy worker protocol details. Synced to `~/.tron/skills/self-extend/` and verified repo/local copies match. Existing live integration tests passed for `execute -> worker::protocol_guide` and the sample session worker lifecycle through spawn, catalog watch, inspect, and cleanup. | Closed. |
| TPROD-C | Chat-led self-extension UX | 10 | passed_after_fix | In chat, a normal user can approve a workspace-local autonomy grant, watch capability chips appear, and understand creation/testing/repair without reading engine terms. | Live iPhone 17 Pro beta proof `sess_019e8d4a-8f85-77d0-bd3c-92c0f78f2fef` approved workspace-local autonomy, created a disposable helper, spawned workspace-visible `tprod_c::echo`, inspected and invoked it through `execute`, stopped the sandbox worker, discarded the helper file, and verified the helper was no longer visible. Fixes made during proof: approval replay now resumes host-dispatched primitives, worker protocol template waits for `catalog_snapshot`, execute propagates top-level workspace context, `worker::spawn` defaults workspace-autonomy child selectors to `workspace:<workspaceId>`, iOS/dashboard labels hide spawned-worker vocabulary, and docs now teach relative `worktree::discard_files` cleanup. Screenshots: `/tmp/tron-tprod-c-v10-approval.png`, `/tmp/tron-tprod-c-v10-relative-discard-approval.png`, `/tmp/tron-tprod-c-v10-dashboard-helper-labels-app.png`. | Closed. TPROD-D must turn this session-created capability evidence into a durable gallery/history surface. |
| TPROD-D | Created-by-agent gallery/history | 9 | passed_after_fix | A filter/shelf shows full lineage: created, updated, auto-repaired, tested, failed, promoted, revoked, discarded, and reused capabilities. | Renamed the former harness-change projection/card to `EngineConsoleCreatedByAgentProjection` and `EngineConsoleCreatedByAgentCard`, added product-facing shelf title/subtitle/history labels from server-owned implementation provenance, catalog functions, generated UI refs, audit events, and program runs, and split focused projection/source-guard tests. `xcodegen generate` passed; `EngineConsoleCreatedByAgentProjectionTests` passed with 2 tests; SourceGuard/accessibility/created-by-agent source guards passed with 20 tests; `EngineConsoleStateTests` passed with 12 tests. | Closed. TPROD-E must prove local disk pack install/manage through chat entry and Console/detail surfaces without remote discovery. |
| TPROD-E | Local capability pack install/manage | 9 | passed_after_fix | Local packs can be registered, inspected, configured, activated, disabled, rolled back, and removed through chat entry plus Console/detail surfaces. | Added canonical `module::remove_package` with CAS, active-activation fail-closed behavior, discarded package/config resources, and removed-pack configure/activate guards. Server action summaries now advertise register, inspect, configure, activate, disable, rollback, revoke-source-approval, and remove with product pack labels; generated pack surfaces use `Pack` vocabulary and stored `remove-package` actions. `self-extend`, the capability primer, README, and iOS architecture docs now name the local-only pack lifecycle. Engine Console renders the module projection as Packs, preserving server-owned action labels/targets and generated package/activation surface requests. Focused Rust lifecycle/registration/generated-surface tests and focused iOS pack projection tests passed. | Closed. TPROD-F must map trust, promotion, revocation, and cleanup states to plain product labels without client-owned trust or policy truth. |
| TPROD-F | Trust, promotion, revocation UX | 9 | passed_after_fix | Plain-language trust states map to real source approval, signature, conformance, promotion, revocation, and cleanup evidence. | Added server-owned `trustPresentation` rows to `control::snapshot.moduleSourceTrust`, deriving plain status/source/signature/approval/conformance/revocation/promotion/cleanup labels from package source evidence, source approvals, trust roots, warning refs, conformance refs, promotion evidence refs, and removed-pack resource state. iOS now requires and renders the server presentation object instead of mapping raw trust codes. Focused Rust tests covered revoked approval, signed trust-root authorization, signed trust-root expiry, and removed-pack cleanup labels; focused Engine Console state tests covered thin-client projection of server labels. | Closed. TPROD-G must complete generated UI authoring product coverage without client-owned target construction. |
| TPROD-G | Generated UI authoring | 9 | pending | Engine-authored native surfaces show preview, plain diff, allowed actions, validation state, and Inspect details; no iOS app update is needed for new capability surfaces. | `ui_surface` resources, generated UI primitives, validation, action submission, and iOS fixed-catalog renderer already exist. Product authoring coverage for all required surfaces is incomplete. | Extend generated authoring only through server-owned surfaces and test renderer/state coverage. |
| TPROD-H | Model, automation, and subagent routing | 10 | pending | Automations support model presets; local models are opt-in per flow; agents choose models within policy; subagent chips show task/model/result/lineage. | Subagent resource lineage exists. Settings include subagent model fields, but product presets and automation routing proof are incomplete. | Add policy model presets and subagent projection tests before UI. |
| TPROD-I | Tron replaces Codex for local work loop | 9 | pending | Flagship proof: a Tron chat session creates or updates a Tron helper capability/skill, tests it, updates docs, shows UI evidence, and reaches local review-ready state without push/merge/release. | The substrate self-extension loop is documented around `execute`, `worker::protocol_guide`, `worker::spawn`, conformance, generated UI, and cleanup. Full flagship proof is missing. | Requires TPROD-B through TPROD-H evidence first. |
| TPROD-J | Mixed real-world example packs | 6 | pending | Ship three polished local examples: Tron maintainer pack, everyday local automation pack, and creative/knowledge pack. | Existing first-party skills are managed, but the three product example packs do not exist as polished local packs. | Add examples with tests, docs, and no personal info literals. |
| TPROD-K | User, operator, and release-note docs | 5 | pending | User guide, operator guide, release-note-style product notes, README/progressive docs updates, and troubleshooting docs are current. | README and architecture docs describe current substrate. Product guide/operator/release-note docs for this campaign are not complete. | Update docs row-by-row with implementation. |
| TPROD-L | Hardening, visual QA, soak, and closeout gates | 12 | pending | Tiered worker soak, focused iOS visual matrix, Mac/CLI smoke, static absence gates, targeted tests, docs drift checks, and ledger closeout all pass. | This checkpoint adds the first static scorecard gate only. | Full closeout remains open until all rows are implemented and verified. |

## Required Scenarios

### Self-Extension Flagship

1. Start from ordinary Tron chat.
2. Grant workspace-local autonomy.
3. Use `self-extend`.
4. Create or update a local helper capability for maintaining Tron.
5. Show live capability chip progression.
6. Inspect generated function, conformance evidence, model/subagent choices,
   and generated UI.
7. Auto-repair one intentional failure with version history.
8. Promote only when explicitly requested; otherwise cleanup/discard cleanly.

### Pack Lifecycle

1. Install a local pack from disk.
2. Show source, trust, signature, and conformance in plain status.
3. Configure with generated UI.
4. Activate, run, disable, rollback, revoke, and remove.
5. Verify disconnected/offline states are read-only and fail closed.

### Model/Subagent/Automation

1. Create an automation with `Local when possible`.
2. Prove the chosen model is visible after the agent decides.
3. Prove hosted fallback is disclosed when local is unavailable.
4. Spawn at least two subagents with different model/task profiles.
5. Show parent/child lineage and result resources in chat and Console.

### Example Packs

1. Tron maintainer pack: repo health, test-summary, scorecard/evidence helper.
2. Everyday pack: local digest/organizer automation with notification delivery.
3. Creative/knowledge pack: prompt/notes transformation workflow with reusable
   generated UI.

## Test Plan

### Rust/Server

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `cargo check --manifest-path packages/agent/Cargo.toml`
- Targeted tests for external workers, module activation, generated UI,
  capability primer/recipes, cron jobs, model routing, subagent lifecycle,
  trust/revocation, and source guards.
- Add or identify regression tests before implementation for every new
  behavior.

### iOS

- `cd packages/ios-app && xcodegen generate`
- Targeted `xcodebuild test` coverage for generated UI rendering, Engine
  Console state/accessibility, capability invocation display, subagent state,
  cron client/types, model client/picker, settings parity, and source guards.

### Mac/CLI

- `cd packages/mac-app && xcodegen generate`
- Run focused Mac app tests or smoke where available.
- Verify CLI/help/operator paths document local pack and self-extension
  workflows without exposing release actions.

### Visual QA

- iPhone 17 Pro and iPad Pro 13-inch simulators.
- Light and dark mode.
- Default and large Dynamic Type for text-heavy surfaces.
- Screenshots for chat self-extension, capability chip detail,
  created-by-agent shelf, pack management, trust/promotion/revocation,
  generated UI preview/action, automation model preset, and subagent helpers.

### Soak

- Fast deterministic soak: repeated spawn/register/invoke/repair/disconnect/
  cleanup loop on temp ports.
- Extended soak before closeout: long-running local worker and automation loop
  proving catalog stability, reconnect behavior, cleanup, memory/resource
  drift, and stale worker failure modes.

### Static Gates

- No client-owned generated action targets, approval truth, policy, routing,
  source trust, or package trust.
- No remote package install/discovery path beyond explicit deferred docs.
- No stale README claims, scorecard planned rows marked complete without
  evidence, or dead compatibility surfaces.

## TPROD-A Baseline Audit

Baseline was audited on 2026-06-03 from branch
`next/modular-capability-engine` with no unstaged work.

- Engine substrate: README documents `worker::protocol_guide`,
  `worker::spawn`, generated `ui_surface` resources, local module package
  lifecycle, source trust/signature/revocation, activation records, conformance,
  and subagent result resources.
- iOS: `packages/ios-app/docs/architecture.md` documents a thin `/engine`
  client, capability-native chat/event rendering, Engine Console projections,
  generated UI renderer, disconnected read-only cache, server-owned approval,
  and no fixed Automations/Voice Notes dashboards.
- Mac: `packages/mac-app/docs/architecture.md` documents a wrapper around the
  headless server, managed skill sync, CLI dev takeover observation, and no
  second production policy owner.
- CLI/operator: `scripts/tron` remains the workspace dispatcher; deployment is
  excluded from this campaign.
- Skills: managed skills exist under `packages/agent/skills/`, but
  `self-extend` does not exist yet.
- Docs: the requested scorecard path was absent before this checkpoint; the
  plan was supplied as `/Users/moose/Downloads/PLAN.md`.

## Next Test

TPROD-G is active. The next required proof is the generated UI authoring
product matrix: engine-authored native surfaces must show preview, plain diff,
allowed actions, validation state, and Inspect details without requiring an iOS
app update for new capability surfaces.
