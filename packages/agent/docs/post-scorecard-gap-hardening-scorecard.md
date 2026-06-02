# Post-Scorecard Gap Hardening Scorecard

Created: 2026-06-01

Initial score: **0/100**

Current score: **70/100**

Status: **active; PSG-1 through PSG-4 and PSG-6 complete, PSG-5 iPad UI regression execution running**

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
| PSG-5 | iPad UI regression execution | 20 | running | `post-100-ipad-ui-regression-scorecard.md` is now at 21/100. IPD-0 and IPD-7 passed on iPad Pro 13-inch (M5) `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle `com.tron.mobile.beta`, with rebuilt dev-server and focused iPad tests; IPD-4 has notification evidence but remains under broader iPad closeout. During IPD Agent Control verification, Computer Use found an iPad History projection regression: the compact row rendered `0 turns`/`0 capability calls` while server DB showed session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` had `message_count=4`, `event_count=18`, `turn_count=3`, input `17885`, output `318`, cache totals `0`, cost `0.0`. Fixed by adding server `turnCount` to `session::list`, iOS `SessionInfo.turnCount`, `CachedSession.turnCount`, schema v14 `turn_count`, repository/migration coverage, and explicit unknown-vs-zero capability-call state. User also clarified that iPhone/iOS sheet styling must stay unchanged, so the compact `.ultraThinMaterial` container is scoped to iPad only. Evidence: `/tmp/tron-psg-evidence/ipd-agent-control-compact-glass-history-fixed.png` shows compact glassy Agent Control with chat/sidebar visible behind it and History `3 turns`; `/tmp/tron-psg-evidence/ipd-history-detail-compact-glass.png` shows the History drill-down with pre-session activity plus turns 1-3. IPD-4 notification evidence now covers badge/list/detail/read/read-all/delivery-failure/deep-link paths plus the iPad-only compact notification sheet fix. Latest user-reviewed sheet retune narrowed/tallened only the iPad compact/large form metrics while leaving iPhone detents unchanged; Computer Use proof captured Agent Control and notification detail/list in portrait and landscape at `/tmp/tron-psg-evidence/ipd-sheet-retune-agent-control-portrait.png`, `/tmp/tron-psg-evidence/ipd-sheet-retune-agent-control-landscape.png`, `/tmp/tron-psg-evidence/ipd-sheet-retune-notification-portrait.png`, and `/tmp/tron-psg-evidence/ipd-sheet-retune-notification-landscape.png`. IPD-7 evidence now covers Settings landscape columns, Server unavailable/retry/recovery, Settings-to-onboarding, connected-server Set Up, provider/model list rendering, protected branches, and redacted DB proof. Tests passed: `cargo test --manifest-path packages/agent/Cargo.toml domains::session::queries -- --nocapture`; iPad `xcodebuild test -scheme Tron ... DatabaseSchemaTests ... SessionRepositoryTests/testInsertAndGetRoundTrip ... AgentControlSummaryTests ... SessionInfoTests ... AgentControlCardMetricTextTests`; iPad `xcodebuild test -scheme Tron ... NotificationSheetPresentationTests`; iPad `xcodebuild test -scheme Tron ... ServerSettingsPageTests ... AgentSettingsPageLayoutTests`. | PSG-5 remains open until IPD-1 through IPD-10 finish or residuals are successor-owned; do not award PSG-5 points yet. |
| PSG-6 | Overlooked cleanup scan | 5 | passed_after_fix | Scan touched token, worktree, Agent Control, event sync, and UI modules for new dead/fallback/legacy/compatibility code. Earlier pass removed the Agent Control display path that manufactured a `1`-token context denominator when the server/model limit was unknown, renamed the local-first summary source from `fallbackSession` to `sessionSnapshot`, and removed stale older-server wording from Worktree commit-result and settings DTO comments. Final pass removed source-control DTO defaults by making `DiffFileEntry.status`, `DiffFileEntry.stagingArea`, and `CommittedFileEntry.status` strict enums, so missing/unknown contract data fails decoding instead of silently becoming `.modified` or `.unstaged`. `EventDatabase` temporary storage was renamed from fallback terminology to `temporaryCache` with no alias, and misleading fallback/compat wording was removed from turn lifecycle, approval note, thinking detail, memory, git error, context, user-interaction, and guard-test paths. Verification: `xcodegen generate` passed; `NotificationSheetPresentationTests` passed 4 XCTest cases after the latest iPad-only sheet retune; strict source-control DTO tests passed 38 Swift Testing checks; focused EventDatabase/UserInteraction/DTO run passed 28 XCTest plus 29 Swift Testing checks; diagnostics/git/memory/sourceguard/thinking/turn-grouping run passed 86 Swift Testing checks; `SourceGuardTests` passed after updating the guard for the current Engine Console component split. Keyword scan residuals were audited and are provider API names, guard-test negative assertions, fixtures, or non-code strings rather than active legacy/fallback paths. | None for PSG-6. |
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
  A later landscape pass added direct-branch iPad Source Control proof for
  existing session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087`: Agent Control
  row proof
  `/tmp/tron-psg-evidence/ipd6-direct-branch-agent-control-landscape.png`,
  drill-down gating proof
  `/tmp/tron-psg-evidence/ipd6-direct-branch-source-control-sheet-landscape.png`,
  and git/UI evidence
  `/tmp/tron-psg-evidence/ipd6-direct-branch-source-control-landscape.json`
  show branch `next/modular-capability-engine`, clean working tree,
  Commit/Merge/Rebase/Sessions/Pull disabled for their stated reasons, and Push
  available but not clicked because it mutates remote state.
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
  cleared. Follow-up document-file picker proof seeded the iPad Simulator
  `Media/Downloads` file-provider root with a tiny text fixture, opened
  `Add attachment -> Choose File`, verified the fixture under `On My iPad`,
  selected it, and staged/removes it through the input row. Screenshots:
  `/tmp/tron-psg-evidence/ipd3-document-picker-on-my-ipad-fixture.png`,
  `/tmp/tron-psg-evidence/ipd3-document-attachment-staged.png`, and
  `/tmp/tron-psg-evidence/ipd3-document-attachment-removed.png`. The staged
  accessibility output exposed a separate remove control for
  `ipd3-attachment-fixture.txt`, so document-file add/remove is now covered by
  real picker evidence.
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
- Follow-up sheet-shape review then found the iPad glass forms had overcorrected
  too wide and not tall enough. Retuned only the iPad presentation sizing path:
  iPad `.largeForm` now maps to a balanced large form while the non-iPad branch
  keeps the existing `.largeForm`, and compact iPad sheets use a narrower,
  taller balanced form. Focused verification passed
  `xcodegen generate` and
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests`
  with 4 XCTest cases. Manual iPad proof used rebuilt bundle
  `com.tron.mobile.beta` on iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`; portrait screenshots:
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
  Computer Use verified row contents, filter controls, footer/actions,
  landscape proportions, and detail text remained visible without the sheets
  reading as tall cards or short over-wide strips, but protected-branch details
  still needed a follow-up pass.
- 2026-06-01 follow-up sheet-shape review after the user reported the current
  iPad forms were still a little too wide and not tall enough retuned only the
  iPad metrics again. Current large iPad forms target
  `min(referenceWidth * 0.46, 540)` by
  `min(referenceHeight * 0.94, 1020)`; compact iPad forms target
  `min(referenceWidth * 0.40, 470)` by
  `min(referenceHeight * 0.92, 960)`. The iPhone/non-iPad branch remains on its
  existing detents and background behavior. Focused verification passed
  `xcodegen generate` and
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
- 2026-06-01 IPD-3 input-row microphone permission pass found that denying
  microphone permission through the chat transcription mic could previously
  leave a generic `Transcription failed` transcript pill. `TranscriptionCoordinator`
  now maps microphone permission-denied start failures to explicit
  `Microphone permission denied` UI and does not append the generic failure
  notification. Evidence before/after:
  `/tmp/tron-psg-evidence/ipd3-voice-note-microphone-permission-prompt.png`,
  `/tmp/tron-psg-evidence/ipd3-voice-note-denied-transcription-failed-toast.png`,
  and `/tmp/tron-psg-evidence/ipd3-input-mic-permission-denied-fixed.png`.
  Dedicated dashboard Voice Note sheet record/cancel/submit remains open because
  microphone capture is action-time confirmation sensitive.
- Follow-up IPD-7/IPD-9 landscape hardening found that the long iPad Agent
  settings sheet remained hard to move deeply enough in landscape even after
  the size retune. Fixed by adding iPad-only sheet content scroll priority,
  constraining presented iPad sheet content to the same visible form frame,
  bounding the shared Settings container `ScrollView` to the viewport, and
  adding an iPad-landscape two-column Agent settings layout that keeps
  Protected Branches visible near the top. Focused iPad verification passed
  after `xcodegen generate`:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/NotificationSheetPresentationTests -only-testing:TronMobileTests/SettingsPageContainerTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  with 6 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_17-30-58--0700.xcresult`.
  Manual landscape proof used rebuilt bundle `com.tron.mobile.beta`, launch pid
  `866`, and iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`: screenshot
  `/tmp/tron-psg-evidence/ipd7-agent-settings-protected-branches-landscape-final.png`
  shows Protected Branches immediately visible with `main`, `master`,
  `develop`, and the add-field. Server profile truth matched:
  `/Users/moose/.tron/profiles/default/profile.toml:229 protectedBranches = ["main", "master", "develop"]`.
  No new PSG-5 points were awarded at that checkpoint; the remaining IPD-7
  provider/profile/auth, pairing/onboarding, and unavailable-server retry
  evidence was closed by the later Settings/unavailable/onboarding pass below.
- IPD-7 final Settings/unavailable/onboarding pass found and fixed one Server
  page projection gap: when the active paired server was offline, the page
  warned in the summary but hid the `Server Controls` unavailable card because
  both status branches required `!activeServerUnavailable`. The page now uses
  `ConnectionSettingsServerControlsStatus`: no active server renders no fake
  loading card, an offline active server renders explicit unavailable copy, and
  a connected not-yet-loaded active server still renders loading copy. Focused
  iPad verification passed:
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
  labels/metadata. IPD-7 is now `passed_after_fix`.
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
  At that checkpoint, landscape visual proof for that exact retune remained
  open because Simulator still exposed zero AX windows and `Rotate Left` /
  `Rotate Right` menu items were disabled even after Window-menu reselection
  and same-UDID relaunch; deterministic iPad landscape layout guards still
  passed.
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
- Previous user-reviewed sheet retune found the current iPad forms still too wide
  and not tall enough. Fixed only the iPad metrics again: large forms now target
  `min(referenceWidth * 0.50, 580)` by
  `min(referenceHeight * 0.92, 980)`, compact forms target
  `min(referenceWidth * 0.44, 500)` by
  `min(referenceHeight * 0.88, 920)`, and the non-iPad branch keeps existing
  detents/backgrounds. `xcodegen generate` and iPad
  `NotificationSheetPresentationTests` passed 4 XCTest cases; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_19-31-09--0700.xcresult`.
  Computer Use recovered on the same iPad window, bundle
  `com.tron.mobile.beta` relaunched as pid `49779`, and portrait plus landscape
  proof was captured for Agent Control and notification sheets:
  `/tmp/tron-psg-evidence/ipd-sheet-retune-agent-control-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-retune-agent-control-landscape.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-retune-notification-portrait.png`, and
  `/tmp/tron-psg-evidence/ipd-sheet-retune-notification-landscape.png`.
