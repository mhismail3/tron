# North Star slice 7: tooling diet and prune-tests list (proposal, #2592)

Proposal for Mohsin's approval. Nothing here is deleted yet, and this branch is not meant to land. Each approved row
becomes its own change with its own proof, and this file is deleted when slice 7 closes.

**Source.** origin/main `2c3a03a0e`. Source reading and git history only: no suite was run. Six read-only subagents
inventoried one area each. I re-read the source behind every row marked *verified*.

**Seconds.** Per-case mean from the test ledger `~/.tron-maintenance/test-ledger/results.sqlite3`, runs since
2026-11-12. Gateway and Python rows come from the mini (`server-desktop`) and this Mac; iOS rows come from simulator runs.
A row that only drops assertions inside a kept test saves 0 s.

**Rules applied.** Global AGENTS.md Tests: prefer E2E, drop tests that duplicate it or test the implementation, keep
precise UI regression tests. DECISIONS (2026-11-17): drop tests that only prove removed code is gone, that change with
every edit, or that cannot fail. Anything uncertain is marked keep. No golden, timeout or tolerance is touched.

## Summary

| Group | Candidates | Seconds saved per full run | Needs from Mohsin |
|---|---|---|---|
| A. Tooling diet, now (X5, X6 pool) | 3 | 38.1, plus the pool's mini probe (up to 30 s) on every `verify` | D1, D2, D3 |
| B. `verify --batch` (X4) | 1 (64 cases, 2,926 code lines) | 251.0 | D4 |
| C. iOS scroll-performance UI tests (X3) | 2 | 628.6 | D5 |
| D. Gateway duplicate and absence-only tests | 9 | 2.2 | list approval |
| E. Tooling tests: structure locks, absence-only, duplicate runs | 7 | 27.2 | list approval |
| F. iOS ViewTests and policy scripts | 5 | 2.9 | list approval |
| **Total now** | **27** | **≈ 950 s** (Python lane ≈ 316 s of it) | |
| G. Later, slice 12 (X7) | 2 (not for approval now) | ≈ 68 | — |

The Python lane's last full run on the mini (`419650462`) summed to 1,748 s of test time. Groups A and B together remove
289 s of it (16.5%), and E removes 27 s more. The rest of the lane is `test-ios-test-infrastructure.py` (501 s, X7,
slice 12), real-boundary tests (`test-tron-profile.py`, `test-tron-mac-replace.py`, `test-home-layout.py`) and the
proof gates, which this list keeps.

## A. Tooling diet, now (X5, X6 pool), ranked by payoff

| # | Path | What it catches today | Evidence | s/run | Recommendation |
|---|---|---|---|---|---|
| A1 | `tools/verify/hunt.py` (160 lines); `verify.py` 1302–1304, 1311; `scripts/tron` 96–98; README §Repeat-suite hunt (239–263); `tests/test-verify.py::HuntTests` (4 cases, 599–841) | Regressions in a post-landing flake-hunting mode. No caller, and it has never written output: no `test-results/hunt/` exists in any of the 40 worktrees | *verified*: grep finds only usage text and docs | 32.4 | **delete** (X5) |
| A2 | Test-host pool: `mini.py` `outside_paths`/`choose_host`/`pool_main` (109–155), `remote_status` (298–311), `status`/`pool` arms (568–574); `test-mini.py` 508–563 (2 cases); `test-verify.py` 294–321 (1 case) | Routes Gateway and Python lanes to the mini "when idle". Every `verify` that selects them SSH-probes the mini first (`verify.py` 1416–1417, 30 s timeout) | *verified* | 5.7, plus the probe on every verify | **delete after D2**: flip the default `--gateway-host pool` to `local` in `verify` and `scripts/tron test gateway` (X6) |
| A3 | Contended mark: `ledger.py` 48, 56, 96, 288; `mini.py` 222, 477; `hunt.py` 62; asserts in `test-verify.py` 723–729, 1025–1027 and `test-mini.py` 287; `docs/PRINCIPLES.md` 99–101; README 202–207 | Excludes runs marked `TRON_TEST_CONTENDED=1` from flake ranking. **0 of 85,594 ledger rows were ever marked** | *verified*: `select contended, count(*)` | 0 | **delete** the env plumbing and filter. Drop the column through a one-shot backed-up migration of the ledger. This is maintenance data, not `~/.tron` (D3) |
| A4 | `scripts/tron flakes` (`ledger.py` 283–311) and its asserts in `test-verify.py` 1014–1018, 1028–1029 | Same-tree pass/fail ranking. `docs/PRINCIPLES.md` P6 tells workers to use it, and its replacement (`verify repeat`, `verify stats`) does not exist yet | *verified*: grep finds no `repeat` or `stats` command | 0 | **keep** until slice 6 ships `verify repeat` (D1) |
| A5 | Whole-verifier transport (`mini.py verify`) and `test-mini.py::…test_whole_verifier…` (19.0 s) | The landing gate: `land.py:56` runs the exact merge through it | *verified* | — | **keep**. DESIGN X6 named it for deletion, but slice 5 made it `land`'s backbone |

