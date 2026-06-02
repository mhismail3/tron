# Post-100 iPad UI Regression Scorecard

Status: active under `post-scorecard-gap-hardening-scorecard.md`

Created: 2026-05-31

Initial score: **0/100**

Current score: **21/100**

This scorecard owns iPad-specific follow-up coverage that was explicitly moved
out of `post-100-operating-conditions-scorecard.md` when that plan closed with
iPhone-only simulator scope. It is now active inside
`post-scorecard-gap-hardening-scorecard.md` and must close with real iPad
Simulator evidence plus the same server/DB truth discipline used by the closed
post-100 scorecard.

## Scope

- Target only iPad layouts, split-view/sidebar behavior, detents, popovers,
  pointer/keyboard affordances, and wider-viewport visual/accessibility issues.
- Do not reopen iPhone-pass criteria unless an iPad bug proves a shared
  rendering/state-projection defect.
- Use Computer Use against the iPad Simulator for visible workflows.
- Record server DB truth for every action-bearing scenario: invocations, logs,
  sessions, worktrees, notifications, approvals, resources, queues, and leases.
- Preserve the same destructive-action confirmation policy: archive, delete,
  reset, unsubscribe, submit, and external-send clicks need action-time user
  confirmation.

## Scenario Ledger

| ID | Scenario | Raw Points | Status | Required Evidence |
|---|---|---:|---|---|
| IPD-0 | Harness and baseline | 5 | passed | iPad Simulator UDID/app bundle/server PID, `/health`, DB no-error classification, screenshot path, and focused iPad `xcodebuild` smoke. |
| IPD-1 | Dashboard/sidebar session cards | 12 | running | Plain, forked, dirty, isolated, fork+dirty, processing, long-title/path, empty state, tap-open, archive context action, icon contrast, and sidebar preload after relaunch. |
| IPD-2 | Chat and engine parity | 12 | running | Prompt send, streaming response, capability cards, approval pending/resolved sheets, reconnect/relaunch/deep-link parity, and DB event ordering. |
| IPD-3 | Input, attachments, voice notes | 8 | running | Text send, queued prompt, stop, attachment add/remove, skills popup, voice-note available/unavailable/record/cancel/submit states on iPad. |
| IPD-4 | Notifications | 8 | passed_after_fix | Bell count, list/detail, mark read, mark all read, session-scoped read, offline failure, badge clearing, and notification deep link in split view. |
| IPD-5 | Capability, approval, generated UI | 10 | running | Detail sheets/popovers, approve/deny/double-tap, read-only terminal approvals, generated UI render/refresh/submit/stale action rejection. |
| IPD-6 | Source control and worktree | 10 | running | Agent Control source-control card, dirty/diff rendering, commit/push/rebase/merge/pull/conflict resolver, disabled destructive actions, and DB policy truth. |
| IPD-7 | Settings, providers, pairing | 8 | passed_after_fix | Settings grid/sidebar behavior, server unavailable/retry, pairing/onboarding from Settings, providers/OAuth status, model picker, protected branches, and profile/auth truth. |
| IPD-8 | Navigation, deep links, session tree | 8 | running | Sidebar selection, back behavior, session/capability/event/notification deep links, load-earlier pagination, history/fork sheet, cold-start routing. |
| IPD-9 | Visual QA and accessibility | 12 | running | Light/dark mode, large accessibility sizes, keyboard/pointer focus, no clipped controls, no overlapped text, and stable fixed-format UI dimensions. |
| IPD-10 | Closeout | 7 | pending | Score reaches 100/100 or every residual item is moved to a newer scorecard with evidence and explicit ownership. |

## Linked Source

The closed iPhone/mac operating scorecard is
`packages/agent/docs/post-100-operating-conditions-scorecard.md`. The active
campaign scorecard is
`packages/agent/docs/post-scorecard-gap-hardening-scorecard.md`. The original
iPad deferrals are no longer open loops in the closed operating scorecard; they
are tracked by the IPD rows above and PSG-5 in the active campaign.

## Evidence Log

### 2026-06-01 IPD-0/IPD-1/IPD-2/IPD-6/IPD-8/IPD-9 Checkpoint

- Harness: iPad Pro 13-inch (M5) `E2A39D89-9AF3-431E-A43B-0030C3716482`,
  bundle `com.tron.mobile.beta`; rebuilt app installed and launched with pid
  `57542`; rebuilt dev server healthy on `http://localhost:9847`, PID `56004`.
  Baseline screenshot: `/tmp/tron-psg-evidence/ipd0-ipad-baseline-dashboard.png`.
- Focused tests after fixes passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/DatabaseSchemaTests -only-testing:TronMobileTests/SessionRepositoryTests/testInsertAndGetRoundTrip -only-testing:TronMobileTests/AgentControlSummaryTests -only-testing:TronMobileTests/SessionInfoTests -only-testing:TronMobileTests/AgentControlCardMetricTextTests`
  passed 18 XCTest cases plus 18 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_13-46-12--0700.xcresult`.
  Server query tests also passed:
  `cargo test --manifest-path packages/agent/Cargo.toml domains::session::queries -- --nocapture`.
