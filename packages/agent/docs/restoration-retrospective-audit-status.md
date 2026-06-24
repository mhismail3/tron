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
- Baseline assumption: this tracker records accepted retrospective audit state
  through Phase 2 Slice 5A after the stale durable job reconciliation fixes. It
  is not an all-slices integrated artifact branch; some canonical evidence
  remains branch-scoped and must be consolidated before any integrated
  acceptance claim.

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
| 3 | Self-Updating Worker Runtime Foundation | First post-BPRC restoration foundation | Baseline `4cb2387f1`; final `6aa395fdd`; retrospective fix branches `codex/slice-3-suwrf-audit-fixes`, `codex/slice-3-suwrf-audit-fixes-2`; fix commits `07c571b6b405a9cc97588fbb3adf113ea40578bf`, `f7ca654e4` | `codex/self-updating-worker-runtime-foundation-current` plus retrospective fix commits | `self-updating-worker-runtime-foundation-scorecard.md`; `self-updating-worker-runtime-foundation-evidence-manifest.md`; `self-updating-worker-runtime-foundation-inventory.md`; `self-updating-worker-runtime-foundation-inventory.tsv`; `self_updating_worker_runtime_foundation_invariants.rs` | Accepted by second re-audit thread `019ef68f-0293-75f3-b8dc-a8a30ba2b4d0` after two focused fix commits; no blocking or important findings remain. Fixes cover stop-to-enabled relaunch state, verified deterministic source-tree `packageDigest`, fail-closed unowned stops, fail-safe child drop, startup ownership-loss reconciliation, and fenced lifecycle requests that cannot launch while startup reconciliation is still scanning stale attempts. | No MCP, skills, memory, web/browser, scheduler, subagents, prompt library, program execution, fixed iOS product panels, provider-visible tool widening, or production deploy behavior. Crash-orphaned OS processes after ownership loss remain an accepted limitation; the system records unhealthy/lost-ownership evidence and relaunchable state. | Closed. Continue with iOS Self-Adapting Agent Cockpit Baseline. |
| 4 | iOS Self-Adapting Agent Cockpit Baseline | iOS baseline | Baseline `6aa395fdd`; final `a0b80c7d2`; retrospective fix branch `codex/slice-4-ios-cockpit-audit-fix`; fix commit `962164520b32bcc25ca24db41daf8bd27baad85f` | `codex/ios-agent-cockpit-baseline-current` plus retrospective fix commit | `ios-self-adapting-agent-cockpit-baseline-scorecard.md`; `ios-self-adapting-agent-cockpit-baseline-evidence-manifest.md`; `ios-self-adapting-agent-cockpit-baseline-inventory.md`; `ios-self-adapting-agent-cockpit-baseline-inventory.tsv`; `ios_self_adapting_agent_cockpit_baseline_invariants.rs` | Accepted by re-audit thread `019ef6a6-dc7b-7ff2-ae3f-ef9cc92148f7` after fix commit `962164520b32bcc25ca24db41daf8bd27baad85f`; no blocking, important, or non-blocking findings remain. Fixes preserve last good refresh facts while surfacing degraded refresh-failed status, and expose malformed live catalog decode diagnostics instead of silently dropping entries. | No fixed product panels, restored old agent-execution surfaces, passive chat runtime banner, provider-visible tool widening, public/settings/auth/DB/API expansion, or coupling to memory/filesystem/jobs internals. | Closed. Continue with iOS Affordance Restoration Map. |
| 5 | iOS Affordance Restoration Map | Phase 1 planning | Baseline `a0b80c7d2`; map commit `d1fd79878`; current branch head `7db72c1ee` also contains Phase 2 plan; retrospective fix branches `codex/iarm-audit-findings-fix`, `codex/iarm-reaudit-findings-fix`; fix commits `92b9357edaa3a64e7c2dfee3e41e95f391239637`, `c52205d3dc049c5fe8cc312588bec45c303cc90a` | `codex/ios-affordance-restoration-map-current` plus retrospective fix commits | `ios-affordance-restoration-map-scorecard.md`; `ios-affordance-restoration-map-evidence-manifest.md`; `ios-affordance-restoration-map-inventory.md`; `ios-affordance-restoration-map-inventory.tsv`; `ios_affordance_restoration_map_invariants.rs`; `ios-affordance-restoration-progress.md` | Accepted by second re-audit thread `019ef6c3-2174-7f31-8a9f-97fae37ae98e` after two focused fix commits; no blocking, important, or non-blocking findings remain. Historical map value and old-path coverage are preserved; IARM queue/handoff text is explicitly historical, Phase 2 live state points to approved Phase 2 artifacts and slice execution, physical-device evidence redacts the UUID, and stale-wording/UUID invariant coverage is normalized and bounded. | Mapping is not permission to restore legacy UI. Agent-execution-dependent surfaces remain Phase 2 or later; IARM planning evidence stays historical rather than live implementation state. | Closed. Continue with iOS Phase 1 Slice 1: Composer Attachment / Camera / Native Menu. |
| 6 | iOS Phase 1 Slice 1: Composer Attachment / Camera / Native Menu | Phase 1 iOS affordance restoration | Baseline after IARM; commits `473cce8b3`, `62b577047`, `84451c969`, `019f3b9ce`, `279fafe4e`; final native-menu cleanup later `d69afc6a1`; retrospective fix commit `e73ae67d3ba1c88fc96018d95a7234928675b26f` | Progress ledger; `codex/ios-voice-dictation-affordance-current`; `codex/ios-prompt-input-snippet-affordance-current` for later label cleanup; retrospective fix branch `codex/iarm-retrospective-audit-closeout` | `ios-affordance-restoration-progress.md`; `ios-affordance-restoration-map-evidence-manifest.md`; iOS attachment/camera/source-guard tests | Accepted by re-audit thread `019ef6d7-cc14-7e10-9f18-0c55a4870a5c` after fix commit `e73ae67d3ba1c88fc96018d95a7234928675b26f`; no blocking, important, or non-blocking findings remain. Camera preview stops the live capture session immediately after successful capture enters preview, and the ledger/evidence truthfully covers camera sheet, pickers, native-menu cleanup, exact commits, coverage, and simulator/device boundaries. | Skills, prompt snippets, queue controls, plugin/catalog concepts, old non-functional menu actions, backend/agent coupling, fake server truth, generated management surfaces, and the old custom attachment sheet path remain absent. | Closed. Continue with iOS Phase 1 Slice 2: Composer Voice Transcription. |
| 7 | iOS Phase 1 Slice 2: Composer Voice Transcription | Phase 1 iOS affordance restoration | Commits `c5f92eed3`, `ec3428283`, `abd396897`, `e095249be`; final branch head `4e66af302` includes accepted session-list/title work; retrospective fix commits `f2fb7c3303da51cb91893ff87b9d41af240702aa`, `9008894583d05fbc7848c290d2c0a75eea3e6109` | `codex/ios-voice-dictation-affordance-current` plus retrospective fix commits | `ios-affordance-restoration-progress.md`; `ios-affordance-restoration-map-evidence-manifest.md`; transcription Rust/iOS tests; settings parity tests | Accepted by second re-audit thread `019ef6fa-166f-7a40-ba0d-118af72f7f94` after two focused fix commits; no blocking or important findings remain. Fixes cancel in-flight transcription/upload on chat exit, prevent late transcript/error mutation after cancellation, and make recording startup cancellation-aware across readiness, permission, recorder engine startup, post-start, and auto-stop registration boundaries. | Voice notes, persistent media storage, media client, APNs/background delivery, fake transcription, and agent-execution voice surfaces remain absent. Local-native boundaries, temp-file cleanup, recorder cancellation, and readiness/settings behavior are preserved. | Closed. Continue with Accepted Off-Plan: Session List Simplification and Native Title Generation. |
| 8 | Accepted Off-Plan: Session List Simplification and Native Title Generation | Phase 1 accepted follow-up | Commits `0f58806c5`, `4e66af302`; retrospective fix commits `634fb7469`, `72a5b9c7` | `codex/ios-voice-dictation-affordance-current`; progress ledger; retrospective fix branches `codex/session-title-cache-audit-fix`, `codex/session-title-sync-legacy-normalize` | `ios-affordance-restoration-progress.md`; session-list/title-generation tests; README/iOS docs where touched | Accepted by second re-audit thread `019ef717-d7f4-78e3-b2d5-6684e400b59f` after two focused fix commits; no findings remain. New/fork local caches no longer seed workspace basenames as row titles, legacy nil-title sync clears only exact workspace-basename titles, and rows/accessibility use `listTitle`. | Work overview, import tree, source-control graph, workspace analytics, old title hooks/skills/rules/subagents, existing-session backfill, and title management UI remain absent. Server/generated titles remain authoritative; legitimate non-workspace local titles are preserved. | Closed. Continue with iOS Phase 1 Slice 3: Recent Input History. |
| 9 | iOS Phase 1 Slice 3: Recent Input History | Phase 1 iOS affordance restoration | Commits `16586ae07`, `3740b33a2`, `ad777a3dd`, `0655e7131`, `d69afc6a1`; progress reconciliation `48054db64`; retrospective fix commits `705253e16644b1b8f4c05f6a57533f320703df49`, `90784394899a88e9b7877c027905d6f6f0cd2d31` | `codex/ios-prompt-input-snippet-affordance-current` plus retrospective fix branches `codex/order-9-recent-input-history-fix`, `codex/order-9-recent-input-history-share-fix` | `ios-affordance-restoration-progress.md`; `ios-affordance-restoration-map-evidence-manifest.md`; recent-input/input-history/attachment/source-guard tests | Accepted by second re-audit thread `019ef733-d2a9-7961-8387-db21cb646ca9` after two focused fix commits; no findings remain. Recent input history persists only after successful `agent::prompt` server sends for normal composer and pending-share text paths; failure, empty text, and attachment-only paths do not persist attempted text. | Snippets/templates, search/pagination/use counts, server prompt history, prompt-library APIs, generated prompt management, skills, queues, routing, agent-execution behavior, fake backend truth, provider/public/auth/API drift, and broad refactors remain absent. | Closed. Continue with iOS Phase 1 Slice 4: Chat Visual Cues / Status / Error Affordances. |
| 10 | iOS Phase 1 Slice 4: Chat Visual Cues / Status / Error Affordances | Phase 1 iOS affordance restoration | Commits `bb9057148`, `09d155bda`; reconciliation `f4cb11d68`; branch ref also has duplicate `87f53a0ca`; retrospective fix branches `codex/order-10-ios-chat-affordance-audit-fixes`, `codex/order-10-ios-chat-affordance-preaccept-cleanup`; fix commits `ea2e01ec7e33a69136915b3c1a04c009b1dccfdc`, `a3d6ddcb0b088165af25cd798cddef65667dc74e` | `codex/ios-chat-visual-cues-status-affordance-current`; progress ledger plus retrospective fix commits | `ios-affordance-restoration-progress.md`; chat visual/local notification/capability evidence/source-guard tests | Accepted by second re-audit thread `019ef765-b32b-7431-bc6a-c1f7402ea901` after two focused fix commits; no findings remain. Pre-accept normal send and retry failures now surface as deduped local notifications after clearing composer/session processing, retry shares normal setup/reset behavior, and reconstruction failures render visible local load errors while successful empty/loading states stay quiet. | Fixed process/job/subagent/source-control/approval/memory/rules/hooks/skill/inbox panels, fake activity, notification expansion, rich connection sheets, fake backend truth, provider/public/auth/settings/API drift, and agent-execution restoration remain deferred. | Closed. Continue with iOS Phase 1 Slice 5: Settings / Onboarding / Diagnostics / Pairing Polish. |
| 11 | iOS Phase 1 Slice 5: Settings / Onboarding / Diagnostics / Pairing Polish | Phase 1 iOS affordance restoration | Commit `3680ea271`; retrospective fix commit `49b76afa3805eeed7b4f5847779cfb2eb69a8edf` | `codex/ios-settings-onboarding-diagnostics-pairing-current`; retrospective fix branch `codex/order-11-ios-settings-onboarding-polish-fix` | `ios-affordance-restoration-progress.md`; settings/onboarding/provider/server/source-guard tests; iOS docs | Accepted by re-audit thread `019ef77a-bce7-7d23-815f-2a06a719b79c` after fix commit `49b76afa3805eeed7b4f5847779cfb2eb69a8edf`; no findings remain. Active-server repair uses truthful re-pair wording, the real new-server path still uses `prefill: nil`, source guards pin label-to-prefill intent, and docs match the corrected behavior. | Fixed product session lists, APNs/device broker, skills/rules/memory/worktree/process/job/goal/subagent/approval/web state, fake server-health facts, new server settings, DB tables, auth/provider behavior, backend facts, diagnostics execution changes, and future agent-execution surfaces remain absent. | Closed. Continue with Accepted Follow-Up: Cockpit Placement and Session-List Row Polish. |
| 12 | Accepted Follow-Up: Cockpit Placement and Session-List Row Polish | Phase 1 accepted follow-up | Commits `becbc0e95`, `34c53dc93`, `22cb96e72`, `9d172aa27`, `0176379ba`; progress checkpoint `da53490c1`; retrospective fix commit `2b546ee9316ae758193b96b594a2002733e2afc9` | `codex/ios-cockpit-placement-cleanup-current`; progress ledger; retrospective fix branch `codex/order-12-cockpit-placement-repair-cta-fix` | `ios-affordance-restoration-progress.md`; IOSAC/IARM invariants; session-list/cockpit/settings placement tests; README/onboarding docs; settings source guards | Accepted by re-audit thread `019ef78e-d30c-7f82-96ab-206c34af2276` after fix commit `2b546ee9316ae758193b96b594a2002733e2afc9`; no findings remain. Active-server repair uses truthful re-pair wording, true new-server flow still uses `prefill: nil`, docs match behavior, and Order 12 cockpit/dashboard/session-row behavior remains intact. | No backend facts, server settings, provider/auth APIs, fake backend truth, diagnostics execution changes, worker lifecycle changes, future agent-execution surfaces, notification inbox, APNs, device broker, Phase 2 capability, or passive chat runtime banner. | Closed. Continue with iOS Phase 1 Slice 6: Notification / Inbox Concept Review. |
| 13 | iOS Phase 1 Slice 6: Notification / Inbox Concept Review | Phase 1 iOS defer decision | Commit `ace41ac98`; closeout `fda2eaf6d`; retrospective fix commit `0ff5d2b28de52dda2beb64245c1d6524ed835969` | `codex/ios-notification-inbox-concept-review-current`; progress ledger plus retrospective fix branch `codex/order-13-notification-inbox-concept-fix` | `ios-affordance-restoration-progress.md`; `ios_affordance_restoration_map_invariants.rs`; BPRC/IARM docs; iOS architecture doc | Accepted by re-audit thread `019ef7a8-1ac7-76d1-9024-4127a0cfdf71` after fix commit `0ff5d2b28de52dda2beb64245c1d6524ed835969`; no findings remain. Slice 6 is recorded as a defer/concept decision, not a runtime notification UI implementation; current line/tracker docs no longer claim it is next or pending implementation. | APNs, background push, device broker, notification resources, durable inbox storage, read state, app badge semantics, delivery chips, tool-family notifications, and agent-execution inbox remain Phase 2/later. | Closed. Continue with Accepted Follow-Up: Server-Backed Workspace Browser. |
| 14 | Accepted Follow-Up: Server-Backed Workspace Browser | Phase 1 accepted follow-up / Phase 2 precursor | Commits `70780b798`, `f34ac1bdd`, `c818cc296`, `ceb6aab35`, `7a9de156b`, `8054ed17e`, `74a5564d3`, `38a88ede9`; reconciliation `980867c35` | `codex/ios-affordance-restoration-map-current`; progress ledger | `ios-affordance-restoration-progress.md`; filesystem workspace-browser docs/tests; IARM/BPRC invariants | Accepted by audit thread `019ef7ae-6dd0-77f2-851b-78934da65718`; no blocking or important findings. Server-backed workspace browser is accepted as a workspace selector precursor only; authenticated engine clients keep first-party filesystem-browser access by design, without adding model-facing filesystem tools. | Native file/patch review UI, import, worktree, git, broad file-management/product panels, fake analytics, source-control surfaces, and Phase 2 model-facing filesystem tools remain absent. | Closed. Follow-up: align symlinked-directory advertisement/navigation behavior; tighten workspace path abbreviation to the server-returned home path. Continue with Phase 2 Agent Execution Restoration Plan. |
| 15 | Phase 2 Agent Execution Restoration Plan | Phase 2 planning | Planning baseline `980867c35`; final `7db72c1ee`; retrospective fix commit `737411eefa30aa5a9b7ebd040583e62c995ba48f` | Historical branch evidence at `codex/ios-affordance-restoration-map-current@7db72c1ee`; the files are not present on this tracker branch. | Historical branch-only files: `phase-2-agent-execution-restoration-scorecard.md`; `phase-2-agent-execution-restoration-evidence-manifest.md`; `phase-2-agent-execution-restoration-inventory.md`; `phase-2-agent-execution-restoration-inventory.tsv`; DESI/IARM/BPRC/SSARR/OPSAA invariants on that source branch. | Accepted by re-audit thread `019ef7c2-a23a-7cf3-80c9-21695a1f84f1` after focused fix commit `737411eefa30aa5a9b7ebd040583e62c995ba48f`; no findings remain. Historical plan evidence reports score 100/100, all 24 BPRC buckets mapped, ordered roadmap, memory architecture, validation protocol, and handoff packet. Current-line integrated acceptance still requires a final consolidation branch/audit that ports or truthfully supersedes branch-scoped artifacts before claiming one integrated accepted state. | Planning does not implement runtime behavior. Future slices still need user decisions and per-slice validation. | Closed. Continue with Phase 2 Slice 1: Catalog Discovery Evidence. |
| 16 | Phase 2 Slice 1: Catalog Discovery Evidence | Phase 2 agent-execution restoration | Baseline `7db72c1ee`; commits `a9c3d3507`, `ca471fcde`, `680d9429f`; final `f95d3b02e`; retrospective fix commit `e9fb48c3b9469d4b8122ab76c299eba3832df8c0` | Historical branch evidence at `codex/phase-2-catalog-discovery-evidence-current@f95d3b02e`; the canonical artifacts and implementation files are not present on this tracker branch. | Historical branch-only files: `phase-2-agent-execution-restoration-scorecard.md`; `phase-2-agent-execution-restoration-evidence-manifest.md`; `phase-2-agent-execution-restoration-inventory.md`; `phase-2-agent-execution-restoration-inventory.tsv`; `packages/agent/src/domains/catalog_discovery/`; Runtime Cockpit Discovery tests; SACB/HRA/PCC/TPC/TMB/IARM/IOSAC/IOSTC/CSD invariants on that source branch. | Accepted by re-audit thread `019ef7ce-cb06-7242-9361-06e28bf01aa9` after focused tracker/docs fix commit `e9fb48c3b9469d4b8122ab76c299eba3832df8c0`; no findings remain. Historical branch-scoped evidence records catalog search/inspect/conformance through `execute`, resource-backed reports, Runtime Cockpit Discovery, protected omission, and Rust/iOS/static validations. Current-line integrated acceptance still requires a final consolidation branch/audit that ports or truthfully supersedes branch-scoped artifacts before claiming one integrated accepted state. | No target routing, intent execution, public `/engine` expansion, generated `ui_surface` publication, fixed legacy panels, schema repair, or old module copies. | Closed. Continue with Phase 2 Slice 2: Approval Safety / Freshness + Schema Hardening. |
| 17 | Phase 2 Slice 2: Approval Safety / Freshness + Schema Hardening | Phase 2 agent-execution restoration | Baseline `f95d3b02e`; final pre-hardening `5ea963008`; hardening final `301f61bc3` | Historical branch evidence at `codex/phase-2-approval-safety-freshness-current` and `codex/phase-2-approval-schema-hardening-current@301f61bc3`; the canonical artifacts and implementation files are not present on this tracker branch. | Historical branch-only files: Phase 2 scorecard/evidence/inventory; `packages/agent/src/domains/approval/`; approval domain docs/tests; SACB/TMB/HRA/TPC/PCC/DRC/CSD/DESI invariants on the source branches. | Accepted by audit thread `019ef7d6-60f7-79f0-a39f-2ab59fb44ae6`; no findings remain. Historical branch-scoped evidence records durable approval request/decision resources, lifecycle stream, idempotent decision replay through engine idempotency, stale version conflict, deterministic `check_approval_at`, fail-closed denial/expiry/pending/missing/malformed/stale/scope mismatch, schema alignment guard, replay/evidence explanations, approval-is-not-authority metadata, and full Rust CI. Current-line integrated acceptance still requires a final consolidation branch/audit that ports or truthfully supersedes branch-scoped artifacts before claiming one integrated accepted state. | Native iOS approval UI, risk taxonomy, default expiry policy, interruption behavior, per-package risky-action triggers, and unrelated capability behavior remain deferred. | Closed. Continue with Phase 2 Slice 3: Memory Foundation + Scope Hardening. |
| 18 | Phase 2 Slice 3: Memory Foundation + Scope Hardening | Phase 2 agent-execution restoration | Baseline `301f61bc3`; original commits `29024b677`, `20dde9894`, `4c35b2119`; accepted fix commit `be1300934fb36ec9bac650eedfee933c9daf0d9d` | Historical branch evidence at `codex/phase-2-memory-foundation-current@4c35b2119` plus accepted fix ref `codex/order-18-memory-bodyref-recursive-validation@be1300934fb36ec9bac650eedfee933c9daf0d9d`; the canonical artifacts, memory implementation, and fix files are not present on this tracker branch. | Historical branch-only files: Phase 2 scorecard/evidence/inventory; memory domain docs/tests; SACB/HRA/TMB/TPC/PCC/DRC/SSARR/CSD/BPRC/IARM/OPSAA/SUWRF/DESI invariants on the source/fix branches. | Accepted by independent re-audit thread `019ef7ee-0b9b-7213-a51c-d66a89e8b483` after focused fix commit `be1300934fb36ec9bac650eedfee933c9daf0d9d`; no findings remain. Historical branch-scoped evidence records memory policy/status, resource definitions, redacted records, prompt traces, migration envelopes, scope hardening, no hidden body-context inclusion, recursive `bodyRef` inline-body rejection, full Rust CI, and guards. Current-line integrated acceptance still requires a final consolidation branch/audit that ports or truthfully supersedes branch-scoped artifacts before claiming one integrated accepted state. | Semantic/vector retrieval, embeddings, ranking, summarization, episodic retrieval, procedural rules/hooks/skills, automatic retention, native iOS memory UI, and unrelated features remain deferred. | Closed. Continue with Phase 2 Slice 4: Filesystem Agent Tools + Truncated Snapshot Hardening. |
| 19 | Phase 2 Slice 4: Filesystem Agent Tools + Truncated Snapshot Hardening | Phase 2 agent-execution restoration | Baseline `4c35b2119`; original commits `27e5847c9`, `2650dd0b9`; accepted fix commits `6c53f3ee9761efce0539363e2c54dd1b80b4f735`, `b373a367887d5fb114ed66fdc1023401bcd0aaa5` | Historical branch evidence at `codex/phase-2-filesystem-agent-tools-current@2650dd0b9` plus accepted fix refs `codex/order-19-filesystem-tools-fix@6c53f3ee9761efce0539363e2c54dd1b80b4f735` and `codex/order-19-filesystem-tools-docs-followup@b373a367887d5fb114ed66fdc1023401bcd0aaa5`; the canonical artifacts, filesystem implementation, and fix files are not automatically current-line integrated on this tracker branch. | Historical branch-only files: Phase 2 scorecard/evidence/inventory; filesystem domain docs/tests; SACB/TMB/HRA/TPC/PCC/BPRC/IARM/DESI/OPSAA invariants; provider message converter tests on the source/fix branches. | Accepted by independent re-audit thread `019ef810-db9e-7081-a64f-265c781ea15c` after focused fix commits `6c53f3ee9761efce0539363e2c54dd1b80b4f735` and `b373a367887d5fb114ed66fdc1023401bcd0aaa5`; no blocking or important findings remain. Historical branch-scoped evidence records hardened `filesystem_*` operations through `execute`, legacy `file_read` / `file_write` removal from model-visible dispatch, relative path authority, canonical root checks, symlink escape denial, preview/commit idempotency, hash guards, patch/materialized evidence, bounded output, binary omission, truncated snapshot refusal, and corrected provider/evidence wording. Current-line integrated acceptance still requires a final consolidation branch/audit that ports or truthfully supersedes branch-scoped artifacts before claiming one integrated accepted state. | Jobs, git, web, subagents, semantic/vector/procedural/scheduling work, native file/patch UI, public DTO expansion, unrelated DB/settings/auth/provider expansion, and production deploy behavior remain deferred. | Closed. Continue with Phase 2 Slice 5A: Durable Jobs and Process Lifecycle + Race Hardening. |
| 20 | Phase 2 Slice 5A: Durable Jobs and Process Lifecycle + Race Hardening | Phase 2 agent-execution restoration | Baseline `1d35ac848` on `2650dd0b9`; original commits `404290d06`, `4fb134c64`, `0d76be40d`; accepted fix commits `8702a7e8cb6346d29ac5247ee87344f34b766143`, `d57aaf83e94693e2eaefde16108202ea4e254e5e` | Historical branch evidence at `codex/phase-2-jobs-process-lifecycle-current@0d76be40d` plus accepted fix refs `codex/order-20-jobs-process-lifecycle-fix@8702a7e8cb6346d29ac5247ee87344f34b766143` and `codex/order-20-jobs-process-lifecycle-reconcile-targeted@d57aaf83e94693e2eaefde16108202ea4e254e5e`; the canonical artifacts, jobs implementation, and fix files are not automatically current-line integrated on this tracker branch. | Historical branch-only files: Phase 2 scorecard/evidence/inventory; jobs domain docs/tests; SACB/TMB/CSD/HRA/PCC/TPC/BPRC/IARM/OPSAA/PRG/DRC/DESI invariants on the source/fix branches. | Accepted by independent re-audit thread `019ef83d-dc76-7031-ae09-8774db2443f4` after focused fix commits `8702a7e8cb6346d29ac5247ee87344f34b766143` and `d57aaf83e94693e2eaefde16108202ea4e254e5e`; no findings remain. Historical branch-scoped evidence records durable `jobs` domain, `job_process` resources, bounded `execution_output`, lifecycle streams, start/status/list/log/cancel `execute` ops, process-group cleanup, cancellation/finalization race fixes, stale running-state reconciliation after restart/crash, targeted status/log/cancel reconciliation after scope validation, and SACB/CSD coverage for `packages/agent/src/domains/jobs/race_tests.rs`. Current-line integrated acceptance still requires a final consolidation branch/audit that ports or truthfully supersedes branch-scoped artifacts before claiming one integrated accepted state. | PTY/interactive terminals, interpreter runtimes, git/source control, web/network research, subagents, scheduling, notifications, native iOS process panels, public DTO expansion, production deploy behavior, unrelated settings/auth/provider changes, and queue-backed internal dispatch remain deferred. | Closed. Continue with Phase 2 Slice 6: Git, Worktrees, And Source Control. |

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

