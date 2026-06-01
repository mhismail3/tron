# Post-Scorecard Gap Hardening Scorecard

Created: 2026-06-01

Initial score: **0/100**

Current score: **65/100**

Status: **active; PSG-1 through PSG-4 complete, PSG-5 iPad UI regression execution running**

This scorecard owns the recent-gap campaign after the collapsed-engine,
codebase-cleanup, post-100 operating, token-accounting, and Agent Control
fast-load work. It is not a whole-repo restart. It reopens only concrete gaps
found in recent scorecards, ledger entries, session transcripts, current code,
and live iPhone/iPad evidence.

## Scope

- Audit recent token-accounting, provider-cache, Agent Control fast-load, and
  Source Control direct-branch/worktree changes.
- Fold the iPad UI regression scorecard into this campaign and close it here
  with real iPad Simulator evidence.
- Mine prior scorecards, ledger, and session transcripts for stale docs,
  missing tests, dead/fallback/compatibility code, and unresolved open loops.
- Use deterministic provider fixtures first, then small configured-provider
  canaries only when credentials/models are available.

Out of scope:

- Full whole-repo architecture reruns unless this campaign finds a real
  regression that invalidates a completed scorecard.
- Production deploys.
- Pull request creation.

## Evidence Contract

Every passed row records the commands, simulator target, bundle id, screenshot
paths, DB/event-log summary, provider/session ids, and focused tests relevant to
that row. Manual UI rows use Computer Use and include the exact visible screen.
Provider rows must not print secrets. SQL evidence must introspect schema before
querying unfamiliar tables.

If a product failure appears, stop breadth testing, classify the owner, add or
identify the smallest covering test, fix only the owning module, remove nearby
dead/fallback/legacy/compatibility code, rerun the failed scenario, update this
scorecard, and commit the checkpoint.

Owner taxonomy: `server_contract`, `client_projection`,
`client_action_wiring`, `ui_rendering`, `stream_or_reconstruction`,
`test_harness`, `environment`, `provider_model_quality`, `docs_or_scorecard`,
`command_hygiene`, and `ledger_or_audit_data`.

## Static Gates

- This scorecard must remain linked from the README living-doc map.
- `post-100-ipad-ui-regression-scorecard.md` must be active under this
  campaign, not a forgotten future scorecard.
- Completed scorecards must not contain stale active status or stale future
  guidance that contradicts their current score.
- Token accounting remains server-authoritative; iOS must not restore local
  pricing, missing-turn defaults, or legacy token fallback reconstruction.
- Agent Control compact cards must use local-first summaries and lightweight
  Source Control summaries; full unified diffs belong in drill-down flows.
- Direct-branch git checkouts must keep Source Control available for commit and
  related actions instead of disappearing from Agent Control.

## Scenario Ledger