- Sidebar/session evidence: Computer Use verified the iPad empty selection state,
  opened the persistent sidebar, selected direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087`, and preserved the split-view
  sidebar while the chat opened. Sidebar evidence:
  `/tmp/tron-psg-evidence/ipd1-ipad-sidebar-session-cards.png`.
- Chat evidence: iPad prompt `IPD-2 iPad smoke check. Reply with exactly:
  IPD-2 ready.` completed with final assistant text `IPD-2 ready.` and two
  visible capability cards. DB session truth after the run:
  `message_count=4`, `event_count=18`, `turn_count=3`,
  `total_input_tokens=17885`, `total_output_tokens=318`, cache totals `0`,
  cost `0.0`. Event counts: two capability starts, two capability completions,
  three `stream.turn_start`, three `stream.turn_end`, three assistant messages,
  one user message, one rules-loaded row, one session-start row, and two
  Anthropic OAuth hook rows. The hook `invalid_grant` rows are title/suggest
  prompt background noise and did not block the iPad chat path.
- Failure found and fixed: the iPad Agent Control History row initially rendered
  `0 turns` and `0 capability calls` while the server session row already held
  `turn_count=3`. Root cause was client projection/persistence: `session::list`
  did not expose `turnCount`, `CachedSession` did not persist it, and
  `AgentControlSummary.fromSession` defaulted turns/capabilities to zero.
  Fixes added server `turnCount`, iOS `SessionInfo.turnCount`,
  `CachedSession.turnCount`, schema v14 `turn_count`, repository round-trip and
  migration coverage, and explicit unknown-vs-zero capability-call state.
- Visual/sheet fix: Agent Control now uses balanced `.compactForm` sizing
  only on iPad and applies `.ultraThinMaterial` only for iPad floating
  presentations; iPhone keeps the previous sizing/background behavior. Manual
  evidence screenshot:
  `/tmp/tron-psg-evidence/ipd-agent-control-compact-glass-history-fixed.png`.
  Visible result: compact glassy Agent Control sheet with the chat/sidebar
  visible behind it; Context `10%`, Model `Gemma 4 E4B`, Source Control
  `next/modular-capability-engine` with `Changes`, Analytics `18.2k`/`$0.00`,
  and History `3 turns` with capability calls provisional as `...` until local
  event detail completes.
- History drill-down evidence:
  `/tmp/tron-psg-evidence/ipd-history-detail-compact-glass.png` showed
  pre-session activity plus turns 1, 2, and 3, including the capability
  invocation turn, from the compact iPad sheet.
- Additional IPD-6 live-update failure found and fixed: a newly seeded isolated
  worktree session `sess_019e84f6-3d34-70a3-b083-812988035042` showed the
  correct isolated Source Control branch after acquiring a worktree, but Agent
  Control History regressed to `0 turns` after the first same-device run while
  the server DB already had `turn_count=1`. Root cause was the live
  `session.updated` contract and local projection: completion/model-switch
  updates did not carry `eventCount`/`turnCount`, the model-switch path also
  sent `event_count` as `messageCount`, and Agent Control preferred a stale
  in-memory `CachedSession` over the freshly refreshed persisted summary.
  Fixes added `eventCount`/`turnCount` to `TronEvent::SessionUpdated`, stream
  projection, completion and model-switch emits, iOS `SessionUpdatedPlugin`,
  `EventStoreManager.handleSessionUpdated`, and Agent Control summary merging.
  Title-only session updates still omit all count fields.
- Live iPad proof after the fix used the same open iPad Simulator and no app
  relaunch after the second prompt. Agent Control showed Source Control
  `019e84f6`, `No changes`, Analytics `11.0k`/`$0.00`, and History `2 turns`.
  Screenshot:
  `/tmp/tron-psg-evidence/ipd6-isolated-agent-control-live-turncount-fix.png`.
  DB evidence:
  `/tmp/tron-psg-evidence/ipd6-isolated-agent-control-live-turncount-db.txt`
  shows `message_count=4`, `event_count=15`, `turn_count=2`,
  `total_input_tokens=10935`, `total_output_tokens=86`, cache totals `0`,
  cost `0.0`, plus two user messages, two assistant messages, two
  `stream.turn_start`, two `stream.turn_end`, and one `worktree.acquired`.
- Additional focused tests after the live-update fix passed:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check &&
  cargo test --manifest-path packages/agent/Cargo.toml session_updated --lib
  -- --nocapture` passed 2 Rust tests; iPad
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/AgentControlSummaryTests -only-testing:TronMobileTests/SessionUpdatedPluginTests`
  passed 11 XCTest cases, including both persisted-newer and live-memory-newer
  Agent Control merge paths; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-09-49--0700.xcresult`.
- Additional IPD-6 dirty direct-branch failure found and fixed: the Source
  Control drill-down refresh correctly loaded a dirty direct-branch diff, but
  after closing and reopening Agent Control the compact Source Control row still
  showed stale `Direct branch` because the drill-down reload did not refresh
  `WorktreeStatusCache` or the presenting card summary. Fixed by routing every
  Source Control sheet status/diff reload path back through the parent
  `onWorktreeStatusShouldRefresh` callback. The shared cache now overwrites stale
  clean status with dirty server results.
- Dirty direct-branch manual evidence used a temporary untracked probe file and
  the open iPad Simulator; the probe was deleted after proof. Before the fix,
  the full Source Control sheet and file detail rendered the dirty untracked
  file while the compact card remained stale. Evidence:
  `/tmp/tron-psg-evidence/ipd6-direct-branch-source-control-dirty-sheet.png`
  and `/tmp/tron-psg-evidence/ipd6-direct-branch-file-diff-detail.png`.
  After the fix and rebuilt app launch, the compact Agent Control Source
  Control card showed dirty summary counts (`3 files`, `+31`, `-20`) for the
  direct branch instead of `Direct branch`; screenshot
  `/tmp/tron-psg-evidence/ipd6-direct-branch-agent-control-dirty-summary-fixed.png`.
  Worktree invocation evidence:
  `/tmp/tron-psg-evidence/ipd6-direct-branch-dirty-summary-fixed-db.txt`.
- Additional focused tests after the dirty-summary fix passed:
  `git diff --check`; iPad
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/WorktreeStatusCacheTests -only-testing:TronMobileTests/SourceControlCardStateTests`
  passed 30 XCTest cases plus 6 Swift Testing checks, including
  `test_refresh_overwritesStaleCleanStatusWithDirtyServerResult`; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-19-03--0700.xcresult`.
- Simulator access recovery: after the dirty-summary checkpoint, the iPad
  Simulator framebuffer stayed booted but Simulator.app exposed zero macOS
  windows, causing Computer Use `cgWindowNotFound`. Per the plan, Simulator was
  force-quit and reopened on the same UDID
  `E2A39D89-9AF3-431E-A43B-0030C3716482`; `xcrun simctl launch` and screenshot
  proof still worked at
  `/tmp/tron-psg-evidence/ipd-windowless-tron-launch-check.png`. Computer Use
  recovered after selecting `Window -> iPad Pro 13-inch (M5) - iOS 26.4`, which
  restored one Simulator window.
- Additional IPD-1/IPD-8/IPD-9 sidebar proof after window recovery:
  `/tmp/tron-psg-evidence/ipd1-sidebar-variants-after-window-recovery.png`
  shows the persistent iPad split sidebar with isolated branch-icon row,
  forked rows, direct-branch row, long-title non-git/path row, selected-state
  contrast, and existing session rows truncated without visible text overlap.
- Additional IPD-1 archive-context discoverability proof: Computer Use attempted
  the sidebar context action on the selected session row. The Simulator did not
  render a separate visible context menu, but the accessibility tree exposed
  `Archive` as a secondary action on the selected session and every visible
  sidebar row. Archive was not invoked because it is a destructive session
  action requiring action-time confirmation. Evidence:
  `/tmp/tron-psg-evidence/ipd1-sidebar-context-actions.txt`.
- Additional IPD-6 non-git proof: selecting non-git session
  `sess_019e84f6-3d43-7e51-9bb6-70deff30ee24` opened the chat in split view;
  Agent Control rendered Context, Model, Analytics, History, and Session ID but
  no Source Control card. Screenshot:
  `/tmp/tron-psg-evidence/ipd6-nongit-agent-control-no-source-control.png`.
  DB evidence paired with the screenshot: the session row has `use_worktree=0`,
  working directory `/tmp/tron-ipd-nongit-visible-20260601205310`, and recent
  `worktree::get_status` returned `{"hasWorktree":false,"worktree":null}` in
  `/tmp/tron-psg-evidence/ipd6-recent-worktree-invocations-after-nongit.json`.
