# Restoration Retrospective Audit Status

Status: `active`

Created: 2026-06-23

Current audit tracker lineage:

- The focused Slice 2 audit-fix branch starts from
  `821bfd90c3460f56e87aa5c707f6cf712531291a` on
  `codex/primitive-minimality-audit-closeout`.
- The prior tracker checkout `cfdc3c29962a1407a580721acf84a888968a7ee9` was
  recorded as the head of `codex/restoration-retrospective-audit-status-current`
  before the retrospective audit-fix pass.
- Baseline assumption: this is the accepted restoration baseline through
  Phase 2 Slice 5A after the final job-finalization cancel-race fix.

## Purpose

This tracker orders completed restoration-campaign slices for retrospective
adversarial audit. Audit threads must review existing claims and evidence first.
They must not implement product/runtime behavior unless a blocking or important
finding is accepted for a focused fix.

The queue includes foundation and closure slices that define the restoration
baseline, completed iOS affordance restoration work, accepted follow-up cleanup
that changed restored surfaces, Phase 2 planning and completed Phase 2
implementation slices, and committed hardening/fix sub-slices that close a
completed slice.

## Audit Constraints

- Review first. A per-slice audit thread inspects the slice, its evidence,
  invariants, and current source before proposing fixes.
- No future feature restoration during the retrospective. Deferred scope stays
  deferred unless the user explicitly starts a new restoration slice.
- Fixes are only for blocking or important findings, such as evidence drift,
  invariant gaps, authority leaks, data-loss races, security issues, or false
  user-facing claims.
- Preserve the foundational minimal/modular design: provider-visible execution
  remains the single `execute` primitive, and restored behavior must stay owned
  by packages/domains with explicit resources, streams, grants, replay evidence,
  tests, and docs.
- Distinguish real blockers from accepted deferred scope. Old legacy panels,
  PTY terminals, web/git/subagent/scheduler/native notification/native process
  UI, semantic memory engines, and risky default approval policies are not bugs
  merely because they remain absent.
- Do not run `tron deploy` or any production deployment command.

## Ordered Audit Queue

