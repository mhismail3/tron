# Post-Scorecard Gap Hardening Scorecard

Created: 2026-06-01

Initial score: **0/100**

Current score: **10/100**

Status: **active; PSG-0 complete, PSG-1 token accounting audit next**

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
| PSG-1 | Token accounting regression audit | 15 | pending | Verify canonical `TokenRecord`, unavailable pricing, cache buckets, segment/reset semantics, DB/session counters, and iOS display. | None yet. |
| PSG-2 | Configured provider canaries | 10 | pending | Run deterministic fixtures first, then small canaries only for configured Anthropic, OpenAI, Google, MiniMax, Kimi, and Ollama lanes. | None yet. |
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
  docs/static gates updated, scorecard invariant passed, commit pending.
- Checkpoint 2: PSG-1/PSG-2 token/provider audit complete, commit.
- Checkpoint 3: PSG-3/PSG-4 Agent Control and Source Control audit complete,
  commit.
- Checkpoint 4: PSG-5 iPad scorecard complete or explicitly successor-owned
  residuals recorded, commit.
- Checkpoint 5: PSG-6/PSG-7 final cleanup, broad gates, ledger, final commit.