- Additional IPD-6 isolated clean drill-down proof after window recovery:
  `/tmp/tron-psg-evidence/ipd6-isolated-agent-control-window-recovery.png`
  shows compact Agent Control for
  `sess_019e84f6-3d34-70a3-b083-812988035042` with Source Control `019e84f6`,
  `No changes`, Analytics `11.0k`/`$0.00`, and History `2 turns`.
  `/tmp/tron-psg-evidence/ipd6-isolated-source-control-clean-sheet-window-recovery.png`
  shows the Source Control drill-down on the isolated worktree path with
  Working tree clean, Commit/Merge/Sessions/Pull disabled with visible help
  text, and Rebase/Push present but not triggered because those actions require
  action-time confirmation.
- Additional IPD-3 input proof: Computer Use focused the iPad input bar, typed
  `IPD-3 iPad input check. Reply exactly: IPD-3 input ready.`, and clicked the
  active send icon. During the run the row rendered the user prompt, the input
  reset to placeholder, Stop Agent replaced Send, and voice recording was
  disabled; screenshot
  `/tmp/tron-psg-evidence/ipd3-input-inflight-stop-state.png`. The completed
  assistant response matched exactly `IPD-3 input ready.`; screenshot
  `/tmp/tron-psg-evidence/ipd3-input-completed-response.png`. DB evidence in
  `/tmp/tron-psg-evidence/ipd3-input-completed-session-db.txt` shows
  `message_count=6`, `event_count=20`, `turn_count=3`, input tokens `16456`,
  output tokens `94`, cache totals `0`, and cost `0.0`.
- Additional IPD-1/IPD-9 sidebar date-label failure found and fixed: after the
  IPD-3 completion, the sidebar row accessibility label briefly reported
  `in 0 seconds` for fresh activity. Root cause was the full relative date path
  in `DateParser.formatRelativeOrAbsolute`, which let sub-minute timestamps go
  through `RelativeDateTimeFormatter`. Fixed by clamping near-now or slightly
  future timestamps to `now`; iPad
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/DateParserTests`
  passed 15 tests, including current and near-future regression cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-36-31--0700.xcresult`.
- Additional IPD-3 skill-popup failure found and fixed: the iPad attachment
  menu opened correctly and Add Skill inserted `browse-the-web`, but the staged
  chip collapsed the visible remove icon into the single `Skill,
  browse-the-web` accessibility element. Root cause was `SkillChip` applying
  `.accessibilityElement(children: .ignore)` even in removable input state.
  Fixed by keeping sent-message chips collapsed while staged removable chips
  expose separate `Skill, browse-the-web` and `Remove skill, browse-the-web`
  controls. Evidence before/after:
  `/tmp/tron-psg-evidence/ipd3-attachment-menu.png`,
  `/tmp/tron-psg-evidence/ipd3-skill-popup.png`,
  `/tmp/tron-psg-evidence/ipd3-skill-chip-added.png`, and
  `/tmp/tron-psg-evidence/ipd3-skill-chip-removed-after-accessibility-fix.png`.
  Focused iPad verification passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/InputBarContentAreaChipTests`
  passed 8 tests, including removable skill-chip labels; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-45-30--0700.xcresult`.
- Additional IPD-3 queued-prompt proof: during an active long
  `gemma4:e4b` turn, Computer Use typed a second prompt and clicked Send.
  The input row showed Stop Agent, voice recording disabled, and a queued chip
  at position `1`; screenshot
  `/tmp/tron-psg-evidence/ipd3-queued-prompt-chip-active-turn.png`. After the
  first turn completed, the queued follow-up drained automatically and the
  assistant answered exactly `IPD-3 queued ready.`; screenshot
  `/tmp/tron-psg-evidence/ipd3-queued-prompt-drained-completed.png`. DB
  evidence `/tmp/tron-psg-evidence/ipd3-queue-session-db.txt` shows one
  `message.queued`, one `message.dequeued`, 5 turns, 10 messages, 32 events,
  27,973 input tokens, 549 output tokens, no cache tokens, and cost `0.0`.
- Additional token-record hardening from the same resumed iPad session:
  the queued-prompt DB audit found older rows with session counters at 5 but
  runtime events and `TokenRecord.meta.turn` still serialized as turn `1`.
  Fixed the server prompt-agent construction so resumed runs are seeded from
  persisted session `turn_count`; after rebuild, a live verifier prompt
  returned exactly `IPD-3 turn offset ready.` and DB evidence
  `/tmp/tron-psg-evidence/ipd3-turn-offset-verifier-db.txt` shows
  `turn_count=6`, latest `message.assistant.turn=6`, latest
  `stream.turn_end.turn=6`, and latest `tokenRecord.meta.turn=6`. Screenshot:
  `/tmp/tron-psg-evidence/ipd3-turn-offset-verifier-completed.png`.
- Additional IPD-3 attachment proof: `xcrun simctl addmedia` imported a tiny
  PNG into the iPad Simulator photo library, Computer Use opened
  `Add attachment -> Photo Library`, selected the thumbnail, and confirmed the
  picker. The staged input row rendered an `Image` chip, `68 B`, enabled Send,
  and exposed a separate accessibility button
  `Remove attachment, Image, 68 B`; screenshot
  `/tmp/tron-psg-evidence/ipd3-photo-attachment-staged.png`. Clicking that
  remove control cleared the chip and returned the input row to idle state;
  screenshot `/tmp/tron-psg-evidence/ipd3-photo-attachment-removed.png`.
  Follow-up document-file picker proof seeded the iPad Simulator
  `Media/Downloads` file-provider root with a tiny text fixture, opened
  `Add attachment -> Choose File`, and verified the available fixture was
  visible under `On My iPad`; screenshot
  `/tmp/tron-psg-evidence/ipd3-document-picker-on-my-ipad-fixture.png`.
  Selecting it staged `ipd3-attachment-fixture.txt` as a document attachment
  with size `25 B`, enabled Send, and exposed a separate accessibility control
  `Remove attachment, ipd3-attachment-fixture.txt, 25 B`; staged and removed
  proof:
  `/tmp/tron-psg-evidence/ipd3-document-attachment-staged.png` and
  `/tmp/tron-psg-evidence/ipd3-document-attachment-removed.png`.