| ID | Scenario | Points | Status | Evidence | Open Loops |
|---|---|---:|---|---|---|
| PSG-0 | Prior-scorecard/session audit and campaign formalization | 10 | passed_after_fix | Master scorecard created; `post-100-ipad-ui-regression-scorecard.md` activated under PSG-5; README and iOS docs now link the active recent-gap campaign; collapsed-engine scorecard stale active-handoff status corrected; `post_scorecard_gap_hardening_scorecard_stays_formalized` passed and `git diff --check` was clean. | None for PSG-0. |
| PSG-1 | Token accounting regression audit | 15 | passed_after_fix | 2026-06-01 provider-doc audit rechecked primary docs: OpenAI Responses usage keeps `input_tokens`, `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`, and `total_tokens`; Anthropic usage keeps cache read/write plus `cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`; Google `UsageMetadata` keeps prompt/cached/candidate/tool-use/thought/total and modality detail fields; MiniMax Anthropic-compatible cache docs keep `cache_creation_input_tokens`, `cache_read_input_tokens`, and explicit M2 pricing; Kimi chat docs keep `usage.cached_tokens`, and thinking docs confirm `reasoning_content` consumes tokens; Ollama docs keep `prompt_eval_count` and `eval_count`. Local audit confirmed `domains/model/providers/tokens` owns canonical `TokenRecord`, server pricing returns explicit unavailable states, iOS DTOs consume server token records, and scanned token/UI paths did not restore local pricing or missing-turn defaults. Deterministic evidence: `cargo test --manifest-path packages/agent/Cargo.toml tokens --lib -- --nocapture` passed 205 tests; provider filters passed Anthropic 214, OpenAI 246, Google 145, MiniMax 64, Kimi 93, Ollama 106 tests; iPhone-targeted iOS token/projection tests passed 125 XCTest cases plus 30 Swift Testing cases. Post-IPD resumed-session audit then found and fixed one remaining token-record ordinal bug: every new `TronAgent::run()` reset event `turn` and `TokenRecord.meta.turn` to `1` even though session counters advanced. Fixed by seeding agents with persisted session turn count and using `persisted_turn_count + run_turn` for events/token records while keeping `RunResult.turns_executed` scoped to the current run. Evidence: focused Rust tests passed and live iPad DB proof `/tmp/tron-psg-evidence/ipd3-turn-offset-verifier-db.txt` shows session turn 6 with `message.assistant` and `stream.turn_end` both carrying `turn=6` and `tokenRecord.meta.turn=6`. | Provider docs can drift; rerun primary-doc audit before future pricing/cache semantic changes. |
| PSG-2 | Configured provider canaries | 10 | passed | Current configured canaries passed without secret output. Hosted isolated ROC-2 run `/tmp/roc2_hosted_model_matrix_20260601130028.json` passed Anthropic `claude-sonnet-4-6` (`sess_019e84c6-1156-7df3-9654-bb8d9a529390`), OpenAI `gpt-5.5` (`sess_019e84c6-5818-7dd3-91ba-def3a8bf2571`), and Google `gemini-3.1-pro-preview` (`sess_019e84c6-836a-79e1-a8fa-76f37dfb83c9`) with two successful execute children each, zero failed invocations, zero approvals, zero compactions, zero error/fatal logs, and provider event rows. MiniMax isolated ROC-2 run `/tmp/roc2_hosted_model_matrix_20260601130236.json` passed `MiniMax-M2.7` (`sess_019e84c7-fb95-7bc1-803c-d440d7e8de04`) with the same DB invariants. Ollama isolated ROC-3 run `/tmp/roc3_local_model_breadth_20260601130137.json` passed `gemma4:e4b`; unavailable larger local lane `gemma4:26b` was cataloged as not installed. New no-tool token canary fixture `packages/agent/tests/fixtures/psg_token_provider_canary.py` passed Kimi `kimi-k2.5` in `/tmp/psg_token_provider_canary_20260601130757.json`: session `sess_019e84cc-e0f2-77f1-9af4-47dbe88734e0`, two token-record events, one unique turn record, provider `kimi`, input `14747`, output `514`, total `15261`, priced cost `$0.0103902`, session counters equal canonical record, zero failed invocations, zero `capability::execute`, zero compactions, zero error/fatal logs. Prior TAH cache-hit evidence remains linked for Anthropic, Google, and Kimi cache-read/write behavior. | No PSG-2 blocker. Kimi execute materialization caveat remains non-accounting follow-up from TAH-6, not a token canary failure. |
| PSG-3 | Agent Control fast-load audit | 15 | passed_after_fix | Audit found one iPhone compact-card UX regression in `SourceControlCardState`: after status was known dirty but before summary arrived, the Source Control row still rendered `Loading...` and left `isGitRepo` unknown. Fixed the projection so known dirty status renders branch plus `Changes`, treats a known checkout as a repo unless the summary says otherwise, and never shows the stale loading label once status is known. Covering iOS tests passed: `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceControlCardStateTests -only-testing:TronMobileTests/AgentControlSummaryTests -only-testing:TronMobileTests/AgentControlCardMetricTextTests -only-testing:TronMobileTests/WorktreeClientTests -only-testing:TronMobileTests/WorktreeGetDiffSummaryResultDecodingTests` passed 7 XCTest cases plus 17 Swift Testing cases; xcresult `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_13-18-45--0700.xcresult`. `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants post_scorecard_gap_hardening_scorecard_stays_formalized -- --nocapture` and `git diff --check` also passed. Implementation audit confirmed `AgentControlView.loadAll()` seeds cached session summary and worktree status first, flips cards visible before remote work, loads context/source/events/session refresh/branches independently, and emits debug-only `[AgentControlLoad]` timing calls for sheet open, local session read, local event read, summary build, worktree cache/status/summary, remote event sync, and branch loading. Manual iPhone evidence used bundle `com.tron.mobile.beta` on iPhone 17 Pro `267F6468-09AE-471D-9157-29144173EB82`: Beta build succeeded; install and launch returned pid `96096`; direct-branch session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` opened by `xcrun simctl openurl`; screenshot `/tmp/tron-psg-evidence/psg3-agent-control-direct-dirty-iphone.png` shows Context, Model, Source Control, Analytics, History, and Session ID rows with Source Control branch `next/modular-capability-engine`, `2 files`, `+7`, `-6`, Analytics `0`/`$0.00`, and History `1 turn`/`0 capability calls`, with no placeholder loading text. | Simulator persisted no `AgentControlLoad` lines via `log show --predicate 'process == "TronMobile" AND eventMessage CONTAINS "AgentControlLoad"'`; this was recorded as log collection behavior, not a missing instrumentation path, because the timing call sites are present in the compiled source. |
| PSG-4 | Source Control direct-branch/worktree workflows | 15 | passed | Server tests passed for lightweight summaries: `cargo test --manifest-path packages/agent/Cargo.toml diff_summary --lib -- --nocapture` passed 9 clean/tracked/staged/partial/deleted/renamed/untracked/binary/non-git tests, and `cargo test --manifest-path packages/agent/Cargo.toml worktree::operations::diff --lib -- --nocapture` passed 10 diff and numstat tests. iOS card/client tests above covered direct branch, clean passthrough, dirty summary counts, no-checkout hidden state, non-git summary decoding, and no local full-diff requirement for the compact row. Manual iPhone Source Control sheet evidence used the same direct-branch dirty session and screenshot `/tmp/tron-psg-evidence/psg4-source-control-direct-dirty-sheet-iphone.png`: the sheet displayed direct branch `next/modular-capability-engine`, repo path `~/Downloads/projects/tron`, Commit available, Merge/Rebase/Sessions disabled with isolated-worktree help text, Pull disabled because local main was current, Push available, and the two changed files only after opening drill-down. Timestamped DB evidence from `engine_invocations` after `2026-06-01T20:16:25Z` proved the compact card path called `worktree::get_status` at `20:16:31Z`, `worktree::get_diff_summary` at `20:16:42Z` with `{totalFiles:2,totalAdditions:7,totalDeletions:6}`, and only called full `worktree::get_diff` at `20:17:12Z` after the Source Control sheet opened. | Worktree UI invocations are recorded with `session_id` null even though the session id is passed in request payloads; current evidence used timestamp and payload correlation. If future audit needs per-session invocation joins for worktree UI calls, tag the engine invocation context too. |
| PSG-5 | iPad UI regression execution | 20 | running | `post-100-ipad-ui-regression-scorecard.md` is now at 13/100. IPD-0 passed on iPad Pro 13-inch (M5) `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle `com.tron.mobile.beta`, rebuilt dev server PID `56004`, and focused iPad tests. During IPD Agent Control verification, Computer Use found an iPad History projection regression: the compact row rendered `0 turns`/`0 capability calls` while server DB showed session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` had `message_count=4`, `event_count=18`, `turn_count=3`, input `17885`, output `318`, cache totals `0`, cost `0.0`. Fixed by adding server `turnCount` to `session::list`, iOS `SessionInfo.turnCount`, `CachedSession.turnCount`, schema v14 `turn_count`, repository/migration coverage, and explicit unknown-vs-zero capability-call state. User also clarified that iPhone/iOS sheet styling must stay unchanged, so the compact `.ultraThinMaterial` container is scoped to iPad only. Evidence: `/tmp/tron-psg-evidence/ipd-agent-control-compact-glass-history-fixed.png` shows compact glassy Agent Control with chat/sidebar visible behind it and History `3 turns`; `/tmp/tron-psg-evidence/ipd-history-detail-compact-glass.png` shows the History drill-down with pre-session activity plus turns 1-3. IPD-4 notification evidence now covers badge/list/detail/read/read-all/delivery-failure/deep-link paths plus the iPad-only compact notification sheet fix. Tests passed: `cargo test --manifest-path packages/agent/Cargo.toml domains::session::queries -- --nocapture`; iPad `xcodebuild test -scheme Tron ... DatabaseSchemaTests ... SessionRepositoryTests/testInsertAndGetRoundTrip ... AgentControlSummaryTests ... SessionInfoTests ... AgentControlCardMetricTextTests`; iPad `xcodebuild test -scheme Tron ... NotificationSheetPresentationTests`. | PSG-5 remains open until IPD-1 through IPD-10 finish or residuals are successor-owned; do not award PSG-5 points yet. |
| PSG-6 | Overlooked cleanup scan | 5 | pending | Scan touched token, worktree, Agent Control, event sync, and UI modules for new dead/fallback/legacy/compatibility code. | None yet. |
| PSG-7 | Closeout | 10 | pending | Final docs, README, static gates, focused and broad tests, ledger, diff hygiene, and final commit. | None yet. |

## PSG-5 Running Evidence Addendum

- 2026-06-01 IPD-6 isolated-worktree live update audit found a second
  same-device Agent Control History regression in
  `sess_019e84f6-3d34-70a3-b083-812988035042`: after a live run, Source
  Control correctly showed the acquired isolated branch, but History could show
  stale turn counts because `session.updated` did not carry `eventCount` or
  `turnCount`, model switching used `event_count` as `messageCount`, and Agent
  Control could choose stale in-memory session metadata over a freshly persisted
  server-list summary. Fixed in the server event contract/projection/emits and
  iOS `SessionUpdatedPlugin`, `EventStoreManager`, and `AgentControlSummary`.
- Manual iPad proof used iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle `com.tron.mobile.beta`, rebuilt
  dev server PID `11330`, and the same open app instance. After the second
  prompt, Agent Control showed Source Control `019e84f6`, `No changes`,
  Analytics `11.0k`/`$0.00`, and History `2 turns`. Screenshot:
  `/tmp/tron-psg-evidence/ipd6-isolated-agent-control-live-turncount-fix.png`.
  DB evidence:
  `/tmp/tron-psg-evidence/ipd6-isolated-agent-control-live-turncount-db.txt`.
- Focused verification passed:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check &&
  cargo test --manifest-path packages/agent/Cargo.toml session_updated --lib
  -- --nocapture`; iPad
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/AgentControlSummaryTests -only-testing:TronMobileTests/SessionUpdatedPluginTests`
  passed 11 XCTest cases, xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-09-49--0700.xcresult`.
