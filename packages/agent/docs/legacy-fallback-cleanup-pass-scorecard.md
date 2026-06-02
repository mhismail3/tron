# Legacy/Fallback Cleanup Pass Scorecard

Created: 2026-06-02

Initial score: **0/100**

Current score: **100/100**

Status: **completed**

Scope:
- Quick post-closeout static pass for legacy, fallback, dead-code, and
  backward-compatibility residue across agent, iOS, Mac, and script surfaces.
- High-signal documentation cleanup where naming/comments implied fallback or
  compatibility behavior that was not actually present.
- Large-file and test-split ownership verification through the cleanup
  scorecard's large-file budget gate.

Out of scope:
- Semantic rewrites of budgeted large test matrices that already have owner,
  reason, and budget rows in `codebase-cleanup-scorecard.md`.
- Product behavior changes, provider model catalog policy, pairing protocol
  changes, and active iPad action-time flows owned by
  `ipad-action-time-followup-scorecard.md`.

## Summary

This pass treats absence of legacy/fallback/compatibility residue as a static
architecture invariant, not a style preference. Server truth remains owned by
engine/domain/resource primitives; iOS and Mac remain thin projections; scripts
remain explicit workflow surfaces. Current protocol facts such as incompatible
server errors, provider API names, terminal `dead_lettered` queue states, and
retired-provider model metadata are not compatibility shims.

## Primitive And Plane Budget

- Durable truth stays in resources, invocations, approvals, queues, events,
  grants, and domain-owned contracts.
- Client code may render server facts and submit server-authored actions, but it
  must not own fallback policy, compatibility aliases, or alternate durable
  state.
- Large tests may stay large only when the cleanup scorecard records exact LOC,
  owner, reason, budget, and decomposition checkpoint; unowned growth fails the
  dedicated large-file invariant.
- Comments and identifiers must not call current display mappings "fallback" or
  "bridge" when they are not compatibility paths.

## Scenario Ledger

| ID | Area | Weight | Status | Owner | Evidence | Residual risk | Checkpoint |
|----|------|--------|--------|-------|----------|---------------|------------|
| LFC-0 | Scorecard formalization | 10 | passed_after_fix | docs_or_scorecard | Added this scorecard, linked it from the README living-doc map, and added `legacy_fallback_cleanup_pass_stays_formalized` to the static gates. | None. | this checkpoint |
| LFC-1 | Production legacy/fallback scan | 25 | passed_after_fix | docs_or_scorecard | Static scan initially exposed current iOS model-list wire keys `isLegacy`/`isDeprecated` and a Mac permission-step placeholder icon named with fallback wording. The model-list keys are now explicit current-boundary allowlist entries, the Mac icon was renamed to `tronShortcutPlaceholderAppIcon`, and `rg -ni "legacy|fallback|compatibility|back-compat|back compat|backward compatibility|backwards compatibility|deprecated|obsolete|remove later|temporary workaround|old server|older server" packages/ios-app/Sources packages/mac-app/Sources scripts -g '!*.svg'` now reports only the two allowlisted iOS model DTO keys. | Exact word scans cannot prove semantic absence; paired with static gates and architecture invariants. | this checkpoint |
| LFC-2 | Client/script static gate | 20 | passed_after_fix | test_harness | `packages/agent/tests/threat_model_invariants.rs` now scans iOS/Mac production Swift plus script sources for unowned legacy/fallback/compatibility debt markers, requires this scorecard to close consistently, and allowlists only the current iOS model-list wire keys `isLegacy` and `isDeprecated` for retired-model metadata. | Current allowed protocol words such as `incompatible` stay outside the debt-word set. | this checkpoint |
| LFC-3 | Large-file/test split audit | 20 | passed_after_fix | test_harness | First `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture` failed because `codebase-cleanup-scorecard.md` recorded stale LOC for `worktree/.../coordinator/tests.rs`. Updated the exact large-file table, including `threat_model_invariants.rs` at 7,444 LOC after the new gate, and reran the same command successfully. | Budgeted large test matrices remain explicit maintenance exceptions with owner, reason, budget, and checkpoint rows. | this checkpoint |
| LFC-4 | High-signal docs and naming | 15 | passed_after_fix | client_projection | Renamed misleading iOS `fallbackActionId`, `fallbackLabel`, `fallbackUnknownDefaultModel`, and bridge comments to submitted/component/selection/mapping language; Pairing URL label docs now describe the current field without compatibility wording; Mac Screen Recording shortcut icon naming now says placeholder instead of fallback. | None. | this checkpoint |
| LFC-5 | Closeout verification | 10 | passed | docs_or_scorecard | `xcodegen generate` passed for iOS and Mac. Targeted iOS `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/GeneratedUIRendererTests -only-testing:TronMobileTests/NewSessionFlowTests -only-testing:TronMobileTests/PairingURLParserTests -only-testing:TronMobileTests/PairingProbeTests -only-testing:TronMobileTests/EngineConsoleStateTests` passed with 22 XCTest cases plus Swift Testing suites reported as a 59-test run. Full Mac `xcodebuild test -scheme TronMac -destination 'platform=macOS'` passed with 291 Swift Testing tests. Final Rust checks passed: `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`, `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture`, and `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture` with 68 tests. | No runtime/UI smoke required because this pass does not change behavior. | this checkpoint |

## Evidence Contract

- `rg` absence scans must cover production Rust, Swift, and scripts with
  documented no-match exits.
- `cargo test --manifest-path packages/agent/Cargo.toml --test large_file_budget_invariants -- --nocapture`
  must pass after LOC/table updates.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants legacy_fallback_cleanup_pass_stays_formalized -- --nocapture`
  must pass for this scorecard and the client/script static gate.
- Formatting and `git diff --check` must pass before closeout.

## Static Gates

- This scorecard must stay linked from the README living-doc map.
- The scorecard must close at **100/100** only when every LFC row is
  `passed` or `passed_after_fix`.
- iOS/Mac production sources and scripts must stay free of unowned
  legacy/fallback/compatibility debt terms.
- Large files over 1,000 LOC must stay exactly represented in
  `codebase-cleanup-scorecard.md`.

## Next Test

The pass is closed. Future changes that introduce new client/script fallback or
compatibility debt markers must remove them or add an explicit current-boundary
owner before the static gates can pass.