## B. `verify --batch` (X4)

| # | Path | What it catches today | Evidence | s/run | Recommendation |
|---|---|---|---|---|---|
| B1 | `tools/verify/batch.py` (1,136), `timing.py` (169, batch-only), `batch.md` (121); `tests/test-verify-batch.py` `BatchTests` 56, `AppleLaneTests` 1, `ChainInterruptTests` 2, `ShardedIosProbeTests` 4 (118–1528); `test-verify.py::LedgerTests.test_batch_fixture…` (942–949); `verify.py` 1299–1301, 1492; `mini.py` 191–192; `scripts/tron` 99–107; README 521–526; PRINCIPLES P2 "Enforced by" | Post-landing full-suite run with attribution and causal revert. **Last run 2026-11-10 (error). Last green 2026-11-03. 1 green in the last 25 batches.** `tron.verify.revertRemote` was never set, so it has never reverted anything. Since slice 5, `land` validates Tiers 0–2 on the exact merge before push, and runs `verify --full`, which includes the serial nested files that `verify --changed` defers to "batch" (`verify.py` 942–952) | *verified* in `.git/verify/batches/*/report.json` and `green.json` | 251.0 | **delete** (D4). Move `FullGatewayLockTests` and `FullGatewayLockQueueTests` (1529–end, 9.0 s), which test `host_lock.py`, to a `test-host-lock.py` owner first. Not covered by `land` today: Tier 3 iOS and the Mac integration lane. Those belong to the slice 12 and 14 checkpoints |

## C. iOS scroll-performance UI tests (X3)

| # | Path | What it catches today | Evidence | s/run | Recommendation |
|---|---|---|---|---|---|
| C1 | `UITests/TronListStandardPerformanceUITests.swift::testLargeHistoryScrollPerformance` | `measure {}` has no committed baseline (no `.xcbaseline` in the tree), so the timing cannot fail. One real claim: 1,000 history entries auto-load by scrolling alone (L23, `h-5733`). No other test asserts it | *verified* | 396.4 | **merge**: move the auto-load assertion into `TronListStandardUITests` (reuse `openLargeHistory()`, L373) and delete the method |
| C2 | `UITests/TronAutomationsListPerformanceUITests.swift::testLargeInventoryScrollPerformance` | `measure {}` without a baseline. Its only asserts are existence waits for the menu and the first `automation-card.`, which other UI tests also wait for (`automation-card.` appears 10 times outside this file) | *verified* | 232.2 | **delete** |

The other X2 rows have resolved. `testSettingsScopeVisualReview…` and `testExpandedSettingsRoutes…` were deleted with the
settings renderer (`3e7e59fffa`). `testNativeHierarchyReviewMatrix` and `TronD4ReviewUITests` carry real asserts and are
converted in groups 9–10, not deleted. `testPhotoChromeForVisualReview` (63.5 s) asserts the top edge, zoom and close:
**keep**.