- 2026-06-01 IPD-6 dirty direct-branch audit then found the compact Source
  Control row could remain stale after the Source Control drill-down refreshed a
  dirty full diff. Root cause was client projection: ordinary
  `SourceControlSheet.loadData()` paths did not notify the presenting Agent
  Control summary or shared `WorktreeStatusCache`; only git sub-sheet dismissals
  did. Fixed by routing sheet refresh, initial load, event-triggered reloads,
  file actions, git action dismissals, and abort refreshes through the parent
  refresh callback. Manual proof after rebuilt app launch showed the compact
  card rendering `3 files`, `+31`, and `-20` for the dirty direct branch;
  screenshot
  `/tmp/tron-psg-evidence/ipd6-direct-branch-agent-control-dirty-summary-fixed.png`,
  invocation evidence
  `/tmp/tron-psg-evidence/ipd6-direct-branch-dirty-summary-fixed-db.txt`.
  Focused iPad tests passed:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/WorktreeStatusCacheTests -only-testing:TronMobileTests/SourceControlCardStateTests`
  with 30 XCTest cases plus 6 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-19-03--0700.xcresult`.
- 2026-06-01 iPad Simulator recovery and additional manual evidence: after
  the dirty-summary checkpoint, Simulator.app exposed zero macOS windows while
  the booted iPad framebuffer and Tron app were still alive. The required
  force-quit/reopen path did not restore a window by itself; selecting
  `Window -> iPad Pro 13-inch (M5) - iOS 26.4` did, after which Computer Use
  resumed on the same UDID. Passive launch proof:
  `/tmp/tron-psg-evidence/ipd-windowless-tron-launch-check.png`. Computer Use
  then verified sidebar variants in
  `/tmp/tron-psg-evidence/ipd1-sidebar-variants-after-window-recovery.png`,
  non-git Agent Control with Source Control suppressed in
  `/tmp/tron-psg-evidence/ipd6-nongit-agent-control-no-source-control.png`,
  non-git DB/worktree invocation evidence in
  `/tmp/tron-psg-evidence/ipd6-recent-worktree-invocations-after-nongit.json`,
  isolated clean compact Agent Control in
  `/tmp/tron-psg-evidence/ipd6-isolated-agent-control-window-recovery.png`, and
  isolated Source Control clean drill-down gating in
  `/tmp/tron-psg-evidence/ipd6-isolated-source-control-clean-sheet-window-recovery.png`.