- IPD-5 capability-detail proof opened direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` and tapped completed
  `capability::execute` invocation `call_eiaqjnjn` for the read-only
  `process::run` smoke command. Screenshot
  `/tmp/tron-psg-evidence/ipd5-capability-card-target-before-detail.png` shows
  the target card; `/tmp/tron-psg-evidence/ipd5-capability-detail-popover-ipad.png`
  shows the compact iPad detail popover with request, execution path,
  preparation, child invocation, and stdout `IPD-2 ready.`; and
  `/tmp/tron-psg-evidence/ipd5-capability-detail-metadata-ipad.png` shows the
  read-only audit metadata expansion. DB evidence
  `/tmp/tron-psg-evidence/ipd5-capability-detail-db.json` ties the event pair
  to `call_eiaqjnjn`, and
  `/tmp/tron-psg-evidence/ipd5-capability-detail-invocations.json` records the
  child `process::run` invocation
  `019e84dd-43c9-7141-90f3-a6770547f239` with `exitCode=0`.
- IPD-5 resolved-approval read-only proof opened historical approval session
  `sess_019e7d1d-c3a5-7a50-a947-e005d584ddfa` by deep link. Timeline proof
  `/tmp/tron-psg-evidence/ipd5-existing-approved-chip-landscape.png` shows the
  executed `Approved` chip; detail proof
  `/tmp/tron-psg-evidence/ipd5-approved-readonly-detail-landscape.png` shows
  the read-only approval sheet with `Approved`, `High Risk`, Action, and Reason
  text and no Approve/Deny controls in the accessibility tree. DB evidence
  `/tmp/tron-psg-evidence/ipd5-approved-readonly-detail-db.json` records
  approval `019e7d1e-f523-7fc0-b99c-23966cf64207`, `status=executed`,
  `function_id=process::run`, parent invocation
  `019e7d1e-f44b-79d0-bf8f-d842c44ac3c5`, and the session id; combined UI/DB
  evidence is
  `/tmp/tron-psg-evidence/ipd5-approved-readonly-detail-landscape.json`.
- IPD-8 deep-link proof then covered real session, capability, event, and
  cold-start routes on iPad. DB target evidence
  `/tmp/tron-psg-evidence/ipd8-deeplink-db-targets.json` records direct-branch
  session `sess_019e84d4-8c5b-7ba1-893c-583594bb9087`, capability invocation
  `call_eiaqjnjn`, completed capability event
  `evt_019e84dd-43e6-73f1-b45b-732360da3bff`, and assistant event
  `evt_019e84dd-4a30-7c70-a894-78c8dcf01bdd`. `xcrun simctl openurl` returned
  `openurl_exit=0` for
  `tron://session/sess_019e84d4-8c5b-7ba1-893c-583594bb9087?capability=call_eiaqjnjn`,
  `tron://session/sess_019e84d4-8c5b-7ba1-893c-583594bb9087?event=evt_019e84dd-4a30-7c70-a894-78c8dcf01bdd`,
  and the cold-start session URL after terminating only `com.tron.mobile.beta`.
  Screenshots:
  `/tmp/tron-psg-evidence/ipd8-session-capability-deeplink-ipad.png`,
  `/tmp/tron-psg-evidence/ipd8-session-event-deeplink-ipad.png`, and
  `/tmp/tron-psg-evidence/ipd8-session-cold-start-deeplink-ipad.png`.
