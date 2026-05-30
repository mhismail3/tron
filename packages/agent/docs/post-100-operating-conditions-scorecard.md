# Post-100 Operating Conditions And UI/UX Regression Scorecard

Status: active operating scorecard

Created: 2026-05-30

Initial score: **0/100**

Current score: **3/100** (raw **5/165**; UXR-1 iPhone checkpoint recorded but unscored until remaining action coverage is closed)

Completed prerequisite scorecards:
- `collapsed-engine-hardening-scorecard.md`: **100/100**
- `codebase-cleanup-scorecard.md`: **100/100**

No scored collapsed-engine hardening scenario remains open after RWO-N17; this
scorecard owns post-100 regression, breadth, and UI/UX evidence from here.

This scorecard measures real operating confidence after the collapsed engine and
cleanup campaigns reached 100/100. It covers production install behavior, live
server and database truth, provider breadth, long-running churn, and UI/UX
projection correctness in the iOS simulator and Mac wrapper.

Raw scenario weights sum to 165. The displayed score is normalized to 100 and
only reaches **100/100** when every ROC and UXR row is passed or explicitly
closed with tested, documented non-applicability.

## Operating Loop

Every scenario follows the same loop:

1. Read this scorecard and pick the next incomplete scenario.
2. Run the exact app/server path under real conditions.
3. Inspect DB truth: logs, events, invocations, resources, approvals, queues,
   streams, sessions, worktrees, and notification rows as relevant.
4. Inspect visible UI with simulator screenshots and Computer Use whenever a
   button, icon, sheet, menu, or visible state matters.
5. Classify the result as `passed`, `passed_after_fix`, `blocked`, or
   `failed_unfixed`.
6. If failed, stop breadth testing, isolate the owner, add the smallest focused
   test, fix the root cause, remove nearby dead/fallback/legacy/compatibility
   code, rerun the exact scenario, update this scorecard and ledger, and commit
   the checkpoint.

UI failures use one owner: `ios_rendering`, `ios_state_projection`,
`ios_action_wiring`, `server_contract`, `stream_or_reconstruction`,
`mac_wrapper_ui`, or `test_harness`.

## Evidence Contract

Each UI/UX row must record the simulator UDID, app bundle id, server PID,
session ids, screenshot paths, Computer Use confirmation, exact UI action
sequence, DB invocation/event/resource/approval/queue/log summary after the
scenario start, focused tests added or rerun, owner classification for every
failure, score delta, and residual risk.

Minimum checkpoint commands:

```bash
git status --short
cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture
git diff --check
```