- 2026-06-01 IPD-3 input audit sent a small local `gemma4:e4b` prompt through
  Computer Use on the iPad input bar. In-flight evidence
  `/tmp/tron-psg-evidence/ipd3-input-inflight-stop-state.png` shows the user
  prompt, input reset, Stop Agent enabled, and voice recording disabled; final
  evidence `/tmp/tron-psg-evidence/ipd3-input-completed-response.png` shows the
  exact response `IPD-3 input ready.`. DB evidence
  `/tmp/tron-psg-evidence/ipd3-input-completed-session-db.txt` shows the
  selected isolated session at 6 messages, 20 events, 3 turns, 16,456 input
  tokens, 94 output tokens, no cache tokens, and `$0.00`.
- The same IPD-3 pass exposed a sidebar accessibility polish bug where fresh
  activity could be announced as `in 0 seconds`. Fixed the shared
  `DateParser.formatRelativeOrAbsolute` near-now path without changing iPhone
  styling; iPad `DateParserTests` passed 15 tests with xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-36-31--0700.xcresult`.
- The IPD-3 attachment menu and skill popup pass then found a staged skill-chip
  accessibility regression: `browse-the-web` inserted successfully, but the
  visible remove icon was hidden inside the single chip accessibility element.
  Fixed `SkillChip` so read-only sent-message chips remain collapsed while
  removable staged chips expose separate skill-detail and remove controls.
  Manual evidence:
  `/tmp/tron-psg-evidence/ipd3-attachment-menu.png`,
  `/tmp/tron-psg-evidence/ipd3-skill-popup.png`,
  `/tmp/tron-psg-evidence/ipd3-skill-chip-added.png`, and
  `/tmp/tron-psg-evidence/ipd3-skill-chip-removed-after-accessibility-fix.png`.
  Focused iPad
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/InputBarContentAreaChipTests`
  passed 8 tests; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_14-45-30--0700.xcresult`.
- IPD-3 queued-prompt verification then exercised an active `gemma4:e4b`
  turn and queued a second prompt while Stop Agent was visible and voice
  recording was disabled. Evidence
  `/tmp/tron-psg-evidence/ipd3-queued-prompt-chip-active-turn.png` shows the
  queued chip with position `1`; `/tmp/tron-psg-evidence/ipd3-queued-prompt-drained-completed.png`
  shows the queued follow-up drained and the exact response
  `IPD-3 queued ready.`. DB evidence
  `/tmp/tron-psg-evidence/ipd3-queue-session-db.txt` shows one
  `message.queued`, one `message.dequeued`, 5 turns, 10 messages, 32 events,
  27,973 input tokens, 549 output tokens, no cache tokens, and `$0.00`.
- The same resumed-session audit exposed a remaining server token-accounting
  ordinal bug: per-run `TronAgent` instances reset runtime event `turn` and
  `TokenRecord.meta.turn` to `1` even while session `turn_count` advanced.
  The fix seeds each prompt agent from the persisted session `turn_count` and
  serializes events/token records with `persisted_turn_count + run_turn`.
  Focused Rust verification passed
  `cargo test --manifest-path packages/agent/Cargo.toml resumed_session_offset_is_used_for_turn_events_and_token_record --lib -- --nocapture`,
  `cargo test --manifest-path packages/agent/Cargo.toml build_token_record --lib -- --nocapture`,
  and `cargo test --manifest-path packages/agent/Cargo.toml tron_agent --lib -- --nocapture`.
  Live iPad proof used the rebuilt dev server PID `50456`; screenshot
  `/tmp/tron-psg-evidence/ipd3-turn-offset-verifier-completed.png` shows the
  exact response `IPD-3 turn offset ready.`, and DB evidence
  `/tmp/tron-psg-evidence/ipd3-turn-offset-verifier-db.txt` shows
  `message_count=12`, `event_count=37`, `turn_count=6`, plus latest
  `message.assistant` and `stream.turn_end` rows carrying both `turn=6` and
  `tokenRecord.meta.turn=6`.
- IPD-3 attachment add/remove evidence then used `xcrun simctl addmedia` to
  import a tiny PNG into the iPad Simulator photo library. Computer Use opened
  `Add attachment -> Photo Library`, selected the thumbnail, and confirmed the
  picker; staged proof
  `/tmp/tron-psg-evidence/ipd3-photo-attachment-staged.png` shows an `Image`
  chip, `68 B`, enabled Send, and separate accessibility control
  `Remove attachment, Image, 68 B`. Removal proof
  `/tmp/tron-psg-evidence/ipd3-photo-attachment-removed.png` shows the chip
  cleared. `Add attachment -> Choose File` opened, but the Simulator Files
  provider did not surface an injected `ipd3-attachment-fixture.txt` under
  `On My iPad`; keep the real document-source picker path open instead of
  claiming document-file coverage from photo-library evidence.
- Additional non-destructive iPad evidence closed more PSG-5 surface area
  without changing app settings or invoking destructive actions:
  `/tmp/tron-psg-evidence/ipd1-sidebar-context-actions.txt` records that
  visible sidebar rows expose `Archive` as a secondary action, but Archive was
  not invoked without action-time confirmation;
  `/tmp/tron-psg-evidence/ipd7-settings-grid-ipad.png` shows the compact iPad
  Settings grid and separated destructive rows, with an accidental Reset
  confirmation canceled; `/tmp/tron-psg-evidence/ipd9-light-mode-sidebar-chat.png`
  and `/tmp/tron-psg-evidence/ipd9-accessibility-extra-extra-large.png` show
  the visible split layout under light appearance request and large Dynamic
  Type, with no new overlap or clipped controls. The Simulator appearance and
  content size were restored after the pass.
- IPD-4 notification evidence now covers the iPad sidebar unread badge, inbox
  list, notification detail, scoped mark-read, global mark-all-read, APNs
  delivery-failure display state, and badge clearing. Screenshots:
  `/tmp/tron-psg-evidence/ipd4-notification-bell-badge-sidebar.png`,
  `/tmp/tron-psg-evidence/ipd4-notification-list-sheet.png`,
  `/tmp/tron-psg-evidence/ipd4-notification-detail-sheet.png`,
  `/tmp/tron-psg-evidence/ipd4-notification-read-all-cleared.png`, and
  `/tmp/tron-psg-evidence/ipd4-notification-sidebar-badge-cleared.png`. DB
  evidence:
  `/tmp/tron-psg-evidence/ipd4-notification-mark-all-read-after-read-all.json`
  shows `notifications::mark_read` scoped to
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` left `unreadCount=1`, then
  `notifications::mark_all_read` marked the remaining notification and returned
  `unreadCount=0`. The seeded notification resources remained visible even
  though APNs delivery recorded `delivery_failed` for invalid simulator-profile
  device tokens.