- Additional IPD-7 settings proof: Computer Use opened the iPad Settings
  surface from the chat gear. Screenshot
  `/tmp/tron-psg-evidence/ipd7-settings-grid-ipad.png` shows the compact
  glassy Settings grid with App, Server, Providers, Agent, Context, and Plugin
  Sources cards, plus separated destructive rows for Clear Prompt History,
  Archive All Sessions, and Reset All Settings. A mistaken tap on Reset All
  Settings opened a confirmation dialog; Cancel was pressed and no reset
  occurred. The sheet then moved to its lower compact position and dismissed by
  the checkmark without changing settings.
- Additional IPD-9 visual/accessibility proof: `xcrun simctl ui` switched the
  iPad appearance to light and captured
  `/tmp/tron-psg-evidence/ipd9-light-mode-sidebar-chat.png`; the app kept the
  dark Tron theme, with readable text and no new overlap in the visible split
  layout. Dynamic Type was then changed from `large` to
  `accessibility-extra-extra-large` and captured at
  `/tmp/tron-psg-evidence/ipd9-accessibility-extra-extra-large.png`; the visible
  session sidebar, chat transcript, model pill, and input controls remained
  stable without overlapping text. Content size was restored to `large` and
  appearance to dark after the pass.
- Additional IPD-4 notification proof used the open iPad Pro 13-inch (M5)
  Simulator `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle
  `com.tron.mobile.beta`, against rebuilt dev server PID `50456`. Two seeded
  server notification resources were visible in the sidebar notification inbox:
  `notification:019e8546-aa68-7230-8bf3-313ff3ddbf54` for isolated session
  `sess_019e84f6-3d34-70a3-b083-812988035042` and
  `notification:019e8547-2b34-76d3-8fd4-baff7588277d` for direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087`. Screenshots prove the unread
  sidebar badge, inbox list, detail content, local read-all clearing, and final
  cleared badge:
  `/tmp/tron-psg-evidence/ipd4-notification-bell-badge-sidebar.png`,
  `/tmp/tron-psg-evidence/ipd4-notification-list-sheet.png`,
  `/tmp/tron-psg-evidence/ipd4-notification-detail-sheet.png`,
  `/tmp/tron-psg-evidence/ipd4-notification-read-all-cleared.png`, and
  `/tmp/tron-psg-evidence/ipd4-notification-sidebar-badge-cleared.png`.
  DB/resource evidence in
  `/tmp/tron-psg-evidence/ipd4-notification-mark-all-read-after-read-all.json`
  shows opening detail invoked `notifications::mark_read` scoped to
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` with `unreadCount=1`; pressing
  `Read All` invoked `notifications::mark_all_read` with `marked=1` and
  `unreadCount=0`. The notification resources also captured `delivery_failed`
  APNs evidence for invalid local simulator device tokens while still creating
  inbox-visible resources, which covers the local offline/delivery-failure
  state without treating provider delivery as a UI failure.
- Follow-up IPD-4 fix after user review found the notification inbox/detail
  iPad sheets were visually too large and that `tron://notification/<id>` could
  leave an already-open inbox on the list instead of auto-opening the target
  detail after refresh. `NotificationListSheet` and
  `NotificationInboxDetailSheet` now use iPad-only compact liquid-glass form
  sizing while preserving iPhone detents, and the notification deep-link target
  is a live binding that retries after notification rows refresh. Focused tests
  passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests`
  passed 3 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_15-37-38--0700.xcresult`.
  Manual iPad proof used the rebuilt app launched as pid `28776`; opening
  `tron://notification/019e8547-2b34-76d3-8fd4-baff7588277d` with
  `xcrun simctl openurl` returned `openurl_exit=0`, Computer Use showed the
  compact glass detail sheet over the split dashboard, and the screenshot is
  `/tmp/tron-psg-evidence/ipd4-notification-compact-deeplink-detail-fixed.png`.
  DB evidence includes `notifications::list` invocation
  `019e8556-5c0c-7ba2-8267-6cd17d4675db` at
  `2026-06-01T22:38:09.943498+00:00` returning the target notification with
  `isRead=true` and `deliveryStatus=delivery_failed`.
- Follow-up IPD-7/IPD-9 sheet-shape fix after user review found the iPad glass
  forms had become too wide and not tall enough. The shared adaptive
  presentation helper now keeps the existing non-iPad `.largeForm` branch,
  routes only iPad large presentations through a balanced large form, and
  retunes compact iPad sheets to a narrower/taller form. Source guards passed
  after `xcodegen generate`:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests`
  passed 4 XCTest cases. Manual Computer Use proof on bundle
  `com.tron.mobile.beta`, iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`, verified portrait and landscape for
  Settings, Agent settings, Agent Control, notification list, and notification
  detail. Portrait screenshots:
  `/tmp/tron-psg-evidence/ipad-balanced-settings-sheet-retuned-portrait.png`,
  `/tmp/tron-psg-evidence/ipad-balanced-agent-settings-retuned-portrait.png`,
  `/tmp/tron-psg-evidence/ipad-balanced-agent-control-retuned-portrait.png`,
  `/tmp/tron-psg-evidence/ipad-balanced-notifications-list-retuned-portrait.png`,
  and `/tmp/tron-psg-evidence/ipad-balanced-notification-detail-retuned-portrait.png`.
  Landscape screenshots:
  `/tmp/tron-psg-evidence/ipad-balanced-settings-retuned-landscape.png`,
  `/tmp/tron-psg-evidence/ipad-balanced-agent-settings-retuned-landscape.png`,
  `/tmp/tron-psg-evidence/ipad-balanced-agent-control-retuned-landscape.png`,
  `/tmp/tron-psg-evidence/ipad-balanced-notifications-list-retuned-landscape.png`,
  and `/tmp/tron-psg-evidence/ipad-balanced-notification-detail-retuned-landscape.png`.
  At that checkpoint, open loops still included IPD-7
  pairing/unavailable-server/protected-branch details and IPD-9 pointer/full
  keyboard traversal, so no new points were awarded.
- Follow-up landscape hardening after live Computer Use found the long Agent
  settings sheet still could not be moved deeply enough in the iPad landscape
  Simulator. The iPad-only sheet presentation path now keeps the narrower/taller
  liquid-glass size, prioritizes sheet content scrolling, constrains presented
  content to the same visible form frame, and the shared Settings container
  bounds its `ScrollView` to the sheet viewport. Agent settings now has an
  iPad-landscape two-column layout that keeps Protected Branches visible near
  the top instead of relying on a deep scroll. iPhone/non-iPad presentation
  styling remains on the existing branch. Focused iPad verification passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests -only-testing:TronMobileTests/SettingsPageContainerTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  with 6 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_17-30-58--0700.xcresult`.
  Manual landscape proof used rebuilt bundle `com.tron.mobile.beta`, launch pid
  `866`, and iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`: screenshot
  `/tmp/tron-psg-evidence/ipd7-agent-settings-protected-branches-landscape-final.png`
  shows the Agent two-column sheet with Protected Branches immediately visible,
  including `main`, `master`, `develop`, and the add-field. Server profile truth
  matched exactly:
  `/Users/moose/.tron/profiles/default/profile.toml:229 protectedBranches = ["main", "master", "develop"]`.
  Remaining IPD-7 loops are provider/profile/auth, pairing/onboarding, and
  unavailable-server retry evidence; no new points were awarded yet.