## D. Gateway tests

| # | Path::test | Category | Survivor / evidence | s/run | Rec. |
|---|---|---|---|---|---|
| D1 | `src/e2e/integrations/tests/connections.projection.integration.test.ts::refuses the retired connection, extension-history, timeline and model-validation RPCs…` (134–150) | absence-only: 15 removed method names answer `not_found` | Generic unknown-method refusal: `protocol.wire.lock…::protocol 8` (`no.such.method`, L110, L151). *verified* | 0.35 | delete |
| D2 | `src/e2e/notifications/notifications-queue.lock.integration.test.ts::refuses the deleted read-only methods push.registration.status and filesystem.home…` (379–385) | absence-only | Same survivor as D1. *verified* | 0.52 | delete |
| D3 | `src/e2e/automations/automation-scheduler.integration.test.ts::…cancels a reserved queued run before its durable claim…` (29–121) | duplicate at a lower level | `automation-home.e2e.test.ts::real Gateway: cancellation before durable claim…` (754–756 → 708–751): same `mutateState` barrier, `cancelled`, 0 trigger messages. *verified* | 0.65 | delete |
| D4 | `src/e2e/modules/apps/swift-app-store.integration.test.ts::…refuses the retired direct v1 install action…` (139–146) | absence-only (retired action) | Asserts that an unknown action value is refused | 0.27 | delete |
| D5 | `src/modules/home/home-task-store.integration.test.ts`: `refuses a task record that carries a deleted field…` (282–301), `refuses an authorization request or grant that carries a deleted binding field` (303–320), `refuses a wake state the inbox no longer writes…` (274–280) | absence-only (retired fields) | The `corruptions` loop already proves unknown-key refusal on read for task and authorization (338–346). Keep write-side coverage by adding a top-level `surprise: true` and the old wake state to the `invalid` list (236–252). *verified* | 0.31 | merge, then delete the 3 |
| D6 | `src/providers/context-window-policy.integration.test.ts::isolates sessions and models and reapplies when returning to a model` (210–221) | duplicate (unit under E2E) | `src/e2e/sessions/runtime-context-window.integration.test.ts` 70–76 (small → 128 000 → large → 1 000 000, second session isolated). *verified* | 0.01 | delete |
| D7 | `src/modules/home/profile-file.integration.test.ts::stores one hierarchical file, resolves only the current head or an exact linked claim…` (26–44) | duplicate | `e2e/modules/home/home-profile-partition.integration.test.ts` L65, L76. Move L34 (unanchored title not in bytes) there | 0.05 | merge |
| D8 | `src/e2e/sessions/administrative-drain-snapshot.integration.test.ts` (whole file, 2 cases) | unit duplicating integration (registry built by hand) | `transport/rpc-idle-admission.integration.test.ts` 883–1025 and `runtime-registry-activity…` L912 through the real drain RPC | 0.01 | delete |
| D9 | Assertion lines only: `modules/home/home-restart.lock.integration.test.ts` L196 (`ok \|\| error` truthy, effectively unfailable); `kernel/delegation/managed-subagents.transform.integration.test.ts` 20–22, 50, 55–56 (stall sampler written only under an env var that nothing sets); `transport/server-capacity.integration.test.ts` 181–182, 190–192, 195–200 (private-method spies) | unfailable / change-detector | The kept tests' real assertions remain | 0 | delete the lines |

## E. Tooling tests