## Completed Audit: Self-Updating Worker Runtime Foundation

Original audit thread: `019ef66e-abb2-7b10-83f6-71e28600b429`

Original verdict: `changes required`

First fix thread: `019ef675-6ade-7490-b992-1f36db960c59`

First fix commit: `07c571b6b405a9cc97588fbb3adf113ea40578bf`
(`codex/slice-3-suwrf-audit-fixes`)

First independent re-audit thread: `019ef682-41d2-7c81-bfcc-fedb43cee0fb`

First re-audit verdict: `changes required`, due to the startup reconciliation
and lifecycle request race.

Second fix thread: `019ef686-bfad-74b3-8b5f-2abfd3c8d683`

Second fix commit: `f7ca654e4` (`codex/slice-3-suwrf-audit-fixes-2`)

Second independent re-audit thread: `019ef68f-0293-75f3-b8dc-a8a30ba2b4d0`

Second re-audit verdict: `slice accepted`

Status: accepted with no blocking or important findings after the second fix.

Accepted result:

- Stop no longer leaves package or installation state stuck running.
- `packageDigest` is verified against deterministic source-tree bytes.
- Unowned stop and ownership loss are fail-closed and truthful.
- Startup reconciliation is fenced before lifecycle operations so it cannot
  downgrade current owned launches.
