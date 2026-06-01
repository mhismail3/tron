# Post-100 iPad UI Regression Scorecard

Status: active under `post-scorecard-gap-hardening-scorecard.md`

Created: 2026-05-31

Initial score: **0/100**

Current score: **5/100**

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
| IPD-3 | Input, attachments, voice notes | 8 | pending | Text send, queued prompt, stop, attachment add/remove, skills popup, voice-note available/unavailable/record/cancel/submit states on iPad. |
| IPD-4 | Notifications | 8 | pending | Bell count, list/detail, mark read, mark all read, session-scoped read, offline failure, badge clearing, and notification deep link in split view. |
| IPD-5 | Capability, approval, generated UI | 10 | pending | Detail sheets/popovers, approve/deny/double-tap, read-only terminal approvals, generated UI render/refresh/submit/stale action rejection. |
| IPD-6 | Source control and worktree | 10 | running | Agent Control source-control card, dirty/diff rendering, commit/push/rebase/merge/pull/conflict resolver, disabled destructive actions, and DB policy truth. |
| IPD-7 | Settings, providers, pairing | 8 | pending | Settings grid/sidebar behavior, server unavailable/retry, pairing/onboarding from Settings, providers/OAuth status, model picker, protected branches, and profile/auth truth. |
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
- Visual/sheet fix: Agent Control now uses the shorter `.compactForm` sizing
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

Open loops before awarding more iPad points: finish IPD-1 variants, IPD-2
approval/reconnect/deep-link paths, IPD-3 input/attachments/voice notes, IPD-4
notifications, IPD-5 approval/generated UI details, full IPD-6 source-control
actions, IPD-7 settings/provider/pairing, IPD-8 navigation/deep links, IPD-9
light/accessibility/keyboard/pointer QA, and IPD-10 closeout.
