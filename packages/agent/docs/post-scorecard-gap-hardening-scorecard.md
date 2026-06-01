# Post-Scorecard Gap Hardening Scorecard

Created: 2026-06-01

Initial score: **0/100**

Current score: **35/100**

Status: **active; PSG-1/PSG-2 complete, PSG-3 Agent Control fast-load audit next**

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
| PSG-1 | Token accounting regression audit | 15 | passed | 2026-06-01 provider-doc audit rechecked primary docs: OpenAI Responses usage keeps `input_tokens`, `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`, and `total_tokens`; Anthropic usage keeps cache read/write plus `cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`; Google `UsageMetadata` keeps prompt/cached/candidate/tool-use/thought/total and modality detail fields; MiniMax Anthropic-compatible cache docs keep `cache_creation_input_tokens`, `cache_read_input_tokens`, and explicit M2 pricing; Kimi chat docs keep `usage.cached_tokens`, and thinking docs confirm `reasoning_content` consumes tokens; Ollama docs keep `prompt_eval_count` and `eval_count`. Local audit confirmed `domains/model/providers/tokens` owns canonical `TokenRecord`, server pricing returns explicit unavailable states, iOS DTOs consume server token records, and scanned token/UI paths did not restore local pricing or missing-turn defaults. Deterministic evidence: `cargo test --manifest-path packages/agent/Cargo.toml tokens --lib -- --nocapture` passed 205 tests; provider filters passed Anthropic 214, OpenAI 246, Google 145, MiniMax 64, Kimi 93, Ollama 106 tests; iPhone-targeted iOS token/projection tests passed 125 XCTest cases plus 30 Swift Testing cases. | Provider docs can drift; rerun primary-doc audit before future pricing/cache semantic changes. |
| PSG-2 | Configured provider canaries | 10 | passed | Current configured canaries passed without secret output. Hosted isolated ROC-2 run `/tmp/roc2_hosted_model_matrix_20260601130028.json` passed Anthropic `claude-sonnet-4-6` (`sess_019e84c6-1156-7df3-9654-bb8d9a529390`), OpenAI `gpt-5.5` (`sess_019e84c6-5818-7dd3-91ba-def3a8bf2571`), and Google `gemini-3.1-pro-preview` (`sess_019e84c6-836a-79e1-a8fa-76f37dfb83c9`) with two successful execute children each, zero failed invocations, zero approvals, zero compactions, zero error/fatal logs, and provider event rows. MiniMax isolated ROC-2 run `/tmp/roc2_hosted_model_matrix_20260601130236.json` passed `MiniMax-M2.7` (`sess_019e84c7-fb95-7bc1-803c-d440d7e8de04`) with the same DB invariants. Ollama isolated ROC-3 run `/tmp/roc3_local_model_breadth_20260601130137.json` passed `gemma4:e4b`; unavailable larger local lane `gemma4:26b` was cataloged as not installed. New no-tool token canary fixture `packages/agent/tests/fixtures/psg_token_provider_canary.py` passed Kimi `kimi-k2.5` in `/tmp/psg_token_provider_canary_20260601130757.json`: session `sess_019e84cc-e0f2-77f1-9af4-47dbe88734e0`, two token-record events, one unique turn record, provider `kimi`, input `14747`, output `514`, total `15261`, priced cost `$0.0103902`, session counters equal canonical record, zero failed invocations, zero `capability::execute`, zero compactions, zero error/fatal logs. Prior TAH cache-hit evidence remains linked for Anthropic, Google, and Kimi cache-read/write behavior. | No PSG-2 blocker. Kimi execute materialization caveat remains non-accounting follow-up from TAH-6, not a token canary failure. |
| PSG-3 | Agent Control fast-load audit | 15 | pending | Verify local-first Context/Model/Source Control/Analytics/History, row-level loading states, and debug timing logs. | None yet. |
| PSG-4 | Source Control direct-branch/worktree workflows | 15 | pending | Verify direct branch, isolated worktree, clean/dirty/non-git, drill-down diff, commit/push/pull/rebase/merge gating. | None yet. |
| PSG-5 | iPad UI regression execution | 20 | pending | Run `post-100-ipad-ui-regression-scorecard.md` IPD-0 through IPD-10 on iPad Simulator with DB/UI evidence. | None yet. |
| PSG-6 | Overlooked cleanup scan | 5 | pending | Scan touched token, worktree, Agent Control, event sync, and UI modules for new dead/fallback/legacy/compatibility code. | None yet. |
| PSG-7 | Closeout | 10 | pending | Final docs, README, static gates, focused and broad tests, ledger, diff hygiene, and final commit. | None yet. |

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
- Checkpoint 3: PSG-3/PSG-4 Agent Control and Source Control audit complete,
  commit.
- Checkpoint 4: PSG-5 iPad scorecard complete or explicitly successor-owned
  residuals recorded, commit.
- Checkpoint 5: PSG-6/PSG-7 final cleanup, broad gates, ledger, final commit.