- Follow-up sheet-shape review after the user found the latest iPad sheets still
  a little too wide and not tall enough retuned only the iPad presentation
  helpers at that checkpoint: large forms targeted
  `min(referenceWidth * 0.62, 700)` by
  `min(referenceHeight * 0.82, 900)`, compact forms targeted
  `min(referenceWidth * 0.56, 620)` by `min(referenceHeight * 0.70, 780)`, and
  the iPhone/non-iPad branch remained unchanged. The same live pass found that
  Server and Providers needed the landscape split too, not only Agent: fixed by
  adding a shared `SettingsAdaptiveLayout`, splitting Providers into model
  provider/service columns, and balancing Server so Diagnostics sits with
  paired-server/transcription controls while Updates owns the second column.
  Focused verification passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests -only-testing:TronMobileTests/SettingsPageContainerTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  with 9 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-01-42--0700.xcresult`.
  Manual Computer Use proof used iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`; when Simulator accessibility became
  inaccessible, Simulator was force-quit and the same UDID was booted/reopened
  before continuing. Final landscape screenshots:
  `/tmp/tron-psg-evidence/ipad-settings-grid-narrow-tall-balanced-final.png`,
  `/tmp/tron-psg-evidence/ipd7-server-settings-landscape-balanced-final.png`,
  `/tmp/tron-psg-evidence/ipd7-providers-settings-landscape-balanced-final.png`,
  and `/tmp/tron-psg-evidence/ipad-agent-control-compact-narrow-tall-balanced-final.png`.
  Provider credential values were not copied into this scorecard.
- Additional sheet-shape retune after further user review found the current
  iPad forms still a little too wide, not tall enough, and able to behave like
  bottom-detent sheets. Root cause was not only the ratio: the iPad branch still
  inherited `.presentationDetents(...)` from the phone path. Fixed by moving
  detents onto the non-iPad branch only, keeping iPad on centered custom
  presentation sizing, and retuning only the iPad metrics again. Large iPad
  forms now target `min(referenceWidth * 0.54, 620)` by
  `min(referenceHeight * 0.90, 980)`, compact iPad forms now target
  `min(referenceWidth * 0.48, 540)` by
  `min(referenceHeight * 0.82, 880)`, and the iPhone/non-iPad detent/background
  behavior remains unchanged. Focused iPad verification passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests -only-testing:TronMobileTests/SettingsPageContainerTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  with 9 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-58-29--0700.xcresult`.
  Manual same-UDID recovery followed the plan after Computer Use returned
  `cgWindowNotFound`: Simulator was quit, killed if still present, the same iPad
  UDID was booted/reopened, and bundle `com.tron.mobile.beta` relaunched as pid
  `81287` for notification proof after the latest build was installed. Computer
  Use still reported no AX-visible Simulator window, but `simctl` screenshots
  confirmed the visible app and opened sheets through non-click deep links.
  Current portrait evidence:
  `/tmp/tron-psg-evidence/ipad-sheet-final-settings-centered-narrow-tall.png`
  and
  `/tmp/tron-psg-evidence/ipad-sheet-final-notification-centered-narrow-tall.png`.
  The Settings form is a centered narrower/taller glass container with its
  footer visible, and the notification list/detail stack is centered over the
  dashboard. Landscape visual proof for this exact retune remains open because
  Simulator still exposes zero AX windows and `Rotate Left`/`Rotate Right`
  menu items were disabled even after Window-menu reselection and same-UDID
  relaunch; deterministic iPad landscape layout guards still passed.
- Follow-up same-UDID recovery after the checkpoint still left manual
  action-time iPad rows environment-blocked. The device was fully shut down
  with `xcrun simctl shutdown E2A39D89-9AF3-431E-A43B-0030C3716482`, Simulator
  was quit and killed, the same iPad UDID was booted/reopened, the current beta
  app was reinstalled and relaunched as pid `1615`, and screenshot
  `/tmp/tron-psg-evidence/ipad-recovery-fresh-boot-visible.png` proved the
  framebuffer remained available. Computer Use still returned
  `cgWindowNotFound`; System Events reported process `Simulator` as visible but
  with zero windows; `Rotate Left` and `Rotate Right` remained disabled; and a
  direct launch of the Spotlight-resolved bundle
  `/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app` did
  not restore an AX-visible device window. That checkpoint recorded an
  environment blocker for current-retune landscape proof and action-time manual
  flows, not an app UI failure.
- Previous sheet-shape review after the user found the current forms still a
  little too wide and not tall enough retuned only the iPad presentation
  metrics again. Large iPad forms now target
  `min(referenceWidth * 0.50, 580)` by
  `min(referenceHeight * 0.92, 980)`, compact iPad forms target
  `min(referenceWidth * 0.44, 500)` by
  `min(referenceHeight * 0.88, 920)`, and the iPhone/non-iPad branch still keeps
  its existing detents and background behavior. Focused verification passed
  after `xcodegen generate`:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests`
  with 4 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_19-31-09--0700.xcresult`.
  Computer Use recovered on the same iPad Pro 13-inch (M5) Simulator window,
  bundle `com.tron.mobile.beta` was launched as pid `49779`, and the same
  direct-branch session plus seeded notification deep link were verified in
  portrait and landscape. Evidence:
  `/tmp/tron-psg-evidence/ipd-sheet-retune-agent-control-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-retune-agent-control-landscape.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-retune-notification-portrait.png`, and
  `/tmp/tron-psg-evidence/ipd-sheet-retune-notification-landscape.png`.
  This closes the previous current-retune landscape proof blocker; action-time
  voice-note/source-control/approval/fork/pointer rows remain open.
- Latest user review then found the current iPad forms still a little too wide
  and not tall enough. Retuned only the iPad metrics again: large forms now target
  `min(referenceWidth * 0.46, 540)` by
  `min(referenceHeight * 0.94, 1020)`, compact forms target
  `min(referenceWidth * 0.40, 470)` by
  `min(referenceHeight * 0.92, 960)`, and iPhone/non-iPad detent/background
  behavior remains unchanged. Focused verification passed after
  `xcodegen generate`:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests -only-testing:TronMobileTests/TranscriptionCoordinatorTests`
  with 28 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_19-45-51--0700.xcresult`.
  Manual Computer Use proof used bundle `com.tron.mobile.beta`, launch pid
  `77571`, and iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`; screenshots:
  `/tmp/tron-psg-evidence/ipd-sheet-retune2-agent-control-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-retune2-agent-control-landscape.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-retune2-notification-portrait.png`, and
  `/tmp/tron-psg-evidence/ipd-sheet-retune2-notification-landscape.png`.