| Order | Slice | Phase | Range / final commit | Source of truth | Canonical files | Current acceptance evidence | Deferred scope to preserve | Likely audit focus |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Primitive Minimality Closure | Pre-restoration foundation | Baseline `7b03b51f`; final `1545da37d` | `codex/primitive-minimality-closure-current` | `primitive-minimality-closure-scorecard.md`; `primitive-minimality-closure-evidence-manifest.md`; `primitive-minimality-closure-inventory.md`; `primitive-minimality-closure-inventory.tsv`; `primitive_minimality_closure_invariants.rs` | Accepted by audit thread `019ef654-8726-7781-91bf-5bbb6f6321cd`; no blocking or important findings; score 100/100 and focused deletion/minimality tests remain accepted. | No successor features, provider-visible tool widening, settings/auth/DB/iOS DTO expansion, or deploy behavior. | Closed. Future cleanup: align the invariant endpoint constant with the documented slice boundary. |
| 2 | Baseline Pre-Restoration Closure | Pre-restoration foundation | Baseline `1545da37d`; final `4cb2387f1` | `codex/baseline-pre-restoration-closure-current`; tag `pre-restoration-baseline-2026-06-14` | `baseline-pre-restoration-closure-scorecard.md`; `baseline-pre-restoration-closure-evidence-manifest.md`; `baseline-pre-restoration-closure-inventory.md`; `baseline-pre-restoration-closure-inventory.tsv`; `baseline_pre_restoration_closure_invariants.rs`; `README.md` | Accepted by re-audit thread `019ef668-26d1-7123-924c-e7077c2232d2` after fix commit `9329dd1f92440500afd861293a9d4b6e981930ef`; no blocking, important, or non-blocking findings remain; BPRC and DESI invariants passed. | Approved restored roots `catalog_discovery`, `approval`, `jobs`, memory, and filesystem remain mapped to canonical Phase 2/BPRC lineage; deferred roots remain forbidden. | Closed. Preserve tracker active status and continue with Self-Updating Worker Runtime Foundation. |
| 3 | Self-Updating Worker Runtime Foundation | First post-BPRC restoration foundation | Baseline `4cb2387f1`; final `6aa395fdd`; retrospective fix branch `codex/slice-3-suwrf-audit-fixes` | `codex/self-updating-worker-runtime-foundation-current` plus retrospective fix commits | `self-updating-worker-runtime-foundation-scorecard.md`; `self-updating-worker-runtime-foundation-evidence-manifest.md`; `self-updating-worker-runtime-foundation-inventory.md`; `self-updating-worker-runtime-foundation-inventory.tsv`; `self_updating_worker_runtime_foundation_invariants.rs` | Original audit verdict and independent re-audit verdict were changes required. Retrospective fixes cover stop-to-enabled relaunch state, verified source-tree `packageDigest`, fail-closed unowned stops, fail-safe child drop, startup ownership-loss reconciliation, and fenced lifecycle requests that cannot launch while startup reconciliation is still scanning stale attempts. | No MCP, skills, memory, web/browser, scheduler, subagents, prompt library, program execution, fixed iOS product panels, provider-visible tool widening, or production deploy behavior. | Next re-audit should focus on adversarial confirmation of digest determinism/no exclusions, stop/relaunch lifecycle state, restart ownership-loss evidence, and startup/request ordering. |
| 4 | iOS Self-Adapting Agent Cockpit Baseline | iOS baseline | Baseline `6aa395fdd`; final `a0b80c7d2` | `codex/ios-agent-cockpit-baseline-current` | `ios-self-adapting-agent-cockpit-baseline-scorecard.md`; `ios-self-adapting-agent-cockpit-baseline-evidence-manifest.md`; `ios-self-adapting-agent-cockpit-baseline-inventory.md`; `ios-self-adapting-agent-cockpit-baseline-inventory.tsv`; `ios_self_adapting_agent_cockpit_baseline_invariants.rs` | Score 100/100; generic runtime/cockpit rendering, DTO/source guard, simulator evidence, README/iOS docs, and static gate coverage recorded. | No fixed product panels or restored old agent-execution surfaces. | Whether cockpit renders only server facts, stays diagnostics/generic, and does not imply hidden runtime truth. |
| 5 | iOS Affordance Restoration Map | Phase 1 planning | Baseline `a0b80c7d2`; map commit `d1fd79878`; current branch head `7db72c1ee` also contains Phase 2 plan | `codex/ios-affordance-restoration-map-current` | `ios-affordance-restoration-map-scorecard.md`; `ios-affordance-restoration-map-evidence-manifest.md`; `ios-affordance-restoration-map-inventory.md`; `ios-affordance-restoration-map-inventory.tsv`; `ios_affordance_restoration_map_invariants.rs`; `ios-affordance-restoration-progress.md` | Score 100/100; old tree census of 848 deleted/renamed iOS paths; Phase 1 queue and Phase 2 deferral anchor; invariant coverage recorded. | Mapping is not permission to restore legacy UI. Agent-execution-dependent surfaces remain Phase 2 or later. | Coverage gaps in old-path classification, overbroad grouping, stale queue state after closeout, and false implication that mapped affordances are shipped. |
| 6 | iOS Phase 1 Slice 1: Composer Attachment / Camera / Native Menu | Phase 1 iOS affordance restoration | Baseline after IARM; commits `473cce8b3`, `62b577047`, `84451c969`, `019f3b9ce`, `279fafe4e`; final native-menu cleanup later `d69afc6a1` | Progress ledger; `codex/ios-voice-dictation-affordance-current`; `codex/ios-prompt-input-snippet-affordance-current` for later label cleanup | `ios-affordance-restoration-progress.md`; `ios-affordance-restoration-map-evidence-manifest.md`; iOS attachment/camera/source-guard tests | Ledger records functional local actions only: Take Photo, Select Photos, Attach Files; native SwiftUI menu; removed custom sheet path; focused iOS tests and source guards. | Skills, prompt snippets, queue controls, plugin/catalog concepts, and old non-functional menu actions remain absent. | Local-only ownership, file/photo privacy, menu sizing/accessibility, source guards against old popup/actions, and interaction with later recent-input menu action. |
| 7 | iOS Phase 1 Slice 2: Composer Voice Transcription | Phase 1 iOS affordance restoration | Commits `c5f92eed3`, `ec3428283`, `abd396897`, `e095249be`; final branch head `4e66af302` includes accepted session-list/title work | `codex/ios-voice-dictation-affordance-current` | `ios-affordance-restoration-progress.md`; `ios-affordance-restoration-map-evidence-manifest.md`; transcription Rust/iOS tests; settings parity tests | Rust/iOS focused tests, readiness gating, live authenticated `/engine` probe, personal-info guard, whitespace, ignored-file, and physical-device install/launch with user confirmation recorded. | Voice notes, persistent media storage, media client, APNs/background delivery, fake transcription, and agent-execution voice surfaces remain absent. | Opt-in setting parity, local readiness states, temp-file cleanup, old-server failure UX, lifecycle cancel on chat exit, and physical-device evidence boundary. |
| 8 | Accepted Off-Plan: Session List Simplification and Native Title Generation | Phase 1 accepted follow-up | Commits `0f58806c5`, `4e66af302` | `codex/ios-voice-dictation-affordance-current`; progress ledger | `ios-affordance-restoration-progress.md`; session-list/title-generation tests; README/iOS docs where touched | User-confirmed device result; Rust title-generation tests; focused iOS session-list presentation tests; server restart note recorded. | Work overview, import tree, source-control graph, workspace analytics, old title hooks/skills/rules/subagents, existing-session backfill, and title management UI remain absent. | Race checks, event reconstruction, title sanitization/bounds, shutdown registration, no old hook/subagent restoration, and session-list accessibility/density. |
| 9 | iOS Phase 1 Slice 3: Recent Input History | Phase 1 iOS affordance restoration | Commits `16586ae07`, `3740b33a2`, `ad777a3dd`, `0655e7131`, `d69afc6a1`; progress reconciliation `48054db64` | `codex/ios-prompt-input-snippet-affordance-current` | `ios-affordance-restoration-progress.md`; `ios-affordance-restoration-map-evidence-manifest.md`; recent-input/input-history/attachment/source-guard tests | Focused iOS simulator tests, IARM invariant, XcodeGen, personal-info guard, whitespace, ignored-file, simulator install/launch, manual validation, and screenshot evidence recorded. | Snippets/templates, search/pagination/use counts, server prompt history, prompt-library APIs, generated prompt management, skills, queues, and routing remain absent. | Local UserDefaults retention/dedupe/clear, privacy, menu state gating, sheet ergonomics, and guards against old prompt-library surfaces. |
| 10 | iOS Phase 1 Slice 4: Chat Visual Cues / Status / Error Affordances | Phase 1 iOS affordance restoration | Commits `bb9057148`, `09d155bda`; reconciliation `f4cb11d68`; branch ref also has duplicate `87f53a0ca` | `codex/ios-chat-visual-cues-status-affordance-current`; progress ledger | `ios-affordance-restoration-progress.md`; chat visual/local notification/capability evidence/source-guard tests | Focused iOS simulator tests, render artifact tests, XcodeGen, reinstall/manual blank-content validation, personal-info guard, whitespace, ignored-file, and clean status recorded. | Fixed process/job/subagent/source-control/approval/memory/rules/hooks/skill/inbox panels, fake activity, notification expansion, and rich connection sheets remain deferred. | No fake chain-of-thought, local notification dedupe/lifecycle, capability evidence truthfulness, quiet empty/loading state, and source guards against old status panels. |
| 11 | iOS Phase 1 Slice 5: Settings / Onboarding / Diagnostics / Pairing Polish | Phase 1 iOS affordance restoration | Commit `3680ea271` | `codex/ios-settings-onboarding-diagnostics-pairing-current` | `ios-affordance-restoration-progress.md`; settings/onboarding/provider/server/source-guard tests; iOS docs | Focused iOS simulator tests, Computer Use validation, screenshots, IARM invariant, personal-info guard, whitespace, ignored-file recorded. | Fixed product session lists, APNs/device broker, skills/rules/memory/worktree/process/job/goal/subagent/approval/web state, fake server-health facts, new server settings, DB tables, auth/provider behavior remain absent. | Settings parity, provider id truthfulness, pairing repair vs new origin, diagnostics copy, feedback path, and no invented server facts. |
| 12 | Accepted Follow-Up: Cockpit Placement and Session-List Row Polish | Phase 1 accepted follow-up | Commits `becbc0e95`, `34c53dc93`, `22cb96e72`, `9d172aa27`, `0176379ba`; progress checkpoint `da53490c1` | `codex/ios-cockpit-placement-cleanup-current`; progress ledger | `ios-affordance-restoration-progress.md`; IOSAC/IARM invariants; session-list/cockpit/settings placement tests | Focused iOS tests, simulator/Computer Use evidence, IARM and IOSAC invariants, personal-info guard, whitespace, ignored-file recorded. | No notification inbox, APNs, device broker, worker launch flow, Phase 2 capability, or passive chat runtime banner. | Placement truthfulness, diagnostics-only cockpit access, native row interaction, no custom press feedback, and no passive idle signal in chat. |
| 13 | iOS Phase 1 Slice 6: Notification / Inbox Concept Review | Phase 1 iOS defer decision | Commit `ace41ac98`; closeout `fda2eaf6d` | `codex/ios-notification-inbox-concept-review-current`; progress ledger | `ios-affordance-restoration-progress.md`; `ios_affordance_restoration_map_invariants.rs`; BPRC/IARM docs | Defer decision; no Swift/UI changes; IARM invariant with defer guard, cargo fmt check, personal-info guard, whitespace, ignored-file recorded. | APNs, background push, device broker, notification resources, read state, app badge semantics, delivery chips, and tool-family notifications remain Phase 2/later. | Whether current source truly lacks fake notification owners; defer guard coverage; database/resource absence evidence; no local-only inbox implying backend truth. |
| 14 | Accepted Follow-Up: Server-Backed Workspace Browser | Phase 1 accepted follow-up / Phase 2 precursor | Commits `70780b798`, `f34ac1bdd`, `c818cc296`, `ceb6aab35`, `7a9de156b`, `8054ed17e`, `74a5564d3`, `38a88ede9`; reconciliation `980867c35` | `codex/ios-affordance-restoration-map-current`; progress ledger | `ios-affordance-restoration-progress.md`; filesystem workspace-browser docs/tests; IARM/BPRC invariants | Progress ledger records server-backed home/list/create-dir selector, compact UI follow-ups, and expected focused validation. | Native file/patch review UI, import, worktree, git, broad file-management/product panels, fake analytics, source-control surfaces remain absent. | Filesystem boundary separation from Phase 2 agent tools, server-fact rendering, path/root handling, hidden-folder behavior, create-dir authority, and selector reuse. |
| 15 | Phase 2 Agent Execution Restoration Plan | Phase 2 planning | Planning baseline `980867c35`; final `7db72c1ee` | `codex/ios-affordance-restoration-map-current` | `phase-2-agent-execution-restoration-scorecard.md`; `phase-2-agent-execution-restoration-evidence-manifest.md`; `phase-2-agent-execution-restoration-inventory.md`; `phase-2-agent-execution-restoration-inventory.tsv`; DESI/IARM/BPRC/SSARR/OPSAA invariants | Score 100/100; all 24 BPRC buckets mapped; ordered roadmap; memory architecture; validation protocol; handoff packet recorded. | Planning does not implement runtime behavior. Future slices still need user decisions and per-slice validation. | Roadmap completeness, stale closure text, inventory row status drift, deferral preservation, and handoff constraints. |
| 16 | Phase 2 Slice 1: Catalog Discovery Evidence | Phase 2 agent-execution restoration | Baseline `7db72c1ee`; commits `a9c3d3507`, `ca471fcde`, `680d9429f`; final `f95d3b02e` | `codex/phase-2-catalog-discovery-evidence-current` | Phase 2 scorecard/evidence/inventory; catalog discovery domain docs/tests; Runtime Cockpit tests; SACB/HRA/PCC/TPC/TMB/IARM/IOSAC/IOSTC/CSD invariants | Catalog search/inspect/conformance through `execute`; resource-backed reports; Runtime Cockpit Discovery; protected omission; many Rust/iOS/static validations recorded. | No target routing, intent execution, public `/engine` expansion, generated `ui_surface` publication, fixed legacy panels, schema repair, or old module copies. | Protected visibility, no target invocation, idempotency/lease/compensation, provider-visible singularity, cockpit DTO truthfulness, and log redaction hardening. |
| 17 | Phase 2 Slice 2: Approval Safety / Freshness + Schema Hardening | Phase 2 agent-execution restoration | Baseline `f95d3b02e`; final pre-hardening `5ea963008`; hardening final `301f61bc3` | `codex/phase-2-approval-safety-freshness-current`; `codex/phase-2-approval-schema-hardening-current` | Phase 2 scorecard/evidence/inventory; approval domain docs/tests; SACB/TMB/HRA/TPC/PCC/DRC/CSD/DESI invariants | Durable approval request/decision resources, lifecycle stream, idempotent decision recording, fail-closed checks, replay explanations, schema alignment guard, full Rust CI recorded. | Native iOS approval UI, risk taxonomy, default expiry policy, interruption behavior, per-package risky-action triggers, and unrelated capability behavior remain deferred. | Approval-is-not-authority boundary, stale version/idempotency, expiry/freshness determinism, schema/output drift, and denial behavior. |
| 18 | Phase 2 Slice 3: Memory Foundation + Scope Hardening | Phase 2 agent-execution restoration | Baseline `301f61bc3`; commits `29024b677`, `20dde9894`, `4c35b2119` | `codex/phase-2-memory-foundation-current` | Phase 2 scorecard/evidence/inventory; memory domain docs/tests; SACB/HRA/TMB/TPC/PCC/DRC/SSARR/CSD/BPRC/IARM/OPSAA/SUWRF/DESI invariants | Memory policy/status, resource definitions, redacted records, prompt traces, migration envelopes, scope hardening, no hidden body-context inclusion, full Rust CI and guards recorded. | Semantic/vector retrieval, embeddings, ranking, summarization, episodic retrieval, procedural rules/hooks/skills, automatic retention, native iOS memory UI, and unrelated features remain deferred. | Privacy and bodyRef custody, scope isolation, prompt trace freshness, policy inheritance, migration redaction, hidden memory leakage, and guard narrowing. |
| 19 | Phase 2 Slice 4: Filesystem Agent Tools + Truncated Snapshot Hardening | Phase 2 agent-execution restoration | Baseline `4c35b2119`; commits `27e5847c9`, `2650dd0b9` | `codex/phase-2-filesystem-agent-tools-current` | Phase 2 scorecard/evidence/inventory; filesystem domain docs/tests; SACB/TMB/HRA/TPC/PCC/BPRC/IARM/DESI/OPSAA invariants; provider message converter tests | Bounded read/list/find/glob/search/diff/write/edit/apply-patch through `execute`; path authority; symlink/traversal denial; patch/materialized resources; truncated snapshot refusal; personal-info guard recorded. | Jobs, git, web, subagents, memory/vector/procedural/scheduling, native file/patch UI, public DTO expansion, DB/settings/auth/provider changes, and production deploy remain deferred. | Path canonicalization, symlink escapes, bounded output, binary omission, exact edit/hash guards, preview/commit idempotency, rollback evidence, and provider prompt guardrails. |
| 20 | Phase 2 Slice 5A: Durable Jobs and Process Lifecycle + Race Hardening | Phase 2 agent-execution restoration | Baseline `1d35ac848` on `2650dd0b9`; commits `404290d06`, `4fb134c64`, `0d76be40d`; final `0d76be40d` | `codex/phase-2-jobs-process-lifecycle-current` | Phase 2 scorecard/evidence/inventory; jobs domain docs/tests; SACB/TMB/CSD/HRA/PCC/TPC/BPRC/IARM/OPSAA/PRG/DRC/DESI invariants | Durable `jobs` domain, `job_process` resources, bounded `execution_output`, lifecycle streams, start/status/list/log/cancel `execute` ops, process-group cleanup, cancellation/finalization race fixes, full Rust CI recorded. | PTY/interactive terminals, interpreter runtimes, git/source control, web/network research, subagents, scheduling, notifications, native iOS process panels, and queue-backed internal dispatch remain deferred. | Process-group cleanup, network denial fail-closed, output-drain bounds, terminal idempotency, cancel/completion races, stale-version retry, cleanup archiving, and no hidden queue grant. |