| # | Path::test | Category | Survivor / evidence | s/run | Rec. |
|---|---|---|---|---|---|
| E1 | `scripts/test-tron-profile.py::MultiDriverImpairment.test_the_blackhole_waits_the_phone_backoff_and_consumes_its_path_change` (1106–1127) | duplicate driver run | Same blackhole leg as `…counts_its_attempts_and_recovers…` (1080). Run one leg at the 2 s deadline with both sets of assertions. *verified* | 14.1 | merge |
| E2 | `scripts/test-tron-profile.py::MultiDriverImpairment.test_the_restart_case_reports_the_new_startups_budget` (1197–1207) | duplicate driver run for one pass-through field | Add `startup` to the stub config of `…counts_the_storm_from_the_restore` (1152) and assert it there. *verified* | 11.4 | merge |
| E3 | `tools/work/tests/test-skill.py::GitSkill.test_retired_commands_are_not_executable_aliases` (89–95) | absence-only | — *verified* | 0.6 | delete |
| E4 | `tools/docs/tests/test-docs.py::RealRepositoryTests.test_settings_list_holds_the_key_the_settings_lock_edited` (89–99) | structure lock on another test's source text | Fixture settings test (242–) and real `docs check` (101–104) | 0.4 | delete |
| E5 | `tools/home-layout/tests/test-home-layout.py::MigrateTests.test_the_shipped_registry_declares_slice_b_moves` (1152–1162) | snapshot of shipped data (exactly 14 moves) | Move mechanics proven on fixtures (718, 789) | 0.3 | delete |
| E6 | `tools/home-layout/tests/test-home-layout.py::AuditTests.test_no_effectful_audit_options_exist` (683–690) | absence-only | Read-only audit proven by the snapshot test (443–455). *verified* | 0.3 | delete |
| E7 | `tools/home-layout/tests/test-home-layout.py::HomeLayoutTests.test_manifest_export_capacity_matches_the_shipped_owner` (291–300) | structure lock (regex on TS constants) | Export bounds owned by the session-export tests | 0.0 | delete |

Line-only edits that save 0 s: `tools/proof/tests/facade.test.mjs` L52 (the L51 assertion repeated, *verified*);
`scripts/test-tron-node.py` 262–264 (source text of generated mirrors, which the `node-pin-mirrors.py check` at 269–275
already proves).

## F. iOS ViewTests and policy scripts

| # | Path | Category | Survivor / evidence | s/run | Rec. |
|---|---|---|---|---|---|
| F1 | `ViewTests/HomeTaskReadingViewTests.swift::testTaskReadingSubtextDark` (L8) | duplicate | Same `exercise` as Light. It asserts only frame heights and ratios, which dark mode cannot change. *verified* | 1.6 | delete |
| F2 | `ViewTests/HomeSheetsViewTests.swift::testWorkerRowsUseStandardSubtext` | duplicate | `HomeTaskReadingViewTests` 24–36 (same ids, `lineHeight`). Move the per-line check-in Done/Next equality (HomeSheets 19–22) there first | 1.3 | merge |
| F3 | `ios-app/scripts/test-build-matrix-policy.sh` 15–16 (stale config names absent), 91 (`#if BETA` absent), 92–94 (`exists()` repeated by the `read_text()` loop at 95–97), 98 (old xcconfigs absent) | absence-only / unfailable | L14 (exactly five configs), L132 (exact scheme set). *verified* | 0 (12.6 s file) | delete the lines |
| F4 | `ios-app/scripts/test-source-policy.sh` 13–14 | duplicate absence | L41–42 assert the same key on the generated project | 0 (1.1 s file) | delete the lines |
| F5 | `ios-app/scripts/test-build-matrix-policy.sh` 65, 70 (`#include` absent) | structure lock | Effective settings come from `xcodebuild -showBuildSettings` (172–208) | 0 | delete the lines |

## G. Later, slice 12 (X7). Listed so they are not lost; not for approval now

- `scripts/test-ios-test-infrastructure.py::GatewayE2EFixture` extra-lane cases at 4621, 4672, 4698, 4740, 4799 and 4832
  (6 cases, 42.3 s). They go with `--ios-jobs 2|3` and the `run-ui` lane queue, whose last caller is `batch.py`.
- `test-verify.py::IosLaneTests.test_a_class_larger_than_one_shard…` (2360–2556, 52.3 s): the concurrent-lane half
  goes; the packing half stays until the journeys shrink.