- IPD-7 final Settings/unavailable/onboarding pass found and fixed one Server
  page projection gap: when the active paired server was offline, the page
  warned in the summary but hid the `Server Controls` unavailable card because
  both status branches required `!activeServerUnavailable`. The page now uses
  `ConnectionSettingsServerControlsStatus`: no active server renders no fake
  loading card, an offline active server renders explicit unavailable copy, and
  a connected not-yet-loaded active server still renders loading copy. Focused
  TDD coverage first failed because the primitive was missing, then passed after
  the fix:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/ServerSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  with 4 XCTest cases plus 23 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-19-29--0700.xcresult`.
  Manual landscape proof used bundle `com.tron.mobile.beta` on iPad Pro
  13-inch (M5) `E2A39D89-9AF3-431E-A43B-0030C3716482`: dev server PID `50456`
  was temporarily stopped by booting out the dev LaunchAgent, port `9847`
  returned closed, Settings showed the main unavailable card and the Server page
  unavailable card, and the active server menu exposed `Retry`/`Forget` without
  invoking destructive Forget. Screenshots:
  `/tmp/tron-psg-evidence/ipd7-settings-unavailable-main-card-fixed.png`,
  `/tmp/tron-psg-evidence/ipd7-server-page-unavailable-status-card-fixed.png`,
  and `/tmp/tron-psg-evidence/ipd7-server-unavailable-retry-menu.png`.
  Restarting dev takeover produced healthy PID `79934`, after which the same
  Server sheet recovered to connected server settings; screenshot
  `/tmp/tron-psg-evidence/ipd7-server-page-recovered-after-dev-restart.png`.
  Settings-to-onboarding proof showed `Connect to a new server` opening the
  `Connect your Mac` sheet, manual entry exposing host/port/token/name fields
  with Connect disabled until valid input, connected-server `Set Up` opening
  the same sheet with Connect enabled by stored-token reuse, prefilled
  host/port/name with the token field blank, and Connect advancing to the
  workspace step without exposing a token. Screenshots:
  `/tmp/tron-psg-evidence/ipd7-settings-onboarding-connect-step.png`,
  `/tmp/tron-psg-evidence/ipd7-settings-onboarding-manual-entry.png`,
  `/tmp/tron-psg-evidence/ipd7-server-connected-setup-menu.png`,
  `/tmp/tron-psg-evidence/ipd7-server-setup-stored-token-connect-enabled.png`,
  `/tmp/tron-psg-evidence/ipd7-server-setup-prefilled-manual-entry.png`, and
  `/tmp/tron-psg-evidence/ipd7-server-setup-advanced-workspace-step.png`.
  Redacted DB evidence is
  `/tmp/tron-psg-evidence/ipd7-settings-onboarding-redacted-invocations.json`;
  raw provider auth payloads were not copied because they include credential
  labels/metadata.
- Additional IPD-5 capability-detail proof opened direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` on the iPad Simulator and
  tapped completed capability invocation `call_eiaqjnjn` for the read-only
  `process::run` smoke command. Screenshot
  `/tmp/tron-psg-evidence/ipd5-capability-card-target-before-detail.png` shows
  the target capability card in the chat. Screenshot
  `/tmp/tron-psg-evidence/ipd5-capability-detail-popover-ipad.png` shows the
  compact iPad capability popover over the split dashboard, including request
  fields, execution path, preparation, child invocation, and result output
  `IPD-2 ready.`. Metadata expansion proof
  `/tmp/tron-psg-evidence/ipd5-capability-detail-metadata-ipad.png` shows the
  read-only audit metadata/raw payload disclosure. DB evidence in
  `/tmp/tron-psg-evidence/ipd5-capability-detail-db.json` ties the started and
  completed capability events to `call_eiaqjnjn`; engine invocation evidence
  `/tmp/tron-psg-evidence/ipd5-capability-detail-invocations.json` records the
  child `process::run` invocation
  `019e84dd-43c9-7141-90f3-a6770547f239` with `exitCode=0` and stdout
  `IPD-2 ready.`.
- Additional IPD-8 deep-link proof used real route targets from direct-branch
  session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087`. DB target evidence in
  `/tmp/tron-psg-evidence/ipd8-deeplink-db-targets.json` records
  `capability.invocation.completed` event
  `evt_019e84dd-43e6-73f1-b45b-732360da3bff` with invocation
  `call_eiaqjnjn`, and assistant event
  `evt_019e84dd-4a30-7c70-a894-78c8dcf01bdd`. Opening
  `tron://session/sess_019e84d4-8c5b-7ba1-893c-583594bb9087?capability=call_eiaqjnjn`
  returned `openurl_exit=0` and routed the iPad split view to the selected
  session with the `Run Command` capability card visible; screenshot
  `/tmp/tron-psg-evidence/ipd8-session-capability-deeplink-ipad.png`. Opening
  the event-target URL returned `openurl_exit=0` and left the event's rendered
  assistant message area visible; screenshot
  `/tmp/tron-psg-evidence/ipd8-session-event-deeplink-ipad.png`. After
  terminating only `com.tron.mobile.beta`, opening
  `tron://session/sess_019e84d4-8c5b-7ba1-893c-583594bb9087` returned
  `openurl_exit=0` and cold-started into that session; screenshot
  `/tmp/tron-psg-evidence/ipd8-session-cold-start-deeplink-ipad.png`.