## Completed Audit: Primitive Minimality Closure

Audit thread: `019ef654-8726-7781-91bf-5bbb6f6321cd`

Verdict: `slice accepted`

Status: accepted with no blocking or important findings.

Accepted range:

- Documented baseline: `7b03b51f5476f5764e3813666137897af2f3cd3d`
- Documented final commit: `1545da37d3c6186fbc6613789bae3d4a5481f976`
- Audit verified `7b03b51f5476f5764e3813666137897af2f3cd3d` is an ancestor
  of `1545da37d3c6186fbc6613789bae3d4a5481f976`, and
  `1545da37d3c6186fbc6613789bae3d4a5481f976` is an ancestor of the current
  tracker checkout `cfdc3c29962a1407a580721acf84a888968a7ee9`.

Verification recorded by the audit:

- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_minimality_closure_invariants -- --nocapture`
  passed, 8 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::anthropic --lib -- --quiet`
  passed, 160 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::google::stream_handler --lib -- --quiet`
  passed, 16 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::shared::sse --lib -- --quiet`
  passed, 20 tests.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- `git status --short` was clean.

Accepted deferred scope:

- No successor features, provider-visible tool widening, settings/auth/DB/iOS
  DTO expansion, or deploy behavior is required for this slice.
- The audit manually verified the full
  `7b03b51f5476f5764e3813666137897af2f3cd3d..1545da37d3c6186fbc6613789bae3d4a5481f976`
  range had no forbidden public protocol, settings, auth, database, or iOS
  source expansion.