- Worker lifecycle remains isolated from memory, filesystem, and jobs internals.
- No public/provider/iOS/settings/auth/API surface widening was introduced.

Accepted limitation:

- Crash-orphaned OS processes cannot be killed after ownership is already lost.
  The system records unhealthy/lost-ownership evidence and relaunchable state.

Verification recorded by the accepted re-audit:

- `cargo test --manifest-path packages/agent/Cargo.toml --test self_updating_worker_runtime_foundation_invariants -- --nocapture`
  passed, 9 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml worker_lifecycle -- --quiet`
  passed, 16 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml lifecycle_launch_waits_for_startup_reconciliation_before_spawning_process -- --nocapture`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
  passed, 8 tests.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.

## Completed Audit: iOS Self-Adapting Agent Cockpit Baseline

Original audit thread: `019ef696-2f4d-7f91-8a9c-6403cdbeff3c`

Original verdict: `changes required`

Fix thread: `019ef69b-5651-7d33-b551-1a3de6ec28ce`

Fix commit: `962164520b32bcc25ca24db41daf8bd27baad85f`
(`codex/slice-4-ios-cockpit-audit-fix`)

Independent re-audit thread: `019ef6a6-dc7b-7ff2-ae3f-ef9cc92148f7`

Re-audit verdict: `slice accepted`