- Additional IPD-1/IPD-3 processing and stop proof used the same direct-branch
  local-model session. Computer Use sent
  `IPD-1 processing sidebar proof. Write 120 numbered short lines...`; while
  the turn was active, the iPad chat showed live `Thinking`, `Stop agent`, and
  disabled voice recording, and the selected sidebar row stayed visible with
  the current prompt preview; screenshot
  `/tmp/tron-psg-evidence/ipd1-sidebar-processing-active.png`. After the run
  remained active with no new turn-end DB row, Computer Use clicked
  `Stop agent`; the input returned to idle, the sidebar row updated to
  `6 messages, now`, and the chat showed `Session interrupted`; screenshot
  `/tmp/tron-psg-evidence/ipd1-processing-stopped-interrupted.png`. DB
  evidence in `/tmp/tron-psg-evidence/ipd1-processing-interrupted-db.json`
  shows session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` at
  `message_count=6`, `event_count=23`, `turn_count=4`, with latest
  `message.assistant.turn=4` and `stop_reason=interrupted`, plus a
  `notification.interrupted` event.
- Additional IPD-7 model-picker proof opened Agent Control's Model row and
  verified the iPad Models sheet without changing the selected model. Screenshot
  `/tmp/tron-psg-evidence/ipd7-model-picker-ollama-ipad.png` shows a compact
  glass sheet with Anthropic, OpenAI, Google, MiniMax, Kimi, and Ollama
  providers, the Ollama group expanded, `Gemma 4 E4B` selected, and
  `Gemma 4 26B` visibly marked unavailable. Server evidence in
  `/tmp/tron-psg-evidence/ipd7-model-picker-db.json` records the latest
  `model::list` invocation plus the direct-branch session's `latest_model`
  `gemma4:e4b`.
- Additional IPD-7 provider-settings proof opened Settings -> Providers without
  changing credentials. Screenshot
  `/tmp/tron-psg-evidence/ipd7-providers-settings-ipad.png` shows the compact
  iPad Providers sheet with the configured-provider summary, per-provider
  status rows, add/clear controls, and Google Cloud fields; the accessibility
  tree also exposed the Services section for Brave Search and Exa. Redacted auth
  evidence in `/tmp/tron-psg-evidence/ipd7-provider-auth-redacted.json` records
  only configured provider/service flags and section names, with no secret
  values or token snippets.
- Additional IPD-8 History/fork-control proof opened Agent Control -> History
  after the interrupted turn. Screenshot
  `/tmp/tron-psg-evidence/ipd8-history-sheet-after-interruption-ipad.png`
  shows the compact iPad History sheet with pre-session activity, turns 1-4,
  the interrupted prompt row, and a capability row. Expanding turn 1 exposed
  detail rows and `Fork` controls without invoking them; screenshot
  `/tmp/tron-psg-evidence/ipd8-history-expanded-fork-controls-ipad.png`.
  DB evidence in `/tmp/tron-psg-evidence/ipd8-history-fork-controls-db.json`
  records the session/event counts, forkable event samples, and
  `forkControlClicked=false`. Code inspection confirmed `HistorySheet.performFork`
  immediately forks a session, so actual fork execution remains action-time
  confirmation-gated.
- Additional IPD-8 load-earlier pagination proof added deterministic fixture
  `packages/agent/tests/fixtures/ipd8_long_history_pagination.py`, compiled
  with `python3 -m py_compile`, and ran it against the current server through
  canonical `/engine` calls only: one `session::create` plus 240
  `events::append` message events for session
  `sess_019e8594-79f2-7a72-b406-fdfc7c44aade`. Server evidence
  `/tmp/tron-psg-evidence/ipd8-long-history-pagination.json` shows
  `message_count=240`, `event_count=241` before the app loaded project rules,
  `turn_count=120`, initial `session::reconstruct(limit:100)` with
  `hasMoreEvents=true`, and event type counts of 120 user plus 120 assistant
  messages. Opening `tron://session/sess_019e8594-79f2-7a72-b406-fdfc7c44aade`
  after terminating only `com.tron.mobile.beta` routed the iPad app into the
  seeded session; screenshot
  `/tmp/tron-psg-evidence/ipd8-long-history-load-earlier-before.png` shows the
  Load Earlier Messages control and the visible tail window around turns
  97-120. Clicking the control loaded the earlier page around turns 47-74 while
  preserving the chat/input layout; screenshot
  `/tmp/tron-psg-evidence/ipd8-long-history-load-earlier-after.png`. Engine
  ledger evidence in
  `/tmp/tron-psg-evidence/ipd8-latest-reconstruct-invocations.json` shows the
  app's initial reconstruct at `2026-06-01T23:46:33Z` around assistant 096 and
  the load-earlier reconstruct at `2026-06-01T23:46:54Z` around assistant 046.
  Sidebar selection proof
  `/tmp/tron-psg-evidence/ipd8-long-history-sidebar-selected.png` shows the
  selected long-history session at the top of the iPad sidebar with
  `240 messages`, while the paginated chat stays visible.
- Additional IPD-9 keyboard-focus proof used the same iPad Simulator window
  after it was moved and recovered by Computer Use. The split dashboard stayed
  visible with direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` selected. Screenshot
  `/tmp/tron-psg-evidence/ipd9-keyboard-focus-input-ipad.png` shows the
  message input focused with the caret visible. Accessibility evidence in
  `/tmp/tron-psg-evidence/ipd9-keyboard-focus-accessibility.txt` records the
  focused `Message input` element. A follow-up `Tab` while the multiline input
  was active inserted a tab character into the draft instead of advancing focus;
  the draft was cleared and no message was sent. This failure was isolated to
  the prompt composer rather than source control, sessions, or server state.
- Follow-up IPD-9 prompt-keyboard fix added
  `packages/ios-app/Tests/Views/InputBarKeyboardTraversalTests.swift` and
  changed `InputBar` so iPad hardware Tab resigns the prompt input focus instead
  of inserting a hidden draft character. The new source guard first failed
  against the old source in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-00-15--0700.xcresult`,
  then passed after the fix with focused composer coverage:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/InputBarKeyboardTraversalTests -only-testing:TronMobileTests/InputBarContentAreaChipTests`
  passed 8 XCTest cases plus 1 Swift Testing check; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-03-11--0700.xcresult`.
  Manual proof used the same iPad Pro 13-inch (M5) UDID and
  `com.tron.mobile.beta`: after focusing the existing direct-branch session's
  `Message input`, pressing `Tab` left the placeholder visible, no accessibility
  draft value appeared, and no message was sent in portrait and landscape.
  Screenshots:
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-no-draft-mutation-fixed-portrait.png`
  and
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-no-draft-mutation-fixed-landscape.png`.
  IPD-9 remains running because pointer QA and broader control-to-control
  hardware-keyboard traversal are still open.
- Additional IPD-9 landscape sheet/appearance pass used the same iPad Pro
  13-inch (M5) `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle
  `com.tron.mobile.beta`, with dev takeover still healthy on PID `79934`.
  Evidence screenshots:
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-sidebar-baseline.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-settings-sheet.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-settings-sheet-accessibility-xxxl.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-server-accessibility-xxxl.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-agent-accessibility-xxxl.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-light-app-settings-accessibility-xxxl.png`,
  and `/tmp/tron-psg-evidence/ipd9-agent-tab-focus-add-branch.png`. The pass
  verified the retuned iPad sheet containers in landscape, Settings/Server/Agent
  with `accessibility-extra-extra-extra-large`, and temporary Light mode via the
  app's own Color Mode setting before restoring Dark plus Simulator
  `content_size large`/`appearance dark`. Providers was visually inspected in
  landscape but not captured because the live view includes credential
  labels/snippets. Broader hardware keyboard traversal remains partial: Tab
  focused the Agent protected-branch text field, but a second Tab did not
  visibly advance out of that field. IPD-9 stays running pending pointer QA and
  a broader keyboard traversal decision/fix.