Non-blocking finding:

- `packages/agent/tests/primitive_minimality_closure_invariants.rs` hardcodes
  `CLOSEOUT_COMMIT` as `b7443240...`, while this tracker identifies the slice
  final as `1545da37d3c6186fbc6613789bae3d4a5481f976`. This does not block
  acceptance because the audit verified the documented full range manually.
  Future cleanup should update, rename, or split the endpoint constant so the
  gate matches the documented slice boundary.

## Completed Audit: Baseline Pre-Restoration Closure

Original audit thread: `019ef65b-3c3f-7b92-9c01-869f5e66e05e`

Original verdict: `changes required`

Fix thread: `019ef661-4751-76a1-a18c-2a569cbad71b`

Fix commit: `9329dd1f92440500afd861293a9d4b6e981930ef` (`Fix BPRC audit
lineage gates`) on `codex/bprc-audit-fix`

Independent re-audit thread: `019ef668-26d1-7123-924c-e7077c2232d2`

Re-audit verdict: `slice accepted`

Status: accepted with no blocking, important, or non-blocking findings after the
fix.

Accepted range:

- Documented baseline: `1545da37d3c6186fbc6613789bae3d4a5481f976`
- Documented final commit: `4cb2387f1a872f9fabaf58bdd88330065113b914`
- Re-audit verified `HEAD` descends from both the documented BPRC baseline and
  final commits.