- User review then found the iPad notification inbox/detail sheets were still
  too tall. Fixed the notification sheets to use the same iPad-only compact
  liquid-glass form sizing as Agent Control while preserving iPhone detents,
  and fixed a live deep-link race so an already-open notification inbox retries
  auto-open after the target invocation id or refreshed rows arrive. Focused
  iPad verification passed 3 XCTest cases in
  `TronMobileTests/NotificationSheetPresentationTests`; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_15-37-38--0700.xcresult`.
  Manual proof used `tron://notification/019e8547-2b34-76d3-8fd4-baff7588277d`
  on iPad Simulator `E2A39D89-9AF3-431E-A43B-0030C3716482`; screenshot
  `/tmp/tron-psg-evidence/ipd4-notification-compact-deeplink-detail-fixed.png`
  shows the compact glass notification detail sheet over the dashboard, and DB
  invocation `019e8556-5c0c-7ba2-8267-6cd17d4675db` returned the target row
  with `isRead=true` and `deliveryStatus=delivery_failed`.

## Verification Plan

Focused automated gates:

```bash
cargo test --manifest-path packages/agent/Cargo.toml tokens --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml diff_summary --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture
python3 -m py_compile packages/agent/tests/fixtures/psg_token_provider_canary.py
python3 packages/agent/tests/fixtures/psg_token_provider_canary.py --no-build --timeout-seconds 240 --model kimi-k2.5
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/AgentControlSummaryTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceControlCardStateTests
```