- IPD-1/IPD-3 processing and stop proof then sent a deterministic long local
  prompt in direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087`. Screenshot
  `/tmp/tron-psg-evidence/ipd1-sidebar-processing-active.png` shows the iPad
  sidebar visible while the selected row remains present, the chat is in live
  `Thinking`, `Stop agent` is visible, and voice recording is disabled. After
  the run stayed active without a new turn-end DB row, Computer Use clicked
  `Stop agent`; screenshot
  `/tmp/tron-psg-evidence/ipd1-processing-stopped-interrupted.png` shows the
  input back at idle, the sidebar row updated to `6 messages, now`, and the chat
  showing `Session interrupted`. DB evidence
  `/tmp/tron-psg-evidence/ipd1-processing-interrupted-db.json` shows
  `message_count=6`, `event_count=23`, `turn_count=4`, latest
  `message.assistant.turn=4`, `stop_reason=interrupted`, and a
  `notification.interrupted` row.
- IPD-7 model-picker proof opened Agent Control's Model row without changing
  settings. Screenshot `/tmp/tron-psg-evidence/ipd7-model-picker-ollama-ipad.png`
  shows the compact iPad Models sheet with Anthropic, OpenAI, Google, MiniMax,
  Kimi, and Ollama providers; Ollama expanded; `Gemma 4 E4B` selected; and
  `Gemma 4 26B` marked unavailable. Server evidence
  `/tmp/tron-psg-evidence/ipd7-model-picker-db.json` records the latest
  `model::list` invocation and session `latest_model=gemma4:e4b`.
- IPD-7 provider-settings proof opened Settings -> Providers without changing
  credentials. Screenshot `/tmp/tron-psg-evidence/ipd7-providers-settings-ipad.png`
  shows the compact Providers sheet with configured provider summary,
  per-provider status rows, add/clear controls, and Google Cloud fields; the
  accessibility tree also exposed configured Brave Search and Exa services.
  Redacted auth evidence
  `/tmp/tron-psg-evidence/ipd7-provider-auth-redacted.json` records only
  configured provider/service flags and section names, with no secret values or
  token snippets.
- IPD-8 History/fork-control proof opened Agent Control -> History after the
  interrupted turn. Screenshot
  `/tmp/tron-psg-evidence/ipd8-history-sheet-after-interruption-ipad.png` shows
  the compact History sheet with pre-session activity, turns 1-4, the
  interrupted prompt row, and a capability row. Expanding turn 1 exposed detail
  rows and `Fork` controls without invoking them; screenshot
  `/tmp/tron-psg-evidence/ipd8-history-expanded-fork-controls-ipad.png`. DB
  evidence `/tmp/tron-psg-evidence/ipd8-history-fork-controls-db.json` records
  the session/event counts, forkable event samples, and
  `forkControlClicked=false`. Code inspection confirmed
  `HistorySheet.performFork` immediately forks a session, so actual fork
  execution remains action-time confirmation-gated.
- IPD-8 load-earlier pagination proof added deterministic fixture
  `packages/agent/tests/fixtures/ipd8_long_history_pagination.py`, verified it
  with `python3 -m py_compile`, and ran it through canonical `/engine`
  `session::create`, `events::append`, and `session::reconstruct` calls. The
  fixture created session `sess_019e8594-79f2-7a72-b406-fdfc7c44aade` with 240
  message events and 120 turns; evidence
  `/tmp/tron-psg-evidence/ipd8-long-history-pagination.json` records the server
  counters and `hasMoreEvents=true` for the 100-event reconstruction window.
  Manual iPad proof opened the session by URL after terminating only
  `com.tron.mobile.beta`, showed the Load Earlier Messages control around the
  visible turn 97-120 window in
  `/tmp/tron-psg-evidence/ipd8-long-history-load-earlier-before.png`, clicked
  it, and verified the earlier 47-74 window in
  `/tmp/tron-psg-evidence/ipd8-long-history-load-earlier-after.png`. Engine
  ledger evidence
  `/tmp/tron-psg-evidence/ipd8-latest-reconstruct-invocations.json` captures
  the app's initial reconstruct at `2026-06-01T23:46:33Z` and load-earlier
  reconstruct at `2026-06-01T23:46:54Z`. Sidebar navigation proof
  `/tmp/tron-psg-evidence/ipd8-long-history-sidebar-selected.png` shows the
  selected long-history session at the top of the iPad sidebar with
  `240 messages` while the paginated chat remains visible.
- IPD-8 back/sidebar/session-tree proof then used the same iPad Simulator,
  bundle `com.tron.mobile.beta`, and only existing sessions. Screenshots
  `/tmp/tron-psg-evidence/ipd8-back-sidebar-visible-before-toggle.png`,
  `/tmp/tron-psg-evidence/ipd8-back-sidebar-hidden-detail-stable.png`, and
  `/tmp/tron-psg-evidence/ipd8-back-sidebar-restored-selected.png` show sidebar
  hide/restore preserving the selected chat detail. Existing fork-session proof
  `/tmp/tron-psg-evidence/ipd8-existing-fork-row-selected.png` shows the
  selected `IPD-1 visible fork card 20260601205310` row and stable detail view.
  DB evidence `/tmp/tron-psg-evidence/ipd8-existing-fork-session-db.json`
  records forked session `sess_019e84f6-3d48-75c3-8df2-aca65b38a123`, parent
  session `sess_019e84f6-3d29-7071-9874-714a0b34e102`, root fork event
  `evt_019e84f6-3d48-75c3-8df2-acbf25c331ba`, parent event
  `evt_019e84f6-3d31-7760-a400-a611c658bb43`, and the
  `sourceSessionId`/`sourceEventId` payload. Actual fork execution remains
  action-time confirmation-gated because invoking `Fork` creates a session.
- IPD-9 keyboard-focus proof used the recovered iPad Simulator window with the
  split dashboard visible and direct-branch session
  `sess_019e84d4-8c5b-7ba1-893c-583594bb9087` selected. Screenshot
  `/tmp/tron-psg-evidence/ipd9-keyboard-focus-input-ipad.png` shows the
  message input focused with the caret visible; accessibility evidence
  `/tmp/tron-psg-evidence/ipd9-keyboard-focus-accessibility.txt` records the
  focused `Message input` element. A follow-up `Tab` while editing the
  multiline input inserted a tab character into the draft instead of advancing
  focus. The draft was cleared, no message was sent, and the failure was
  classified as a prompt-composer bug.
- IPD-9 prompt-keyboard follow-up added
  `packages/ios-app/Tests/Views/InputBarKeyboardTraversalTests.swift` and
  changed `InputBar` so iPad hardware Tab resigns prompt focus instead of
  inserting hidden draft text. The new source guard failed before the fix in
  xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-00-15--0700.xcresult`,
  then passed after the fix with existing composer coverage:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/InputBarKeyboardTraversalTests -only-testing:TronMobileTests/InputBarContentAreaChipTests`
  passed 8 XCTest cases plus 1 Swift Testing check; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-03-11--0700.xcresult`.
  Manual Computer Use proof on the same iPad Pro 13-inch (M5) UDID, bundle
  `com.tron.mobile.beta`, verified the existing direct-branch session's
  `Message input` in portrait and landscape: pressing `Tab` left `Type here`
  visible, no accessibility draft value appeared, and no prompt was sent.
  Screenshots:
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-no-draft-mutation-fixed-portrait.png`
  and
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-no-draft-mutation-fixed-landscape.png`.
  IPD-9 still remains open for pointer QA and broader control-to-control
  hardware-keyboard traversal.