- Additional IPD-1 relaunch preload proof terminated and relaunched
  `com.tron.mobile.beta` on the same iPad UDID; relaunch returned PID `14768`
  while dev takeover stayed healthy on PID `79934`. Screenshot
  `/tmp/tron-psg-evidence/ipd1-sidebar-preload-after-relaunch.png` and the
  accessibility tree both showed the sidebar preloaded with session rows,
  workspace filters, and per-row `Archive` secondary actions immediately after
  launch. This closes the sidebar preload/relaunch assertion; archive execution
  remains action-time confirmation gated.
- Additional IPD-3 voice-note deterministic proof ran the focused iPad target:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/AccessibilityTests -only-testing:TronMobileTests/VoiceNotesRecorderTests -only-testing:TronMobileTests/AudioAvailabilityMonitorTests -only-testing:TronMobileTests/AudioCaptureEngineTests -only-testing:TronMobileTests/MediaClientTests`.
  The run passed 39 XCTest cases plus 9 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-32-53--0700.xcresult`.
  Coverage includes floating voice-note accessibility copy, audio availability
  state, simulator-safe capture start/stop/prewarm/cancel, voice-note recorder
  states, and `voice_notes::save`/`transcription::audio` payload contracts.
  Manual Voice Note sheet opening/record/cancel/submit remains open: Computer
  Use lost the Simulator window with `cgWindowNotFound`, then normal quit,
  `killall Simulator`, same-UDID reopen, same-UDID shutdown/boot, Window-menu
  selection, and File -> Open Simulator selection all left Simulator without
  AX-visible windows. CoreGraphics still reported an onscreen Simulator window
  and simctl screenshots worked; evidence
  `/tmp/tron-psg-evidence/ipd-computer-use-window-recovery-simctl-visible.png`.
  Because voice-note recording can involve microphone capture, the flow was not
  driven by blind coordinate clicks.
- Additional IPD-3 input-row microphone permission proof covered the chat
  transcription mic, which shares the audio capture path but is not the dashboard
  Voice Note sheet. Before the fix, denying the simulator microphone permission
  left a generic `Transcription failed` transcript pill; screenshots:
  `/tmp/tron-psg-evidence/ipd3-voice-note-microphone-permission-prompt.png` and
  `/tmp/tron-psg-evidence/ipd3-voice-note-denied-transcription-failed-toast.png`.
  `TranscriptionCoordinator` now treats permission-denied start failures as an
  explicit `Microphone permission denied` UI error and does not append the
  generic transcript notification. Focused verification passed in the same
  28-test run above, and manual proof is
  `/tmp/tron-psg-evidence/ipd3-input-mic-permission-denied-fixed.png`.
  Dedicated Voice Note sheet record/cancel/submit remains open and
  confirmation-sensitive.
- Additional deterministic IPD-5/IPD-6/IPD-8 coverage ran on the iPad target
  while Computer Use remained blocked for manual action-time flows. IPD-5
  generated UI / approval / user-interaction coverage passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/GeneratedUIRendererTests -only-testing:TronMobileTests/GeneratedUIDTOTests -only-testing:TronMobileTests/UserInteractionTests -only-testing:TronMobileTests/UserInteractionStateTests -only-testing:TronMobileTests/UserInteractionCoordinatorTests -only-testing:TronMobileTests/EngineApprovalStateTests -only-testing:TronMobileTests/EngineApprovalTimelineTests -only-testing:TronMobileTests/ApprovalClientTests`
  with 62 XCTest cases plus 9 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-35-03--0700.xcresult`.
  Source/navigation coverage passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/SourceChangesSheetTests -only-testing:TronMobileTests/GitActionRunnerTests -only-testing:TronMobileTests/SourceControlCardStateTests -only-testing:TronMobileTests/WorktreeClientTests -only-testing:TronMobileTests/WorktreeStatusCacheTests -only-testing:TronMobileTests/DeepLinkRouterTests -only-testing:TronMobileTests/EngineNavigationTests -only-testing:TronMobileTests/ForkNavigationTests -only-testing:TronMobileTests/EngineProtocolTypesWorktreeTests`
  with 57 XCTest cases plus 22 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-35-21--0700.xcresult`.
  A follow-up source metadata/worktree DTO rerun passed 71 Swift Testing checks
  across `FileDetailData`, `SourceControlMetadata`, `DiffContentExtraction`,
  `WorktreeInfo`, `RepoDivergence`, `SessionBranchInfo`,
  `CommittedFileEntry`, `WorktreeCommitParams`, `WorktreeCommitResult`, and
  `GitActionResult` suites; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-52-01--0700.xcresult`.
  This narrows IPD-5/IPD-6/IPD-8 to manual action-time approval decisions,
  source-control mutations, conflict resolution, back/session-tree checks, and
  fork execution rather than DTO/state-machine coverage.
- PSG-6 cleanup scan found and fixed one Agent Control display fallback: when
  no detailed context snapshot or model context window was known, the Context
  card used a fake `1`-token denominator. `AgentControlView` now preserves
  unknown as `0`, and `ContextUsageGaugeView` renders `--`, `Limit unknown`, or
  `{tokens} used (limit unknown)` instead of a misleading percentage/ratio.
  The same cleanup pass renamed `AgentControlSummary.fromEvents` from
  `fallbackSession` to `sessionSnapshot`, because the value is the cached
  server session projection used for local-first reconciliation rather than a
  legacy fallback path.
  Focused iPad verification passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/AgentControlSummaryTests -only-testing:TronMobileTests/AgentControlCardMetricTextTests -only-testing:TronMobileTests/NotificationSheetPresentationTests -only-testing:TronMobileTests/SettingsPageContainerTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  with 24 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_19-05-55--0700.xcresult`.
  The same cleanup pass removed stale "older server" wording from
  `WorktreeCommitResultTests` and the optional `tailscaleIp` DTO comment;
  current semantics are unknown current-server stats and environment-dependent
  server metadata, not compatibility shims.

Open loops before awarding more iPad points: finish IPD-1 archive execution
confirmation, IPD-2
approval/reconnect/deep-link paths,
IPD-3 manual voice-note sheet record/cancel/submit states, IPD-5
approval flows, read-only terminal approvals, and generated UI details, full
IPD-6 action-time-confirmed source-control
actions and conflict resolver, IPD-8
back/session-tree behavior and action-time-confirmed fork execution, IPD-9
pointer QA and full hardware-keyboard traversal, and IPD-10 closeout.