Status: accepted with no blocking, important, or non-blocking findings after the
fix.

Accepted result:

- Refresh failures no longer fabricate a connected empty/Idle cockpit. The view
  model preserves last good facts and projects explicit degraded refresh-failed
  status.
- Malformed live catalog entries are no longer silently dropped. Decode
  diagnostics surface through projection/UI and issue counts, and lossy helper
  APIs were removed.
- The Runtime Cockpit boundary remains under Settings -> Servers -> Diagnostics
  -> Runtime Cockpit.
- No passive chat banner, fixed product panels, provider-visible tool widening,
  public/settings/auth/DB/API expansion, or coupling to memory/filesystem/jobs
  internals was introduced.

Accepted deferred scope:

- Fixed product panels, restored old agent-execution surfaces, passive chat
  runtime banners, public cockpit/API expansion, settings/auth/database
  expansion, and cross-domain coupling to memory/filesystem/jobs remain out of
  scope for this slice.

Verification recorded by the accepted re-audit:

- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_self_adapting_agent_cockpit_baseline_invariants -- --nocapture`
  passed, 11 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  passed, 9 tests.
- `cd packages/ios-app && xcodegen generate` succeeded and the worktree stayed
  clean.
- Focused simulator tests for WorkerLifecycle DTO/client/state/view-model plus
  SourceGuard tests passed, 74 tests.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- Final `git status --short` was clean.

## Completed Audit: iOS Affordance Restoration Map

Original audit thread: `019ef6ae-2063-7f22-a4dd-c3b7589c2212`

Original verdict: `changes required`

First fix thread: `019ef6b2-529b-7bb1-a3cb-a52b3086f049`

First fix commit:
`92b9357edaa3a64e7c2dfee3e41e95f391239637`
(`codex/iarm-audit-findings-fix`)

First independent re-audit thread: `019ef6b9-93fa-75f1-b7f5-554a6a149822`

First re-audit verdict: `changes required`

Second fix thread: `019ef6bd-a881-7700-ba6d-7096d7f12b56`

Second fix commit:
`c52205d3dc049c5fe8cc312588bec45c303cc90a`
(`codex/iarm-reaudit-findings-fix`)

Second independent re-audit thread: `019ef6c3-2174-7f31-8a9f-97fae37ae98e`

Second re-audit verdict: `slice accepted`

Status: accepted with no blocking, important, or non-blocking findings after
the second fix.

Accepted result:

- IARM queue and handoff text is explicitly historical, not live
  implementation state.
- Phase 2 live state points to existing approved Phase 2 artifacts and
  execution of approved Phase 2 slices, not a future full Phase 2 goal-plan
  effort.
- Physical iOS device evidence redacts the device UUID and uses generic
  selectors.
- IARM invariant coverage uses normalized stale-wording checks and bounded
  contextual UUID detection, with wrapped Markdown regressions.
- Historical IARM map value and old-path coverage remain preserved.
- No runtime or iOS product source changed.

Accepted limitations:

- The map remains planning and audit evidence. It does not imply mapped legacy
  affordances are shipped product behavior.
- Agent-execution-dependent surfaces remain governed by approved Phase 2
  artifacts and completed Phase 2 slice execution records.

Verification recorded by the accepted re-audit:

- `git show --stat --oneline c52205d3dc049c5fe8cc312588bec45c303cc90a`
  reported a docs/test-only change with 2 files changed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed, 12 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  passed, 9 tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- Final `git status --short --branch` was a clean detached HEAD in the review
  worktree.

## Completed Audit: iOS Phase 1 Slice 1 Composer Attachment / Camera / Native Menu

Original audit thread: `019ef6ca-5a03-7f93-ada5-820e7d80fe2e`

Original verdict: `changes required`

Fix thread: `019ef6ce-28ab-7991-b92b-b43fdf4eb27d`

Fix commit: `e73ae67d3ba1c88fc96018d95a7234928675b26f`
(`Fix Slice 1 camera preview audit gaps`) on
`codex/iarm-retrospective-audit-closeout`

Independent re-audit thread: `019ef6d7-cc14-7e10-9f18-0c55a4870a5c`

Re-audit verdict: `slice accepted`

Status: accepted with no blocking, important, or non-blocking findings after
the fix.

Accepted result:

- Camera preview now stops the live `AVCaptureSession` immediately after
  successful capture enters preview.
- Sheet disappear cleanup remains idempotent, and `retake()` remains the
  preview-to-live restart path.
- Slice 1 ledger and evidence truthfully cover the camera sheet, photo picker,
  file picker, native-menu cleanup, exact commits, focused coverage, and
  simulator/device validation boundaries without overclaiming physical-device
  manual validation.
- The slice remains local-native only. It does not couple to backend/agent
  behavior, fake server truth, the old custom attachment sheet path,
  skills/snippets/queues/plugin/catalog/generated management surfaces, or old
  non-functional menu actions.

Accepted deferred scope:

- Skills, prompt snippets/templates, queue controls, plugin/catalog concepts,
  generated management surfaces, and old non-functional attachment menu actions
  remain absent.
- Backend/agent coupling and fake server truth remain out of scope for this
  Phase 1 local-native slice.
- Physical-device manual validation is not overclaimed beyond the recorded
  simulator/device validation boundaries.

Verification recorded by the accepted re-audit:

- Focused iOS tests passed: 6 `AttachmentMenuTests` plus 52
  `SourceGuardTests`.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed, 13 tests; existing provider dead-code warnings only.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- XcodeGen `project.pbxproj` consistency was checked in a temporary copy, and
  the generated project matched.
- The re-audit worktree remained clean.

## Completed Audit: iOS Phase 1 Slice 2 Composer Voice Transcription

Original audit thread: `019ef6e0-1bd8-7fd3-ab94-9d627b526fab`

Original verdict: `changes required`

First fix thread: `019ef6e5-73f5-70b3-bc54-63c35f88a38e`

First fix commit: `f2fb7c3303da51cb91893ff87b9d41af240702aa`
(`Fix chat exit transcription cancellation`) on
`codex/slice-7-transcription-cancel-fix`

First independent re-audit thread: `019ef6ed-0ac7-76b3-b41e-1c22a5ef39cd`

First re-audit verdict: `changes required`, due to the async microphone
permission/startup cancellation race.

Second fix thread: `019ef6f1-f80d-7aa1-a1ef-a2f89a173bc6`

Second fix commit: `9008894583d05fbc7848c290d2c0a75eea3e6109`
(`Fix composer transcription startup cancellation`) on
`codex/slice-7-transcription-startup-cancel-fix`

Second independent re-audit thread: `019ef6fa-166f-7a40-ba0d-118af72f7f94`

Second re-audit verdict: `slice accepted`

Status: accepted with no blocking or important findings after the second fix.

Accepted result:

- In-flight transcription/upload is a stored cancellable task, and chat exit
  cancels it.
- Late transcript completion cannot mutate draft/input or error state after
  cancellation.
- Recording startup is cancellation-aware across readiness, microphone
  permission, recorder engine startup, post-start, and auto-stop registration
  boundaries.
- Cancellation wins over late non-cancellation readiness/startup errors after
  chat exit.
- Temp-file cleanup, recorder cancellation, readiness/settings behavior, and
  local-native boundaries are preserved.
- No fake transcription, persistent audio/media storage, APNs/background
  delivery, provider/public/auth/API drift, agent-execution voice surface, dead
  fallback, or speculative abstraction was introduced.

Accepted deferred scope:

- Voice notes, persistent audio/media storage, media client behavior,
  APNs/background delivery, fake transcription, and agent-execution voice
  surfaces remain absent.
- Provider/public/auth/API changes, persistent audio uploads beyond the existing
  local transcription boundary, dead fallbacks, and speculative abstractions
  remain out of scope for this Phase 1 local-native slice.

Verification recorded by the accepted re-audit:

- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- `scripts/personal-info-guard.sh` passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed, 13 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml transcription --lib`
  passed, 8 tests.