iOS checkpoints also run:

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:<targeted-test>
```

App-path evidence starts from:

```bash
scripts/tron dev -bd --json --wait 30
curl -fsS http://localhost:9847/health
xcrun simctl launch <udid> com.tron.mobile.beta
xcrun simctl openurl <udid> "tron://session/<session_id>"
xcrun simctl io <udid> screenshot /tmp/<scenario>.png
```

## ROC Scenario Ledger

| ID | Scenario | Raw Points | Status | Evidence | Open Loops |
|---|---|---:|---|---|---|
| ROC-0 | Scorecard formalization and baseline | 5 | passed_after_fix | 2026-05-30 baseline: new scorecard, README/iOS/Mac doc links, and static gate added. First `scripts/tron ci fmt check clippy test` stopped at formatting in the new invariant; `cargo fmt --manifest-path packages/agent/Cargo.toml --all` fixed it, then full CI passed. Focused iOS smoke passed on iPhone 17 Pro simulator with `ContentViewCoordinatorTests` and `PendingSessionDeepLinkTests` (7 tests). Dev server `scripts/tron dev -bd --json --wait 30` passed with PID 22061 and `/health` returned ok. Simulator UDID `267F6468-09AE-471D-9157-29144173EB82`, bundle `com.tron.mobile.beta`, Computer Use confirmed the visible Sessions list, screenshot `/tmp/roc0-baseline-simulator.png`. DB classification since `2026-05-30T18:06:09Z`: 0 error/fatal logs, 0 failed invocations; warning-only rows were simulator WebSocket attempts to an older paired host. | None for ROC-0; continue with UXR-1 and UXR-2. |
| ROC-1 | Production install, service, and update path | 10 | pending | Must exercise `/Applications/Tron.app`, SMAppService, stale helper diagnostics, update finalization, stop/restart/resume, local Release replacement, and uninstall preservation behavior. | No optimistic success before `/health`; stale helpers require update/reinstall. |
| ROC-2 | Current hosted model regression matrix | 8 | pending | Must run core scenarios on `claude-sonnet-4-6`, `gpt-5.5`, and the current Gemini profile model. | Prove every path uses `capability::execute` and DB child-call truth. |
| ROC-3 | Local model breadth | 6 | pending | Keep `gemma4:e4b` as local substrate smoke; add a larger Ollama lane when available. | Separate small-model comprehension failures from engine failures. |
| ROC-4 | Worker, queue, stream, trigger chaos | 9 | pending | Repeat RWO-N15, RWO-N16, RWO-N16B, and RWO-N17 under real dev server and simulator conditions. | No stale leases, duplicate completions, unclosed subscriptions, hidden failures, or non-terminal queues. |
| ROC-5 | Resource truth and mutation failure paths | 7 | pending | CAS mismatch, stale version, missing payload, hash mismatch, discarded resource access, stale generated UI submit, and process output collision. | Required failures happen before mutation; refs and versions match DB truth. |
| ROC-6 | Platform surfaces | 7 | pending | Notifications/APNs, updater, transcription, voice notes, feedback diagnostics, and settings parity. | Failures visible and bounded; no side-channel truth. |
| ROC-7 | Long-running session and compaction regression | 8 | pending | Long sessions, repeated tool calls, restart mid-turn, compaction threshold crossing, background/foreground, and session reopen. | Reconstructed chat equals persisted event truth; no unexpected `compact.*` events. |
| ROC-8 | Large test and static-gate maintainability | 5 | pending | Keep large-file budgets current and split only when it reduces concepts. | Static tests assert owner-level invariants, not brittle old paths. |
| ROC-9 | Full real-world sweep | 5 | pending | Broad Rust CI, focused iOS tests, simulator smoke, DB classification, and large-file audit. | Final sweep remains open until all fixes land. |
| ROC-10 | Closeout | 5 | pending | Close or explicitly defer every row with evidence. | Move future work to a new scorecard, not vague residual risk. |

## UI Inventory

| Surface | Owner | Current Test Coverage | Live/Simulator Coverage | DB Evidence Requirement |
|---|---|---|---|---|
| iOS dashboard/sidebar/session cards | ios_state_projection | Existing view-model and coordinator tests; UXR-1 to map exact coverage. | Simulator iPhone and iPad screenshots. | Session/worktree rows, branch status, processing state, archive/delete actions. |
| Chat input and message bubbles | stream_or_reconstruction | Chat view-model, event transformer, deep-link tests. | Typed and harness-submitted prompts in simulator. | `message.user`, assistant terminal event, queue and stream rows. |
| Capability cards and approval sheets | ios_action_wiring | Capability/approval model tests. | Visible pending/completed/error cards and approval resolution. | Invocation rows, approval status, grant/resource refs. |
| Generated UI | server_contract | Engine generated-UI tests and Swift renderer tests. | Surface render, refresh, submit, and stale action rejection. | `ui_surface` resource/version/action ids and target invocation rows. |
| Notification bell/list/detail | ios_action_wiring | Notification store tests to add in UXR-2. | Bell count, detail mark-read, read-all, offline failure. | Notification read state plus `notifications::*` invocations. |
| New Session and onboarding | ios_state_projection | Coordinator and pairing tests. | Sheet flow, QR/manual pairing, unauthorized/unreachable paths. | Server pairing and session creation rows. |
| Settings, model/provider settings | server_contract | Settings parity tests. | Loading/unreachable/add/edit/clear/model controls. | `settings::*`, provider credential status, profile settings truth. |
| Source-control sheets | ios_action_wiring | Worktree/git workflow tests. | Commit, merge, push, pull, rebase, conflict, branch picker. | Worktree status, git invocation rows, classified errors. |
| Voice notes and attachments | ios_action_wiring | Audio/transcription service tests. | Unavailable/record/cancel/submit and attachment add/remove. | Voice/transcription invocation rows and materialized resources. |
| Prompt library, subagent, process/log/detail sheets | ios_state_projection | Existing model/detail tests to map in UXR-0. | Sheet open/close/action paths. | Capability invocation, resource, log, and subagent state rows. |
| Mac wizard/menu/logs/install/update/uninstall | mac_wrapper_ui | Mac planner/menu tests. | Local wrapper UI plus launchd/SMAppService/health evidence. | `/health`, launchd print, SMAppService state, updater/log rows. |

## UXR Scenario Ledger

| ID | Scenario | Raw Points | Status | Evidence | Open Loops |
|---|---|---:|---|---|---|
| UXR-0 | UI inventory and test harness | 5 | pending | Inventory table exists above; exact existing test mapping still needs row-by-row confirmation. | Map each surface to tests before adding new tests. |
| UXR-1 | Dashboard session cards and metadata icons | 10 | pending | 2026-05-30 iPhone checkpoint passed after fixes for owner `ios_state_projection` / `ios_rendering`: `SessionTitleIcons` now shows dirty dots for on-base and non-isolated dirty worktrees, exposes matching accessibility descriptors, and keeps the icon cluster fixed-size. Sidebar preloads worktree status after the active server is connected instead of relying on per-row tasks, so relaunch shows all visible branch/fork/dirty indicators. Session cache schema v13 persists `is_processing`, and legacy provider-schema rebuilds now run before current-column migrations so processing state is not dropped. Simulator: iPhone 17 Pro UDID `267F6468-09AE-471D-9157-29144173EB82`, bundle `com.tron.mobile.beta`; screenshot `/tmp/uxr1-session-cards-iphone-20260530112912.png` covers plain, forked, dirty, isolated, fork+dirty, long-title/path, and narrow phone rows; `/tmp/uxr1-processing-active-iphone-20260530114402.png` covers live processing row `sess_019e7a33-49aa-71f2-9aca-b169634b18e2` while server `session::list` reported `isRunning=true`; Computer Use accessibility tree showed dirty/isolated rows with `branch 019e7a19, dirty worktree`. Tap-open path was verified by opening `UXR-1 clean plain card 20260530112912` and returning to the session list. Focused tests passed: `DatabaseSchemaTests` + `EventDatabaseTests/testSessionPersistenceRoundTripsProcessingFlag` (6 tests), `SessionTitleIconsTests` + `WorktreeStatusCacheTests` (40 tests). | iPad/sidebar live layout intentionally deferred by user on 2026-05-30 for a later plan/session. Archive/delete final UI mutation for disposable row `UXR-1 archive disposable card 20260530112912` remains pending action-time confirmation for Computer Use; the row exposes the `Archive` secondary action. |
| UXR-2 | Notification inbox actions | 10 | pending | Bell count, refresh, mark-read, auto-mark, read-all, session-scoped read-all, offline failure, deep link, `notifications::mark_read`, and `notifications::mark_all_read`. | Add focused `NotificationStore.markRead` and `markAllRead` tests with mock transport. |
| UXR-3 | Chat/engine visual parity | 12 | pending | Harness prompt, native prompt, terminal assistant, approvals, capability cards, cold/live deep link, reconnect, relaunch. | Simulator screenshot plus DB classification for same session id and order. |
| UXR-4 | Input bar, attachments, voice notes, prompt submission | 8 | pending | Text/send, queued while processing, stop/cancel, attachment add/remove, voice states, skills mention popup. | Disabled states visibly disabled and untappable; errors surfaced. |
| UXR-5 | Capability cards, approval sheets, generated UI | 9 | pending | Detail cards for process/filesystem/resource/web/model/settings, approval deny/approve/double tap, generated UI action flow. | Server-owned invocation/action coordinates only. |
| UXR-6 | Source control and worktree UX | 8 | pending | Summary card, commit/merge/push/pull/rebase/conflict, protected branch gating, branch picker, worktree refresh. | Buttons enabled only when server/worktree state permits. |
| UXR-7 | Settings, providers, server pairing UX | 8 | pending | Server settings load/unreachable/loading, API key add/edit/clear, OAuth, model picker, protected branches, appearance, notifications, diagnostics, pairing. | One server field and one iOS control per setting. |
| UXR-8 | Navigation, deep links, session tree, history | 7 | pending | Dashboard/sidebar selection, session/notification deep link, back/sidebar toggle, history/fork, scroll target, load more. | Route and visible session id match DB truth; nonzero `simctl openurl` fails. |
| UXR-9 | Mac wrapper UX | 8 | pending | Wizard, menu status, start/pause/resume/restart/stop-dev, logs, feedback, update, uninstall, Debug companion, isolated install. | Wrapper remains observer/manager; Debug companion cannot mutate production. |
| UXR-10 | Visual QA and accessibility sweep | 5 | pending | iPhone/iPad screenshots, dynamic text, long titles, icon-only labels, placeholder/dead button audit. | No overlap, clipping, invisible icons, unreadable contrast, or unhooked affordances. |

## Baseline Evidence

ROC-0 baseline was recorded on 2026-05-30:

- `scripts/tron ci fmt check clippy test`: passed after formatter correction to
  `packages/agent/tests/threat_model_invariants.rs`.
- `xcodegen generate`: passed in `packages/ios-app`.
- Focused iOS simulator smoke: `xcodebuild test -scheme Tron -destination
  'platform=iOS Simulator,name=iPhone 17 Pro'
  -only-testing:TronMobileTests/ContentViewCoordinatorTests
  -only-testing:TronMobileTests/PendingSessionDeepLinkTests` passed 7 tests.
- `scripts/tron dev -bd --json --wait 30`: passed, PID 22061, database
  `/Users/moose/.tron/internal/database/tron.sqlite`.
- `curl -fsS http://localhost:9847/health`: `status=ok`, `active_sessions=0`.
- Simulator evidence: UDID `267F6468-09AE-471D-9157-29144173EB82`, bundle
  `com.tron.mobile.beta`, screenshot `/tmp/roc0-baseline-simulator.png`;
  Computer Use confirmed the visible Sessions list and notification/settings
  affordances.
- DB classification since `2026-05-30T18:06:09Z`: 0 error/fatal log rows and
  0 failed invocations. Warning-only rows were simulator WebSocket attempts to
  an older paired host and were not classified as dev-server startup failures.

## Assumptions

- UXR-1 and UXR-2 are the first UI implementation lanes because they match the
  currently observed regressions.
- UI/UX correctness means visible app state matches engine/server truth; Swift
  does not own separate policy or product-state side channels.
- Simulator evidence is sufficient for iOS foreground UI. APNs delivery still
  requires physical-device testing and should be marked blocked if no device is
  available.
- Mac UI scenarios may require local manual-safe app launching, but they still
  need `/health`, launchd, and SMAppService evidence before passing.