- DESIGN corrections: X7 is 6 + 1 cases, not "56 cases and most of a 6,923-line file". The rest of that file covers the
  live leases, sweep and simulator code. X4 is 63 + 1 cases, not 67 (4 test `host_lock.py`).

## Looked redundant, kept

| Path | Seam it guards |
|---|---|
| `src/e2e/protocol/protocol.wire.lock…::types.ts is exactly what Protocol.dfy generates` | Its twin `tools/proof/tests/wire.test.mjs` runs only through `test-core.py` in `python-here`, which `land` skips (`land.py:19`). This is the only copy `land` runs |
| `tools/proof/tests/test-core.py` (hand mutants 70.7 s, blocks 24.8 s, protocol wrapper 20.6 s) | Only gates on the real `packages/core` proofs |
| `managed-subagents.transform…::prepares only the catalog's own module graph…` (3.2 s) | Discovery does not wait for the session build and loads no Babel transform on the Gateway thread. The warm-process E2E does not prove it |
| `server-http-lifecycle.integration.test.ts` timeout literal pins (169, 182–184) | Touches timeout values: left to Mohsin, not in this list |
| `disposable-read-parity.integration.test.ts` | The only Swift ↔ TS guard for the cancellable-read list. Replace it with a generated list before deleting it |
| `profile-file…::keeps a shared claim until its last current Correction link is removed…` | The two-correction staged release has no E2E owner |
| `inert-pi-fields-migration` and `observed-git-residue-migration` tests | Delete each with its migration only after it has run on live `~/.tron` (Approvals 4) |
| `UITests` nested-history and retention methods in `TronSheetTintUITests` | They press the menu actions and persist the choice. Their ViewTests twins assert tint only |
| Store and session goldens (`*.lock.integration.test.ts`) | Persisted and model-visible formats |
| `test-ios-test-infrastructure.py` (other 189 cases), `test-tron-mac-replace.py`, home-layout crash and migration matrices, the episodic crash-cut matrix (85 s) | Real process, launchd and crash boundaries. Speed work, not deletion |

## Ledger hygiene (observation, not a deletion)

About 650 s of ledger means name tests that no longer exist. Examples: the pre-split `runtime-registry.integration.test.ts`
(148 s), a 310.96 s `server-http-lifecycle` title, 12 deleted ViewTests classes (171 s), `worker.test.ts` and
`test-mac.py`. Stats over the ledger should filter to tracked test ids. Slice 6's `verify stats` is the natural owner.

## Decisions for Mohsin

| # | Decision | Recommended | Why |
|---|---|---|---|
| D1 | Retire `scripts/tron flakes` now with hunt, or after slice 6? | **After slice 6** | It is the only same-tree flake reader, and the P6 flake policy names it. Hunt has no output and goes now |
| D2 | Default `--gateway-host` once the pool goes | **`local`**; explicit `mini` stays for heavy runs; `land` validates on the mini | Saves the per-verify SSH probe. Matches X6 ("workers do not use the mini") and the AGENTS.md rule that heavy runs name `--gateway-host mini` |
| D3 | Drop the never-set `contended` column | **Yes**, via a one-shot backed-up ledger migration | No dead schema. It is maintenance data outside `~/.tron` |
| D4 | Delete `verify --batch` (X4) now, or after the 3-day side-by-side (from 2026-11-21) | **Now** | It has not run since 2026-11-10 and was green once in 25 runs, so a side-by-side would compare against nothing. `land` already runs `--full` Tiers 0–2 before push. Also needed: stop Home's batch Automation and edit P2 |
| D5 | Delete the two scroll-performance UI tests (X3) | **Yes**, keeping the 1,000-entry auto-load assertion | 628.6 s per run. With no baseline they cannot fail on time |
| D6 | Approve groups D–F as listed | **Yes** | 21 rows, each with a named survivor or no fault caught. ≈ 32 s |