- Focused `xcodebuild` test
  `TronMobileTests/ChatTranscriptionCoordinatorTests` passed, 12 tests.
- Focused `xcodebuild` test `TronMobileTests/SourceGuardTests` passed, 52
  Swift Testing tests.

## Completed Audit: Accepted Off-Plan Session List Simplification and Native Title Generation

Original audit thread: `019ef702-5bf2-7a82-ab5f-01720bc3283e`

Original verdict: `changes required`

First fix thread: `019ef707-a8de-78c1-8ca5-85799d6d196c`

First fix commit: `634fb74696cfbd324cb96cf6509072cc6bd4f3b7`
(`Fix local session title cache fallback`) on
`codex/session-title-cache-audit-fix`

First independent re-audit thread: `019ef70e-4538-7a40-98bd-86a1f52cbb73`

First re-audit verdict: `changes required`, due to nil-title sync preserving
pre-fix stale workspace-basename titles.

Second fix thread: `019ef712-6975-7d60-a188-9119614fddb9`

Second fix commit: `72a5b9c7c21a9ea053402b8feae6dde5d8f10913`
(`Normalize legacy workspace titles during sync`) on
`codex/session-title-sync-legacy-normalize`

Second independent re-audit thread: `019ef717-d7f4-78e3-b2d5-6684e400b59f`

Second re-audit verdict: `slice accepted`

Status: accepted with no findings after the second fix.

Accepted result:

- New local session cache no longer promotes workspace basename into
  `CachedSession.title`.
- Fork/local cache no longer seeds workspace basename as title.
- Sync merge clears only legacy cached titles that exactly equal existing or
  server workspace basename when server title is nil or blank.
- Server/generated titles remain authoritative, and legitimate non-workspace
  local titles are preserved.
- Cleared legacy titles fall back through `listTitle` to `lastUserPrompt` or
  `New Session`.
- Session rows and accessibility use `listTitle`; workspace names remain
  grouping/header metadata.

Accepted deferred scope:

- Work overview, import tree, source-control graph, workspace analytics, old
  title hooks/skills/rules/subagents, existing-session backfill, and title
  management UI remain absent.
- Future agent-execution behavior, fake backend truth, provider/public/auth/API
  drift, broad refactors, and runtime documentation overclaims remain out of
  scope for this accepted off-plan follow-up.

Verification recorded by the accepted re-audit:

- Focused `xcodebuild` for `TronMobileTests/CachedSessionTests`,
  `TronMobileTests/SessionListPresentationTests`, and
  `TronMobileTests/SourceGuardTests` passed, 18 selected XCTest tests plus 52
  source guard tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- The review worktree was clean.

## Completed Audit: iOS Phase 1 Slice 3 Recent Input History

Original audit thread: `019ef71e-b36d-70d3-a7c2-06d5a339e8d2`

Original verdict: `changes required`, because recent inputs were retained before
successful send.

First fix thread: `019ef724-299f-7ec3-90c9-755b07b1280a`

First fix commit: `705253e16644b1b8f4c05f6a57533f320703df49`
(`Fix recent input history send boundary`) on
`codex/order-9-recent-input-history-fix`

First independent re-audit thread: `019ef72b-868e-7562-8066-6c3b6ddab0ae`

First re-audit verdict: `changes required`, because pending-share text sends in
`ChatView.swift` bypassed recent input persistence.

Second fix thread: `019ef72f-9f4d-7a73-a26e-a7288e542542`

Second fix commit: `90784394899a88e9b7877c027905d6f6f0cd2d31`
(`Fix shared prompt recent input history`) on
`codex/order-9-recent-input-history-share-fix`

Second independent re-audit thread: `019ef733-d2a9-7961-8387-db21cb646ca9`

Second re-audit verdict: `slice accepted`

Status: accepted with no findings after the second fix.

Accepted result:

- Recent input history persists only after successful `agent::prompt` server
  sends for normal composer and pending-share text paths.
- Subscription failure, server-send failure, empty text, and attachment-only
  sends do not persist attempted text.
- Successful text sends persist trimmed text through local `InputHistoryStore`,
  preserving UserDefaults ownership, dedupe/order, and the 100-entry cap.
- Dead legacy `TextFieldWithHistory` was removed after source/test reference
  search.
- Source guards cover the normal composer path, pending-share path,
  local-native scope, and no backend prompt-history routing.

Accepted deferred scope:

- Snippets/templates, search/pagination/use counts, server prompt history,
  prompt-library APIs, generated prompt management, skills, queues, and routing
  remain absent.
- Agent-execution behavior, fake backend truth, provider/public/auth/API drift,
  and broad refactors remain out of scope for this Phase 1 local-native slice.

Verification recorded by the accepted re-audit:

- Focused `xcodebuild` selected `TronMobileTests/MessagingCoordinatorTests`,
  `TronMobileTests/InputHistoryStoreTests`,
  `TronMobileTests/RecentInputHistoryTests`, and
  `TronMobileTests/SourceGuardTests`; 56 XCTest cases plus 53 source-guard tests
  passed.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- The review worktree had no edits or commits.

## Completed Audit: iOS Phase 1 Slice 4 Chat Visual Cues / Status / Error Affordances

Original audit thread: `019ef73c-0509-7eb0-a4d3-ebc257b8b9cd`

Original verdict: `changes required`, because server-send failures bypassed
local notifications, retry bypassed normal subscription/status reset, and
session reconstruction failure could render as quiet blank chat.

First fix thread: `019ef742-e80b-7923-8127-34f6fcf5c65d`

First fix commit: `ea2e01ec7e33a69136915b3c1a04c009b1dccfdc`
(`Fix chat affordance audit regressions`) on
`codex/order-10-ios-chat-affordance-audit-fixes`

First independent re-audit thread: `019ef75a-96d2-71b0-9ca7-ac25e1b5b853`

First re-audit verdict: `changes required`, because pre-accept normal send and
retry failures appended local notifications but left `isProcessing` and
session-processing stuck.

Second fix thread: `019ef760-23ee-7d53-84b5-edfcde1a6f08`

Second fix commit: `a3d6ddcb0b088165af25cd798cddef65667dc74e`
(`Fix pre-accept chat send cleanup`) on
`codex/order-10-ios-chat-affordance-preaccept-cleanup`

Second independent re-audit thread: `019ef765-b32b-7431-bc6a-c1f7402ea901`

Second re-audit verdict: `slice accepted`

Status: accepted with no findings after the second fix.

Accepted result:

- Server-send and other pre-accept failures surface as deduped local
  notifications, not generic `.error`, and later prompt-start clears stale local
  notifications.
- Normal prompt-send and retry-send pre-accept failures reset `isProcessing` and
  `setSessionProcessing(false)` before local notification emission, avoiding
  stuck composer or session state.
- Retry shares normal subscription, status reset, local-notification clearing,
  processing, session-processing, and streaming-reset behavior while preserving
  retry prompt selection, idempotency, no user-bubble append, and no composer or
  attachment consumption.
- Session reconstruction failure surfaces a local load/reconstruction error.
  Successful empty and loading states stay quiet.
- Post-accept server-event, provider, and streaming errors remain on existing
  server-event paths.

Accepted deferred scope:

- Fixed process/job/subagent/source-control/approval/memory/rules/hooks/skill
  and inbox panels remain absent.
- Old connection detail sheets, cockpit/status-pill restoration, process/job
  and subagent UI, notification expansion, provider/public/auth/settings/API
  drift, fake backend truth, and agent-execution restoration remain out of scope
  for this Phase 1 chat-affordance slice.

Verification recorded by the accepted re-audit:

- Focused `xcodebuild test` selected
  `TronMobileTests/MessagingCoordinatorTests`,
  `TronMobileTests/MessagingCoordinatorAuditRegressionTests`,
  `TronMobileTests/MessagingCoordinatorDraftTests`,
  `TronMobileTests/ConnectionCoordinatorTests`, and
  `TronMobileTests/SourceGuardTests`; 58 XCTest cases plus 53 source-guard tests
  passed.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- The re-audit worktree was clean.

## Completed Audit: iOS Phase 1 Slice 5 Settings / Onboarding / Diagnostics / Pairing Polish

Original audit thread: `019ef76e-e810-7640-a15b-475470e49ff2`

Original verdict: `changes required`, because the disconnected Settings card
labeled an active-server-prefilled repair flow as "Connect to a new server."

Fix thread: `019ef775-3214-7ff2-b864-082a73df35b7`

Fix commit: `49b76afa3805eeed7b4f5847779cfb2eb69a8edf`
(`Fix settings re-pair CTA semantics`) on
`codex/order-11-ios-settings-onboarding-polish-fix`

Independent re-audit thread: `019ef77a-bce7-7d23-815f-2a06a719b79c`

Re-audit verdict: `slice accepted`

Status: accepted with no findings after the fix.

Accepted result:

- The disconnected Settings card no longer labels an active-server-prefilled
  onboarding launch as "Connect to a new server."