- IPD-9 landscape sheet/appearance proof then verified the retuned iPad sheet
  containers in dark landscape, Settings/Server/Agent at
  `accessibility-extra-extra-extra-large`, and temporary Light mode through the
  app's own Color Mode setting before restoring Dark plus Simulator
  `content_size large`/`appearance dark`. Screenshots:
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-sidebar-baseline.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-settings-sheet.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-settings-sheet-accessibility-xxxl.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-server-accessibility-xxxl.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-dark-agent-accessibility-xxxl.png`,
  `/tmp/tron-psg-evidence/ipd9-landscape-light-app-settings-accessibility-xxxl.png`,
  and `/tmp/tron-psg-evidence/ipd9-agent-tab-focus-add-branch.png`. Providers
  was visually inspected but not captured because the live view includes
  credential labels/snippets. IPD-9 remains open because pointer QA and broader
  control-to-control keyboard traversal are not complete.
- IPD-1 relaunch preload proof terminated and relaunched `com.tron.mobile.beta`
  on the same iPad UDID; relaunch returned PID `14768` while dev takeover stayed
  healthy on PID `79934`. Screenshot
  `/tmp/tron-psg-evidence/ipd1-sidebar-preload-after-relaunch.png` and the
  accessibility tree showed the sidebar preloaded with session rows, workspace
  filters, and per-row `Archive` secondary actions immediately after launch.
  Archive execution remains action-time confirmation gated.
- IPD-3 voice-note deterministic proof passed on the iPad target:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,id=E2A39D89-9AF3-431E-A43B-0030C3716482' -only-testing:TronMobileTests/AccessibilityTests -only-testing:TronMobileTests/VoiceNotesRecorderTests -only-testing:TronMobileTests/AudioAvailabilityMonitorTests -only-testing:TronMobileTests/AudioCaptureEngineTests -only-testing:TronMobileTests/MediaClientTests`
  with 39 XCTest cases plus 9 Swift Testing checks; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_18-32-53--0700.xcresult`.
  Coverage includes floating voice-note accessibility copy, audio availability,
  simulator-safe capture start/stop/prewarm/cancel, voice-note recorder states,
  and `voice_notes::save`/`transcription::audio` payload contracts. Manual
  Voice Note sheet opening/record/cancel/submit remains open because Computer
  Use lost the Simulator window with `cgWindowNotFound`; normal quit,
  `killall Simulator`, same-UDID reopen, same-UDID shutdown/boot, Window-menu
  selection, and File -> Open Simulator selection still left Simulator without
  AX-visible windows even though CoreGraphics reported an onscreen window and
  simctl screenshots worked. Evidence:
  `/tmp/tron-psg-evidence/ipd-computer-use-window-recovery-simctl-visible.png`.
  The microphone path was not driven by blind coordinate clicks.
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
  source-control mutations, conflict resolution, and fork execution rather than
  DTO/state-machine/back/session-tree coverage.
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
- 2026-06-01 iPad sheet standardization checkpoint found the remaining sheet
  inconsistency was structural rather than another one-off metric retune:
  app-level and feature sheets still mixed raw `.presentationDetents(...)`,
  duplicate outer wrappers, and fixed iPad heights that made short read-only
  details look over-expanded. Fixed by making `adaptivePresentationDetents` the
  canonical helper for app sources, adding content-aware large/compact iPad
  target sizes, adding explicit phone-preserving sizing/background modes for
  converted raw-detent callers, and moving approval, user-interaction,
  subagent, compaction, memory-retain, provider-error, onboarding, camera, QR,
  clone, process-list, and stream sheets onto the shared helper. Source-level
  TDD guard `TronMobileTests/IPadSheetPresentationTests` first failed against
  the mixed raw-detent source set, then passed after the conversions; `rg -n
  "\\.presentationDetents\\(" packages/ios-app/Sources` now reports only the
  shared helper in `Sources/Extensions/View+Extensions.swift`. Focused iPad
  tests passed 12 XCTest cases on iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482` after `xcodegen generate`: targeted
  classes were `IPadSheetPresentationTests`,
  `NotificationSheetPresentationTests`, `SettingsPageContainerTests`, and
  `AgentSettingsPageLayoutTests`; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-44-10--0700.xcresult`.
  Rebuilt beta app proof used bundle `com.tron.mobile.beta`; build/install
  succeeded and launch returned pid `92610`. Non-mutating Computer Use proof
  captured the previously over-expanded resolved approval sheet before the
  change at `/tmp/tron-psg-evidence/ipd-current-open-approved-sheet-baseline.png`,
  then the standardized read-only approval detail in landscape/portrait at
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-approved-readonly-landscape.png`
  and
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-approved-readonly-portrait.png`.
  Additional standardized sheet proof covers Settings main/server, Agent
  Control, Context, Source Control, Analytics, History, and notification
  portrait/landscape screenshots:
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-settings-main-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-settings-server-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-agent-control-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-context-detail-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-source-control-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-analytics-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-history-portrait.png`,
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-notification-portrait-normalized.png`,
  and
  `/tmp/tron-psg-evidence/ipd-sheet-standardized-notification-landscape-normalized.png`.
  No approval, source-control, fork, reset, archive, send, or remote-mutating UI
  action was invoked during this checkpoint. PSG-5 remains running because
  action-time approval decisions, source-control mutations, fork execution,
  voice-note sheet submission states, pointer QA, and broader keyboard traversal
  remain open.
- 2026-06-01 IPD-9 Agent protected-branch keyboard follow-up fixed the
  previously documented Agent settings subcase where Tab focused the
  protected-branch text field but did not visibly advance out of it. Added
  source-level TDD guard
  `packages/ios-app/Tests/Views/Settings/AgentSettingsKeyboardTraversalTests.swift`;
  the initial focused run failed against the existing source in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-51-16--0700.xcresult`.
  `AgentSettingsPage` now binds the protected-branch field to local focus state
  and handles iPad hardware Tab by resigning first responder instead of
  submitting `addProtected`. Focused verification passed on the same iPad UDID:
  `AgentSettingsKeyboardTraversalTests` alone passed in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-52-14--0700.xcresult`,
  then the broader iPad keyboard/settings run passed 4 XCTest cases plus 12
  Swift Testing checks across `AgentSettingsKeyboardTraversalTests`,
  `InputBarKeyboardTraversalTests`, `AgentSettingsPageLayoutTests`, and
  `AgentContextSettingsPageTests`; xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_20-52-50--0700.xcresult`.
  Manual non-mutating proof used rebuilt bundle `com.tron.mobile.beta`, launch
  pid `20213`, typed draft-only value `ipd9-tab-no-submit` in the Agent
  protected-branch field, pressed Tab, and did not click Add. Screenshots:
  `/tmp/tron-psg-evidence/ipd9-agent-keyboard-protected-branch-before-tab.png`,
  `/tmp/tron-psg-evidence/ipd9-agent-keyboard-protected-branch-draft-before-tab.png`,
  and
  `/tmp/tron-psg-evidence/ipd9-agent-keyboard-protected-branch-after-tab-no-submit.png`.
  DB evidence
  `/tmp/tron-psg-evidence/ipd9-agent-keyboard-tab-settings-invocations.json`
  shows only `settings::get` in the proof window and no `settings::update`, so
  the draft did not mutate protected-branch settings. IPD-9 remains open for
  pointer QA and broader keyboard traversal beyond the prompt/protected-branch
  text fields.