Verification recorded by the re-audit:

- `git show --stat --oneline 9329dd1f92440500afd861293a9d4b6e981930ef`
  reported 3 changed files, scoped to `README.md`, the tracker doc, and the
  BPRC invariant test.
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
  passed, 8 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  passed, 9 tests.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.

Accepted deferred scope:

- README active wording now describes the current restoration baseline and the
  single `execute` provider surface without teardown branch/path language.
- BPRC invariants explicitly map approved restored roots `catalog_discovery`,
  `approval`, `jobs`, plus existing memory and filesystem, to canonical Phase 2
  and BPRC lineage.
- Deferred roots remain forbidden. This includes fixed product panels, MCP,
  web/git, prompt library, notifications, voice notes, subagents,
  scheduler/autostart, PTY terminals, semantic memory engines, risky default
  approval policies, unapproved DB migrations, deploy/install behavior, and
  other future restoration scope.
- The retrospective tracker remains active and does not claim the entire audit
  campaign is complete.

## Next Audit

The next slice to audit is **Self-Updating Worker Runtime Foundation**.

## Per-Slice Audit Start State

Per-slice audit may start from this queue. The first audit thread should remain
review-only until it records findings, separates real blockers from preserved
deferred scope, and identifies any focused fix that requires user acceptance.