- The active-server-prefilled repair path uses truthful re-pair wording and
  preserves intended same-server repair/token-reuse semantics.
- The real "Connect to a new server" path still launches onboarding with
  `prefill: nil`.
- Source guards pin the label-to-prefill intent.
- README and onboarding docs match the corrected behavior.

Accepted deferred scope:

- Backend facts, server settings, provider/auth APIs, fake backend truth,
  diagnostics execution changes, and future agent-execution surfaces remain out
  of scope for this Phase 1 settings/onboarding polish slice.
- Fixed product session lists, APNs/device broker,
  skills/rules/memory/worktree/process/job/goal/subagent/approval/web state,
  new server settings, DB tables, and auth/provider behavior remain absent.

Verification recorded by the accepted re-audit:

- `git show --stat --oneline 49b76afa3` reported 5 intended files changed.
- `git diff 78f44fe..49b76afa -- packages/ios-app README.md packages/agent/docs`
  was reviewed.
- Focused `xcodebuild` for `ServerSettingsPageTests` passed, 21 Swift Testing
  tests.
- Focused `xcodebuild` for `OnboardingFlowLayoutTests` with isolated
  DerivedData passed, 2 tests. An initial parallel attempt hit an Xcode database
  lock, then passed serially.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- `git status --short` was clean.

## Completed Audit: Accepted Follow-Up Cockpit Placement and Session-List Row Polish

Original audit thread: `019ef782-0b89-7873-b510-4d7e9c6f8d6f`

Original verdict: `changes required`, because the Order 12 branch was not based
on the accepted Order 11 closeout and dropped the accepted re-pair CTA
fix/guard/docs.

Fix thread: `019ef787-4f87-7b90-b3e3-db605f67fb2f`

Fix commit: `2b546ee9316ae758193b96b594a2002733e2afc9`
(`Fix settings re-pair CTA semantics on Order 12`) on
`codex/order-12-cockpit-placement-repair-cta-fix`

Independent re-audit thread: `019ef78e-d30c-7f82-96ab-206c34af2276`

Re-audit verdict: `slice accepted`

Status: accepted with no findings after the fix.

Accepted result:

- The active-server-prefilled unavailable-card action uses "Re-pair this
  server" and remains a repair/re-pair flow.
- The true "Connect to a new server" path remains `prefill: nil`.
- README and onboarding docs match the behavior; stale token-rotation wording is
  gone.
- Order 12 behavior remains intact: cockpit moved out of chat into Servers ->
  Diagnostics, passive banner removal, dashboard row glass/interactivity/title
  fallback/alignment polish, and source guards.

Accepted deferred scope:

- Backend facts, server settings, provider/auth APIs, fake backend truth,
  diagnostics execution changes, worker lifecycle changes, and future
  agent-execution surfaces remain out of scope.
- Notification inbox, APNs, device broker, Phase 2 capability, and passive chat
  runtime banner behavior remain absent.
- Broader `cargo test state_ownership_lifecycle::settings_auth` still has
  unrelated existing lifecycle-inventory failures outside this fix/slice.

Verification recorded by the accepted re-audit:

- `git diff 0176379..2b546ee -- README.md packages/ios-app packages/agent/docs`
  showed only the CTA/docs/test fix files changed.
- Focused Xcode tests passed, 79 tests total, including
  `ServerSettingsPageTests`, `OnboardingFlowLayoutTests`,
  `SessionDashboardPresentationTests`, `ChatAffordanceVisualRenderTests`,
  `AgentCockpitStateTests`, `AgentCockpitViewModelTests`, and
  `SourceGuardTests`.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- Targeted README/auth lifecycle invariant
  `sol_settings_auth_secrets_lifecycle_is_source_backed` passed.

## Completed Audit: iOS Phase 1 Slice 6 Notification / Inbox Concept Review

Original audit thread: `019ef798-f06a-7951-961f-590915eccb60`

Original verdict: `changes required`, because the current audit line/tracker
claimed the defer decision was complete while the current line lacked the
recorded Slice 6 defer/progress/invariant guard content.

Fix thread: `019ef7a1-4c08-7542-832b-98c86ba79d43`

Fix commit: `0ff5d2b28de52dda2beb64245c1d6524ed835969`
(`Fix notification inbox defer audit drift`) on
`codex/order-13-notification-inbox-concept-fix`

Independent re-audit thread: `019ef7a8-1ac7-76d1-9024-4127a0cfdf71`

Re-audit verdict: `slice accepted`

Status: accepted with no findings after the fix.

Accepted result:

- Notification / Inbox Concept Review is recorded as a defer/concept decision,
  not a runtime notification UI implementation.
- The current line no longer says Slice 6 is still next or pending as a future
  implementation slice.
- Rust IARM guards prove defer documentation and absence of old APNs,
  device-token, `NotificationClient`, `NotificationStore`, and inbox runtime
  planes.
- README and iOS architecture docs match the defer decision and do not overclaim
  APNs, push, badge/read semantics, durable inbox storage, notification
  resources, background delivery, or agent-execution inbox.
- Existing local chat error notification pills remain accepted Slice 4 behavior,
  not a restored inbox/APNs plane.

Accepted deferred scope:

- No runtime notification UI/code, backend facts, server settings,
  provider/auth APIs, fake backend truth, diagnostics execution changes, or
  future agent-execution surfaces were added.
- APNs, background push, device broker, notification resources, durable inbox
  storage, read state, app badge semantics, delivery chips, tool-family
  notifications, and agent-execution inbox remain deferred.
- Unrelated broad Swift SourceGuard budget drift remains outside this slice and
  was not papered over.

Validation recorded by the accepted re-audit:

- `git show --stat --oneline 0ff5d2b28de52dda2beb64245c1d6524ed835969`
  reported a docs/test-only fix with 5 files changed.
- Targeted diff review found no Swift/runtime source changes.
- Source scan found forbidden APNs, device-token, `NotificationClient`, and
  `NotificationStore` tokens only in absence guards; notification-named runtime
  files remain local chat error notification files.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed, 8 tests; existing Rust warning backlog observed.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- The review worktree remained clean.

## Completed Audit: Accepted Follow-Up Server-Backed Workspace Browser

Audit thread: `019ef7ae-6dd0-77f2-851b-78934da65718`

Verdict: `slice accepted`

Status: accepted with no blocking or important findings. The two audit findings
below are accepted non-blocking follow-up work, not blockers.

Accepted range:

- Tracker-listed audited range: `70780b798^..980867c35`
- Audited head: `980867c35`
- The audit inspected runtime and test behavior detached at `980867c35`.

Accepted result:

- Server-backed workspace browser is accepted as a workspace selector precursor
  only.
- It does not restore native file/patch review UI, import/worktree/git broad
  file-management panels, fake analytics/source-control surfaces, or Phase 2
  model-facing filesystem tools.
- Authenticated engine clients retain first-party filesystem-browser access by
  design. The slice did not add model-facing filesystem tools.

Accepted deferred scope:

- Native file/patch review UI, import/worktree/git panels, broad
  file-management or product panels, fake analytics, source-control surfaces,
  and Phase 2 model-facing filesystem tools remain deferred or absent.

Non-blocking follow-up findings:

- Symlinked directories are advertised as navigable but then rejected on
  navigation. The service marks symlink-to-directory entries as `isDirectory`,
  while `list_dir` validates the selected path with `symlink_metadata`.
  Audit refs:
  `packages/agent/src/domains/filesystem/service.rs:158`,
  `packages/agent/src/domains/filesystem/service.rs:229`.
- Workspace path display abbreviates any `/Users/<name>` path as `~`, not
  specifically the server-returned home path. This can mislabel
  `/Users/Public` or another account home if the browser navigates outside the
  paired user home. Audit refs:
  `packages/ios-app/Sources/Support/Foundation/Formatting/String+Extensions.swift:78`,
  `packages/ios-app/Sources/UI/Chat/Sheets/WorkspaceSelector.swift:155`.

Validation recorded by the accepted audit:

- `cargo test --manifest-path packages/agent/Cargo.toml filesystem --lib -- --nocapture`
  passed, 5 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
  passed, 8 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
  passed, 8 tests.
- Focused Xcode tests for `TronMobileTests/NewSessionFlowTests` and
  `TronMobileTests/FolderCreationTests` passed with existing Swift warning
  noise.
- XcodeGen drift checked in a temporary copy of `packages/ios-app`: no diff.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- The audit worktree remained clean.

## Completed Audit: Phase 2 Agent Execution Restoration Plan

Original audit thread: `019ef7b9-106d-70b3-b50b-984ba4718287`

Focused fix thread: `019ef7be-7e0d-70d0-9e03-4727e8a87557`

Independent re-audit thread: `019ef7c2-a23a-7cf3-80c9-21695a1f84f1`

Original audit verdict: `changes required`

Re-audit verdict: `slice accepted`

Status: accepted with no findings after the focused tracker/docs fix.

Accepted fix:

- Fix commit:
  `737411eefa30aa5a9b7ebd040583e62c995ba48f`
- The fix clarified that Phase 2 Agent Execution Restoration Plan artifacts are
  historical branch-only evidence at
  `codex/ios-affordance-restoration-map-current@7db72c1ee`, not files present
  on this tracker branch.
- The fix preserved the consolidation requirement: before any all-slices
  integrated acceptance claim, a final consolidation branch and explicit
  consolidation audit must verify branch-scoped artifacts have either been
  ported into that branch or truthfully superseded by current-line records.

Accepted result:

- Phase 2 Agent Execution Restoration Plan is accepted as a planning slice.
- The accepted historical evidence reports score 100/100, all 24 BPRC buckets
  mapped, an ordered roadmap, memory architecture, validation protocol, and
  handoff packet.
- Acceptance does not claim runtime/product implementation and does not claim
  the historical branch-only plan files exist on this tracker branch.

Accepted deferred scope:

- Planning does not implement runtime behavior.
- Future slices still need user decisions and per-slice validation.
- Integrated all-slices acceptance remains blocked until the final
  consolidation branch/audit requirement is completed.

Validation recorded by the accepted re-audit:

- The independent re-audit returned `verdict: slice accepted`.
- The independent re-audit reported no findings.

## Completed Audit: Phase 2 Slice 1: Catalog Discovery Evidence

Original audit thread: `019ef7c8-3427-7420-9c5c-f43b4fdd5b4f`

Focused fix thread: `019ef7cc-23f2-7391-830c-7e5e97305aed`

Independent re-audit thread: `019ef7ce-cb06-7242-9361-06e28bf01aa9`

Original audit verdict: `changes required`, because Order 16 branch-scoped
artifacts were described as current-line artifacts.

Re-audit verdict: `slice accepted`

Status: accepted with no findings after the focused tracker/docs fix.

Accepted fix:

- Fix commit:
  `e9fb48c3b9469d4b8122ab76c299eba3832df8c0`
- The fix clarified that Phase 2 Slice 1 catalog discovery implementation and
  evidence are historical branch-scoped artifacts at
  `codex/phase-2-catalog-discovery-evidence-current@f95d3b02e`, not files
  present on this tracker branch.
- The fix preserved the consolidation requirement: before any all-slices
  integrated acceptance claim, a final consolidation branch and explicit
  consolidation audit must verify branch-scoped artifacts have either been
  ported into that branch or truthfully superseded by current-line records.
- The fix changed docs/tracker wording only and did not alter runtime or product
  behavior.

Accepted result:

- Phase 2 Slice 1 Catalog Discovery Evidence is accepted as branch-scoped
  historical evidence.
- Historical range: baseline `7db72c1ee`, commits `a9c3d3507`,
  `ca471fcde`, and `680d9429f`, final `f95d3b02e` on
  `codex/phase-2-catalog-discovery-evidence-current`.
- The accepted historical evidence covers catalog search/inspect/conformance
  through `execute`, resource-backed reports, Runtime Cockpit Discovery,
  protected omission, and recorded Rust/iOS/static validations.
- Acceptance does not claim the canonical Phase 2 Slice 1 artifacts or
  `packages/agent/src/domains/catalog_discovery/` are present on this tracker
  branch.

Accepted deferred scope:

- No target routing, intent execution, public `/engine` expansion, generated
  `ui_surface` publication, fixed legacy panels, schema repair, or old module
  copies are accepted as part of this slice.
- Integrated all-slices acceptance remains blocked until the final
  consolidation branch/audit requirement is completed.

Validation recorded by the accepted re-audit:

- `git show --stat --oneline e9fb48c3b9469d4b8122ab76c299eba3832df8c0`
  reported one docs file changed.
- `git diff ca74c9f...e9fb48c3 -- packages/agent/docs/restoration-retrospective-audit-status.md`
  showed wording correction only.
- Current `HEAD` tracked-file checks confirmed the canonical Order 16 files are
  absent from this tracker branch.
- Historical ref `codex/phase-2-catalog-discovery-evidence-current` resolved to
  `f95d3b02e`, and historical docs plus `catalog_discovery` implementation
  files exist there.
- `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture`
  passed, 11 tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.

## Completed Audit: Phase 2 Slice 2: Approval Safety / Freshness + Schema Hardening

Independent audit thread: `019ef7d6-60f7-79f0-a39f-2ab59fb44ae6`

Verdict: `slice accepted`

Status: accepted with no findings.

Accepted result:

- Phase 2 Slice 2 Approval Safety / Freshness + Schema Hardening is accepted
  as branch-scoped historical evidence.
- Historical range: baseline `f95d3b02efbffe15798d4164ae494e743a6332a5`,
  final pre-hardening `5ea963008166e0d0a784b137d04f3b000c9de0cd`, and
  hardening final `301f61bc3af24e69decbe0281d829b9a9f7ada8e` on
  `codex/phase-2-approval-safety-freshness-current` and
  `codex/phase-2-approval-schema-hardening-current`.
- The accepted historical evidence covers durable approval request/decision
  resources, lifecycle stream, idempotent decision replay through engine
  idempotency, stale version conflict, deterministic `check_approval_at`,
  fail-closed denial/expiry/pending/missing/malformed/stale/scope mismatch,
  schema alignment guard, replay/evidence explanations, and
  approval-is-not-authority metadata.
- Acceptance does not claim the canonical Phase 2 Slice 2 artifacts or approval
  implementation files are present on this tracker branch.

Accepted deferred scope:

- Native iOS approval UI, risk taxonomy, default expiry policy, interruption
  behavior, per-package risky-action triggers, and unrelated capability behavior
  remain deferred.
- Integrated all-slices acceptance remains blocked until the final
  consolidation branch/audit requirement is completed.

Validation recorded by the accepted audit:

- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::approval -- --nocapture`
  passed, 6 tests.
- SACB passed, 17 tests.
- TMB passed, 12 tests.
- TPC passed, 15 tests.
- PCC passed, 16 tests.
- DRC passed, 17 tests.
- CSD passed, 12 tests.
- HRA passed, 35 tests.
- DESI passed, 9 tests.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check && git ls-files -ci --exclude-standard` passed with empty
  output.
- `scripts/tron ci fmt check clippy test` passed on a temporary detached
  `301f61bc3` worktree.
- The original audit checkout remained clean and detached at `fce107fa`.

## Completed Audit: Phase 2 Slice 3: Memory Foundation + Scope Hardening

Original audit thread: `019ef7e2-1558-7b70-9281-ebe61e56eedb`

Original audit verdict: `changes required`, because shallow `bodyRef`
validation only rejected top-level inline body keys and allowed nested inline
body content to be persisted despite privacy/bodyRef custody claims.

Focused fix thread: `019ef7e7-3d95-7fe1-b29c-1aa69b5ea359`

Focused fix commit:
`be1300934fb36ec9bac650eedfee933c9daf0d9d` (`Reject nested inline memory
body refs`) on `codex/order-18-memory-bodyref-recursive-validation`

Independent re-audit thread: `019ef7ee-0b9b-7213-a51c-d66a89e8b483`

Re-audit verdict: `slice accepted`

Status: accepted with no findings after the focused fix.

Accepted result:

- Phase 2 Slice 3 Memory Foundation + Scope Hardening is accepted as
  branch-scoped historical evidence.
- Historical range: baseline `301f61bc3`, original implementation commits
  `29024b677`, `20dde9894`, and `4c35b2119` at
  `codex/phase-2-memory-foundation-current@4c35b2119`, plus accepted fix commit
  `be1300934fb36ec9bac650eedfee933c9daf0d9d` at
  `codex/order-18-memory-bodyref-recursive-validation@be1300934fb36ec9bac650eedfee933c9daf0d9d`.
- The accepted historical evidence covers memory policy/status, resource
  definitions, redacted records, prompt traces, migration envelopes, scope
  hardening, no hidden body-context inclusion, and branch-scoped full Rust
  CI/guards.
- The accepted fix recursively rejects inline body-like keys (`content`, `text`,
  `body`, `raw`) anywhere inside `bodyRef` objects/arrays before retain, edit,
  or import persistence.
- Regression coverage includes nested retain and migration import cases. The
  edit path is accepted because it shares the same validator before update
  persistence.
- Acceptance does not claim the canonical Phase 2 Slice 3 artifacts, memory
  implementation files, or focused fix files are present on this tracker branch.
- The original audit also noted that Order 18 source-branch history is not an
  ancestor of tracker `HEAD`; this remains branch-scoped historical evidence
  until the final consolidation branch/audit ports or truthfully supersedes it.

Accepted deferred scope:

- Semantic/vector retrieval, embeddings, ranking, summarization, episodic
  retrieval, procedural rules/hooks/skills, automatic retention, native iOS
  memory UI, and unrelated features remain deferred.
- Integrated all-slices acceptance remains blocked until the final
  consolidation branch/audit requirement is completed.

Validation recorded by the accepted re-audit:

- `git show --stat --oneline be1300934fb36ec9bac650eedfee933c9daf0d9d`
  reported 4 files changed, with 128 insertions and 8 deletions.
- `cargo test -p tron memory::tests` passed, 13 tests.
- `cargo test -p tron nested_inline_body_refs_are_rejected_on_retain` passed.
- `cargo test -p tron migration_import_rejects_nested_inline_body_ref_content`
  passed.