- 2026-06-01 IPD-9 Agent Control card accessibility follow-up found a real
  broader keyboard/pointer gap: Agent Control summary cards were interactive via
  `onTapGesture`, but the live iPad accessibility tree exposed the rows as text
  instead of buttons, so hardware-keyboard traversal had no semantic row targets.
  Added source-level TDD guard
  `packages/ios-app/Tests/Views/AgentControlCardAccessibilityTests.swift`; the
  initial focused run failed with 5 issues in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_21-08-25--0700.xcresult`.
  `AgentControlCards.CardChrome` now wraps tappable cards in plain semantic
  `Button` controls, combines their accessibility children, keeps the
  interactive glass shape, and adds hover highlighting. The focused guard passed
  after the fix in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_21-09-16--0700.xcresult`.
  Manual non-mutating proof rebuilt and launched `com.tron.mobile.beta` as pid
  `51618` on iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482` with Simulator pointer and keyboard
  capture enabled. Screenshots captured dashboard pointer/keyboard baseline,
  session selection, composer focus/no-draft Tab behavior, sidebar/floating
  pointer hovers, and post-fix Agent Control card button rendering:
  `/tmp/tron-psg-evidence/ipd9-pointer-keyboard-capture-dashboard-baseline.png`,
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-dashboard-selected-session.png`,
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-message-input-focused-capture.png`,
  `/tmp/tron-psg-evidence/ipd9-keyboard-tab-message-input-resigned-no-draft.png`,
  `/tmp/tron-psg-evidence/ipd9-pointer-hover-sidebar-row.png`,
  `/tmp/tron-psg-evidence/ipd9-pointer-hover-floating-new-session.png`, and
  `/tmp/tron-psg-evidence/ipd9-agent-control-card-buttons-accessibility-fixed.png`.
  The post-fix Computer Use tree exposed `Context`, `Model`, `Source Control`,
  `Analytics`, and `History` as buttons with combined labels. No approval,
  source-control, fork, reset, archive, send, voice-record, or git mutation was
  invoked. IPD-9 remains running for broader traversal/pointer coverage outside
  this Agent Control card fix.
- 2026-06-01 IPD-5 generated-UI read-only proof used iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`, bundle `com.tron.mobile.beta`, with
  Engine Console opened to Substrate. Screenshot
  `/tmp/tron-psg-evidence/ipd5-engine-console-generated-surfaces-empty-ipad.png`
  shows the read-only `Generated Surfaces` card with no actionable live rows in
  the current control projection. Direct DB/API evidence
  `/tmp/tron-psg-evidence/ipd5-generated-ui-readonly-existing-surfaces.json`
  inspected four active fixed-catalog `ui_surface` resources and validated them
  through successful read-only `ui::inspect_surface`/`ui::validate_surface`
  invocations
  `019e86aa-c6c1-7182-800e-3b913f082acd`,
  `019e86aa-c6c4-7210-84e6-15d31d7b0f3c`,
  `019e86aa-c6c5-7180-9cc6-aed1e9d957bf`,
  `019e86aa-c6c8-7dc3-bdf2-5e923065abff`,
  `019e86aa-c6c9-7891-9376-570e2bd929b3`,
  `019e86aa-c6cb-7960-9d14-88a3abc36f59`,
  `019e86aa-c6cd-7ec3-8f6b-6c8147884b27`, and
  `019e86aa-c6cf-7a51-843e-06d4f372e580`. The stored actions target
  `resource::create`; validation returned `unauthorized` with `grant_mismatch`,
  so the proof covers read-only inspect/validate behavior without invoking
  `ui::submit_action`, `ui::refresh_surface`, or any approval decision.