Final broad gates:

```bash
scripts/tron ci fmt check clippy test
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

Manual Simulator targets:

- iPhone 17 Pro `267F6468-09AE-471D-9157-29144173EB82`, bundle
  `com.tron.mobile.beta`.
- iPad Pro 13-inch (M5) `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle
  `com.tron.mobile.beta`.

If a simulator is inaccessible, force quit Simulator and reopen the same target
UDID before continuing.

## Checkpoints

- Checkpoint 1: Complete. PSG-0 formalized, iPad scorecard activated,
  docs/static gates updated, scorecard invariant passed, commit `996b26ac`.
- Checkpoint 2: Complete. PSG-1/PSG-2 token/provider audit and configured
  canaries complete; evidence recorded here and in the ledger.
- Checkpoint 3: Complete. PSG-3/PSG-4 Agent Control and Source Control audit
  complete with focused gates, iPhone screenshots, and DB invocation evidence.
- Checkpoint 4: In progress. PSG-5 has IPD-0 passed, Agent Control
  History/live-update/dirty-summary regressions fixed with evidence, and
  additional iPad sidebar/non-git/isolated-clean Source Control proof after
  Simulator window recovery. IPD-3 text input and sidebar near-now date display
  have focused proof/fixes; queued prompts, resumed-session token-record turn
  ordinals, and photo attachment add/remove now have live iPad proof.
  Settings grid, archive-action discoverability, and light/Dynamic-Type visual
  QA now have partial evidence too. IPD-4 notification list/detail/read/read-all,
  delivery-failure/badge-clearing, deep-link, and iPad compact-sheet paths now
  have live iPad proof and focused regression coverage. Remaining IPD rows must
  still close or be explicitly successor-owned before final PSG-5 points.
- Checkpoint 5: PSG-6/PSG-7 final cleanup, broad gates, ledger, final commit.