- `cargo fmt --all -- --check` passed.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check 4c35b211...be130093` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.
- The re-audit worktree was clean.

## Completed Audit: Phase 2 Slice 4: Filesystem Agent Tools + Truncated Snapshot Hardening

Original audit thread: `019ef7f6-d7f2-7f23-8ba8-4a52d8849209`

Original audit verdict: `changes required`, because legacy `file_read` and
`file_write` remained model-reachable through `capability::execute`, bypassing
the hardened `filesystem_*` operations. The audit also identified
branch-scoped evidence/current-line integration distinctions, provider
prompt/evidence wording that overclaimed truncated-snapshot mutating
guardrails, and a non-blocking provider-prompt absolute-path mismatch.

Focused fix thread: `019ef7fd-633f-7822-9c4b-9a691d485619`

Focused fix commit:
`6c53f3ee9761efce0539363e2c54dd1b80b4f735`
(`codex/order-19-filesystem-tools-fix`)

First independent re-audit thread: `019ef807-d1bc-77e2-b83f-388637da4e15`

First re-audit verdict: `changes required`, because stale active docs still
presented `file_read` and `file_write` as current provider-visible operations.

Follow-up docs fix thread: `019ef80c-3ac5-7870-8603-976b3f51acf0`

Follow-up docs fix commit:
`b373a367887d5fb114ed66fdc1023401bcd0aaa5`
(`codex/order-19-filesystem-tools-docs-followup`)

Accepted independent re-audit thread: `019ef810-db9e-7081-a64f-265c781ea15c`

Accepted re-audit verdict: `slice accepted`

Status: accepted with no blocking or important findings after the focused fix
and follow-up docs fix.

Closeout checkout assumption:

- This docs-only closeout started from detached `HEAD` at
  `fef27cb991dc9944de6132ffb51f927581493951`, decorated as
  `codex/order-18-memory-closeout`, and created the focused tracker closeout
  branch `codex/order-19-filesystem-closeout` from that point.

Accepted result:

- Phase 2 Slice 4 Filesystem Agent Tools + Truncated Snapshot Hardening is
  accepted as branch-scoped historical evidence.
- Historical range: baseline `4c35b2119`, original implementation commits
  `27e5847c9` and `2650dd0b9` at
  `codex/phase-2-filesystem-agent-tools-current@2650dd0b9`, plus accepted fix
  commits `6c53f3ee9761efce0539363e2c54dd1b80b4f735` at
  `codex/order-19-filesystem-tools-fix@6c53f3ee9761efce0539363e2c54dd1b80b4f735`
  and `b373a367887d5fb114ed66fdc1023401bcd0aaa5` at
  `codex/order-19-filesystem-tools-docs-followup@b373a367887d5fb114ed66fdc1023401bcd0aaa5`.
- Legacy `file_read` and `file_write` are no longer model-visible or
  dispatched through `capability::execute` on the accepted fix branch.
- Active docs no longer present those legacy names as current provider-visible
  operations; remaining legacy mentions are historical or provenance-only.
- Current provider-visible filesystem operations on the accepted branch are the
  hardened `filesystem_*` surface with relative path authority, canonical root
  checks, symlink escape denial, preview/commit idempotency, hash guards,
  patch/materialized evidence, bounded output, binary omission, and truncated
  snapshot refusal.
- Provider and evidence wording was corrected to avoid overclaiming
  converter-only proof for mutating guardrails and to preserve branch-scoped
  truth.
- Acceptance does not claim the canonical Phase 2 Slice 4 artifacts,
  filesystem implementation files, or focused fix files are present on this
  tracker branch unless a future consolidation branch ports or truthfully
  supersedes them.
- The original audit noted that source/fix evidence is branch-scoped and must
  not be treated as current-line integrated without explicit proof. That
  distinction remains preserved in this tracker.

Accepted deferred scope:

- Jobs, git, web, subagents, semantic/vector/procedural/scheduling work,
  native file/patch UI, public DTO expansion, unrelated DB/settings/auth/provider
  expansion, and production deploy behavior remain deferred for this slice.
- Integrated all-slices acceptance remains blocked until the final
  consolidation branch/audit requirement is completed.

Validation recorded by the accepted re-audit:

- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::filesystem -- --nocapture`
  passed, 17 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture`
  passed, 17 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`
  passed, 26 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`
  passed, 3 tests.
- `git diff --check` passed.

## Completed Audit: Phase 2 Slice 5A: Durable Jobs and Process Lifecycle + Race Hardening

Original audit thread: `019ef819-970d-7672-b088-e8097005b23b`

Original audit verdict: `changes required`, because stale durable
`job_process` resources could remain observable as `running` after restart or
crash. Live ownership was only in memory, and status/list/cleanup did not
reconcile stale running state unless a later cancel was called. The audit also
identified false SACB/CSD validation claims because
`packages/agent/src/domains/jobs/race_tests.rs` was missing from the SACB/CSD
inventories and guards.

Focused fix thread: `019ef820-a8b2-7873-b5c5-c4e827b80121`

Focused fix commit:
`8702a7e8cb6346d29ac5247ee87344f34b766143`
(`codex/order-20-jobs-process-lifecycle-fix`)

First independent re-audit thread: `019ef831-0a55-7b10-9a0d-ea836b919452`

First re-audit verdict: `changes required`, because reconciliation still had
a pagination hole when more than 500 newer non-reconcilable running rows could
hide the targeted stale resource needed by status/log/cancel.

Follow-up focused fix thread: `019ef835-909c-7ed1-93a4-f795345b1afc`

Follow-up fix commit:
`d57aaf83e94693e2eaefde16108202ea4e254e5e`
(`codex/order-20-jobs-process-lifecycle-reconcile-targeted`)

Accepted independent re-audit thread: `019ef83d-dc76-7031-ae09-8774db2443f4`

Accepted re-audit verdict: `slice accepted`

Status: accepted with no findings after both focused fix commits.

Closeout checkout assumption:

- This docs-only closeout started from detached `HEAD` at
  `6505d30ca56abc0d5f9f3700242f862fe078e571`, decorated as
  `codex/order-19-filesystem-closeout`, and created the focused tracker
  closeout branch `codex/order-20-jobs-closeout` from that point.

Accepted result:

- Phase 2 Slice 5A Durable Jobs and Process Lifecycle + Race Hardening is
  accepted as branch-scoped historical evidence.
- Historical range: baseline `1d35ac848` on `2650dd0b9`, original
  implementation commits `404290d06`, `4fb134c64`, and `0d76be40d` at
  `codex/phase-2-jobs-process-lifecycle-current@0d76be40d`, plus accepted fix
  commits `8702a7e8cb6346d29ac5247ee87344f34b766143` at
  `codex/order-20-jobs-process-lifecycle-fix@8702a7e8cb6346d29ac5247ee87344f34b766143`
  and `d57aaf83e94693e2eaefde16108202ea4e254e5e` at
  `codex/order-20-jobs-process-lifecycle-reconcile-targeted@d57aaf83e94693e2eaefde16108202ea4e254e5e`.
- Stale durable `job_process` resources after restart or crash are reconciled
  into truthful terminal state with inspectable evidence instead of remaining
  observable as stale `running`.
- The follow-up fix closes the greater-than-500 newer non-reconcilable
  running-row pagination hole using an internal scan and targeted status,
  log, and cancel reconciliation after scope validation, without changing
  public list limits.
- Request-triggered reconciliation is invocation-scoped, while startup
  reconciliation may scan all scopes.
- Runtime-owned and post-startup jobs are not falsely marked stale.
- SACB/CSD inventory coverage for
  `packages/agent/src/domains/jobs/race_tests.rs` is now present and guarded.
- Acceptance does not claim the canonical Phase 2 Slice 5A artifacts, jobs
  implementation files, or focused fix files are present on this tracker
  branch unless a future consolidation branch ports or truthfully supersedes
  them.
- The original and follow-up audits treated source/fix evidence as
  branch-scoped; that distinction remains preserved in this tracker.

Accepted deferred scope:

- PTY/interactive terminals, interpreter runtimes, git/source control,
  web/network research, subagents, scheduling, notifications, native iOS
  process panels, public DTO expansion, production deploy behavior, unrelated
  settings/auth/provider changes, and broader final all-slices integration
  remain deferred.
- Integrated all-slices acceptance remains blocked until the final
  consolidation branch/audit requirement is completed.

Validation recorded by the accepted re-audit:

- `cargo test --manifest-path packages/agent/Cargo.toml domains::jobs -- --nocapture`
  passed, 13 jobs tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture`
  passed, 17 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture`
  passed, 12 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
  passed, 9 tests.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  passed.
- `scripts/personal-info-guard.sh` passed.
- `git diff --check` passed.
- `git ls-files -ci --exclude-standard` passed with empty output.

## Next Audit

The next action is audit of **Order 21: Phase 2 Slice 6: Git, Worktrees, And
Source Control**.

The tracker queue is not ambiguous: Order 20 is now closed, and the Phase 2
roadmap names Slice 6 after the completed Slice 5A jobs/process lifecycle
foundation:

> `### Slice 6: Git, Worktrees, And Source Control`

Order 21 should start from the accepted Phase 2 source/fix lineage only after
orchestration confirms the intended source branch/ref for Slice 6. The roadmap
describes Slice 6 as restoring source-control workflows over durable worktree
resources, including branch status, diffs, staging, commits, conflicts, merges,
rebases, pushes, and PR handoff with evidence. It depends on filesystem, jobs,
resources, authority, replay, trace, and approval decisions. Likely areas are
future `domains/git`, future `domains/worktree`, resources, events, and iOS
SourceChanges only after a stable server contract.

Before any all-slices integrated acceptance claim, create a final consolidation
branch and run an explicit consolidation audit that verifies accepted
branch-scoped artifacts have either been ported into that branch or superseded
by truthful current-line records.

## Per-Slice Audit Start State

Per-slice audit may start from this queue. The first audit thread should remain
review-only until it records findings, separates real blockers from preserved
deferred scope, and identifies any focused fix that requires user acceptance.