- 2026-06-01 IPD-9 Engine Console accessibility follow-up found and fixed a
  remaining broader pointer/keyboard affordance gap outside Agent Control:
  Engine Console section and suggestion chips were semantic buttons but lacked
  explicit hover content shapes, hover highlighting, and combined accessibility
  treatment, and toolbar icon controls needed source-guarded labels/values.
  Added
  `packages/ios-app/Tests/Views/EngineConsoleAccessibilityTests.swift`; the
  initial guard failed before the fix in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_21-58-58--0700.xcresult`.
  The corrected focused guard passed after the final fix and post-rename rerun
  in xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-13-18--0700.xcresult`.
  `EngineConsoleSectionChips` and `EngineConsoleSuggestionChips` now use plain
  buttons with interaction/hover content shapes, `.hoverEffect(.highlight)`,
  and combined labels; `DashboardToolbarContent` uses icon-only `Label`
  controls for sidebar/navigation/settings with explicit labels/hover effects;
  `NotificationBellButton` hides the visual badge from duplicate reading and
  exposes a notification count value. Manual final-build proof installed and
  launched `com.tron.mobile.beta` pid `20615` on iPad Pro 13-inch (M5)
  `E2A39D89-9AF3-431E-A43B-0030C3716482`; evidence lives at
  `/tmp/tron-psg-evidence/ipd9-engine-console-accessibility-fixed.txt`,
  `/tmp/tron-psg-evidence/ipd9-engine-console-overview-chip-buttons-fixed.png`,
  and
  `/tmp/tron-psg-evidence/ipd9-engine-console-capability-suggestion-buttons-fixed.png`.
  Computer Use exposed toolbar overflow `Navigation`/`Settings`, navigation
  rows `Sessions`/`Engine`, Engine Console section chips, and Capabilities
  suggestion chips as buttons. No capability submit, approval, generated UI
  submit/refresh, source-control action, fork, archive, delete, reset, send,
  voice-record, or git mutation was invoked.

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
  ordinals, and photo plus document attachment add/remove now have live iPad
  proof.
  Settings grid, archive-action discoverability, and light/Dynamic-Type visual
  QA now have partial evidence too. IPD-4 notification list/detail/read/read-all,
  delivery-failure/badge-clearing, deep-link, and iPad compact-sheet paths now
  have live iPad proof and focused regression coverage; IPD-8 session,
  capability, event, and cold-start deep-link paths have live iPad proof; IPD-1
  processing and IPD-3 Stop Agent/interruption paths have live proof; IPD-5
  completed-capability detail popover, metadata expansion, and resolved
  approval read-only details have live iPad proof; IPD-7 model-picker,
  provider-settings, and provider list rendering have live iPad proof; IPD-8
  History and fork controls have live iPad proof without invoking fork
  execution; IPD-8 load-earlier pagination, sidebar
  selection, back/sidebar toggle, and existing fork lineage now have live iPad
  proof; IPD-5 generated-UI read-only inspect/validate has live DB/API and iPad
  Engine Console proof without invoking submit/refresh; IPD-9 input focus,
  prompt Tab no-draft behavior, and Agent
  protected-branch Tab no-submit behavior have live proof, with pointer and
  broader keyboard traversal still open. The canonical iPad sheet
  standardization guard now also requires every adaptive sheet call site in app
  sources to declare its `ipadSizing` preset explicitly; it first failed on 25
  implicit-preset offenders in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-18-19--0700.xcresult`,
  then passed 8 focused sheet XCTest cases across `IPadSheetPresentationTests`
  and `NotificationSheetPresentationTests` after explicit
  `ipadSizing: .largeForm` classification was added without changing compact or
  phone-preserving call sites:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-20-41--0700.xcresult`.
  The same guard now centralizes raw `.presentationBackground(...)` styling in
  `View+Extensions.swift`: it first failed on `ModelPickerSheet` and
  `GlassActionSheet` in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-24-30--0700.xcresult`,
  then passed 9 focused sheet XCTest cases across `IPadSheetPresentationTests`
  and `NotificationSheetPresentationTests` after
  `glassPopoverPresentationBackground()` replaced those raw popover-background
  call sites:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-26-53--0700.xcresult`.
  The guard now also centralizes raw `.presentationDragIndicator(...)` styling
  in the adaptive helper: it first failed because the helper lacked a
  `dragIndicator` default and 38 app source files still called raw
  `.presentationDragIndicator(.hidden)` in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-31-05--0700.xcresult`,
  then passed 10 focused XCTest cases across `IPadSheetPresentationTests` and
  `NotificationSheetPresentationTests` after
  `dragIndicator: Visibility = .hidden` was applied on both iPad sizing branches
  and the iPhone detent branch, the raw app-source call sites were removed, and
  the notification source guard was aligned to the helper shape:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-34-29--0700.xcresult`.
  Suite-level `SourceGuardTests` also passed 14 Swift Testing checks after the
  stale Engine Console source guard was updated:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-35-00--0700.xcresult`.
  The same presentation guard now centralizes compact-width popover adaptation:
  it first failed because the helper did not exist and raw
  `.presentationCompactAdaptation(.popover)` remained in `ModelPickerSheet`,
  `AgentControlView`, `ContextDetailView`, `RepoSessionsSubSheet`, and
  `FileDetailSheet` in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-38-55--0700.xcresult`,
  then passed 11 focused XCTest cases across `IPadSheetPresentationTests` and
  `NotificationSheetPresentationTests` after `popoverCompactAdaptation()`
  replaced those six raw call sites:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-41-13--0700.xcresult`.
  Follow-up reusable-sheet ownership audit then found `ProcessListSheet` and
  `SubagentResultsListSheet` depended on their presenters to apply adaptive
  iPad sizing. The expanded `IPadSheetPresentationTests` guard first failed on
  those two sheet views in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-47-13--0700.xcresult`,
  then passed after both reusable sheet bodies owned the helper directly and
  the duplicate presenter-side modifiers were removed:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-48-59--0700.xcresult`.
  A scoped reusable-sheet guard then caught the same presenter-owned sizing
  pattern in `CapabilityInspectionSheet` and private `AddPluginSourceSheet`:
  red xcresult
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-53-06--0700.xcresult`.
  Moving those helpers into the sheet bodies passed 8 focused
  `IPadSheetPresentationTests` cases in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-55-02--0700.xcresult`,
  and the updated Engine Console source guard passed 14 Swift Testing checks in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_22-54-23--0700.xcresult`.
  A further container-routed detail-sheet audit then caught `SourceControlSheet`
  wrapping `FileDetailSheet` with duplicate presenter-side adaptive sizing even
  though `FileDetailSheet` already routes through
  `CapabilityDetailSheetContainer`. The focused guard first failed in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_23-00-44--0700.xcresult`,
  then passed 9 `IPadSheetPresentationTests` cases after the duplicate wrapper
  was removed while the reusable container retained ownership:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_23-01-14--0700.xcresult`.
  Final combined sheet regression coverage passed 13 XCTest cases across
  `IPadSheetPresentationTests` and `NotificationSheetPresentationTests`:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_23-02-24--0700.xcresult`.
  The broader duplicate-wrapper audit then found `SettingsView` wrapping
  reusable `LogViewer` with a second adaptive helper even though `LogViewer`
  owns its own medium/large large-form sizing. The focused guard first failed
  in
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_23-05-08--0700.xcresult`,
  then passed 10 `IPadSheetPresentationTests` cases after the presenter-side
  wrapper was removed:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_23-05-43--0700.xcresult`.
  Final combined sheet regression coverage passed 14 XCTest cases across
  `IPadSheetPresentationTests` and `NotificationSheetPresentationTests`:
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.01_23-07-11--0700.xcresult`.
  Remaining IPD rows must still close or be explicitly successor-owned before
  final PSG-5 points.
- Checkpoint 5: PSG-6/PSG-7 final cleanup, broad gates, ledger, final commit.
