# Simplification program

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-24, V-0, S-COMMENTS-1, S-STRUCT-1, S-DOCS-1
- **Goal:** Every file, module, abstraction, dependency, comment and test in Tron has a specific, visible reason to exist, with no change to what users see or do.

Follow the [plan protocol](README.md#protocol) to claim tasks and hand off.

## Goal and constraints

The goal is a codebase where the next agent can see why each piece exists.
Fewer lines are a side effect, never the target.

**The overriding rule: Tron's intended UI, UX and workflows do not change.**
This holds for iOS, the Mac app, the Gateway's observable behavior, the CLI and
scripts. If something is actually useful, keep it. When in doubt, it stays, and
the doubt goes in a handoff entry for the user.

A change is out of bounds if it alters any of these:

- What a user sees or can do: screens, controls, copy, navigation, gestures,
  keyboard and composer behavior, scroll position and chat identity.
- Timing a user can feel: launch, reconnect, send, scroll, streaming.
- Wire contracts: RPC methods, payload shapes, protocol versions, persisted file
  formats under `~/.tron`, iOS caches and Keychain entries.
- Operational workflows: install, rebuild from source, deploy, rollback, pairing,
  and the `scripts/tron` commands a maintainer uses.
- Safety properties: credential storage, trust gating, redaction, bounds,
  idempotency.

A wire contract or persisted format may change only if no live consumer exists.
Prove that with a search of every consumer (Gateway, iOS, Mac, scripts,
fixtures) and state it in the handoff.

**Coordination:** the observability foundation plan closed on 2026-09-24
(see [HISTORY](HISTORY.md)). Its logging, export and deploy-reporting code is now
ordinary code for this program; the level policy, streams and event catalog it
must keep are owned by `packages/gateway/docs/observability.md`.

## Context

Counts are from `git ls-files` at commit `1919394af` (2026-09-23): about 1,180
tracked files; roughly 60k lines of Gateway source with 43k of tests, 107k of
iOS source with 73k of tests, and 12k of Mac source with 7k of tests. Each row
is a scoping unit whose area code appears in task IDs. Scoping tasks may split a
unit and add rows here.

| Area code | Path | Source lines | Test lines | Notes for scoping |
| --- | --- | --- | --- | --- |
| GW-SESS | `packages/gateway/src/sessions` (38 files) | 22,817 | 18,826 | Largest unit; split before cleanup. `runtime-slot.ts` 7,869 lines, `runtime-registry.ts` 3,651, `projection.ts` 2,198; `runtime-registry.integration.test.ts` is 10,560 lines |
| GW-TRANS | `packages/gateway/src/transport` (11 files) | 5,763 | 6,983 | `server.ts` 2,021 and `gateway-service.ts` 2,005; 30 test files |
| GW-KNOW | `packages/gateway/src/knowledge` (18 files) | 6,796 | 3,685 | Includes legacy import |
| GW-MACH | `packages/gateway/src/machine` | 3,472 | 1,921 | |
| GW-AUTO | `packages/gateway/src/automations` | 3,229 | 1,480 | |
| GW-EXT | `packages/gateway/src/extensions` | 3,221 | 1,793 | |
| GW-ADMIN | `packages/gateway/src/admin` | 2,854 | 1,773 | Update service and install helpers |
| GW-DISP | `packages/gateway/src/display` | 2,182 | 1,291 | |
| GW-SMALL | integrations, notifications, providers, protocol, runtime, security, util, workspace, client, lifecycle | about 7,000 | about 5,000 | Scope together; lifecycle is one 5-line file |
| GW-ROOT | `index.ts`, `config.ts`, `errors.ts`, `version.ts` and the migrations at the `src/` root | 2,506 | 853 | Migrations: `agent-home-migration.ts`, `agent-home-preflight.ts`, `internal-layout-migration.ts`, `sessions/delegated-root-migration.ts`, `integrations/connection-migration.ts`. Check completion before proposing removal |
| IOS-STATE | `packages/ios-app/Sources/State` (42 files) | 24,322 | in Tests/Gateway | `AppModel.swift` 4,836, `SessionPresentationStore.swift` 3,418, `ComposerDraftCoordinator.swift` 2,483 |
| IOS-CHAT | `packages/ios-app/Sources/UI/Chat` (73 files) | 39,556 | about 20,000 | Split before cleanup; highest UX risk (scroll, composer, keyboard) |
| IOS-SET | `packages/ios-app/Sources/UI/Settings` (34 files) | 10,141 | about 3,000 | |
| IOS-UI-OTHER | UI Automations, Components, Onboarding, Terminal, Theme | 13,463 | about 4,000 | |
| IOS-CORE | Sources App, Auth, Gateway, Models, Notifications, Support | 19,053 | about 15,000 | Includes the observability code (AppLog, log export); its event catalog in `packages/gateway/docs/observability.md` must stay accurate |
| IOS-TEST-INFRA | Tests Fixtures and Support, UITests, TestPlans, iOS scripts | about 2,300 | n/a | Audit last in the iOS track |
| MAC | `packages/mac-app/Sources` (7 dirs) | 11,931 | 7,154 | |
| MAC-NATIVE | `packages/mac-app/native-computer-control`, `packages/mac-app/native-gateway-client`, `packages/mac-app/scripts` | 7,279 | in-dir | Includes the C launcher |
| RELAY | `packages/push-relay` (26 files) | 6,461 total | in-dir | |
| SCRIPTS | `scripts/` (52 files) | 15,104 total | in-dir | `scripts/gateway-payload-deploy.mjs` 2,510; two ~1,200-line Python reinstall tools plus a 1,309-line test for them |
| DOCS | Root docs, package docs (24 files), `.agents/` | n/a | n/a | Cutover and migration docs may describe finished work |
| DEPS | Package manifests and Swift packages | n/a | n/a | Gateway has 9 runtime dependencies; iOS uses SwiftTerm |

## Plan rules

### What counts as a finding

Every finding names a file and line range, what the code is for, why it is more
than needed, the smaller alternative, and the acceptance conditions that must
still pass.

| Finding type | What it looks like | Default proposal |
| --- | --- | --- |
| Single-use abstraction | A protocol, interface, generic, factory, wrapper or strategy with one real implementation or one caller (test doubles do not count as a second use) | Inline it into its one user |
| Duplicated capability | Two implementations of the same job: parsing, redaction, retries, bounds, path validation, date formatting, JSON helpers | Keep the better one; move callers; delete the other |
| Speculative extensibility | Options, flags, parameters, plugin points or config nobody sets; enum cases never produced; "future" hooks | Delete; hard-code the one value used, as a named constant with its reason |
| Unnecessary dependency | A package, framework or import that a few lines of platform API replace, or that is unused | Remove it; use the platform API |
| Dead code | Unreferenced files, exports, functions, types, assets, scripts, flags, RPC handlers with no caller | Delete after checking runtime registration, reflection, generated code and external callers |
| Compensating mechanism | A cache, timer, retry, flag or parallel state that patches misplaced ownership | Fix ownership at the owner, then delete the patch |
| Test-only seam | Injection points, protocols or parameters that exist only so a test can reach in | Delete once the test that demanded it is gone or rewritten against behavior |
| Misleading comment | Comments narrating syntax, describing the absence of something ("no longer does X", "we don't need Y"), agent diaries, or stale rationale | Delete, or rewrite as the current why |
| Orphan documentation | Docs describing removed behavior or duplicating another doc | Delete or merge into the owning doc |
| Temporary or stale file | Leftovers from one commit's testing, one-off plans or reports, scratch fixtures, backup copies, or docs and scripts that drifted from the code | Delete, or move lasting content into the owning file |

Keep a mechanism, even if it looks heavy, when it protects a real requirement:
security boundaries, data durability, bounded resources, crash recovery or a
measured performance need. Say which requirement in one line.

### The test bar

A test stays only if it protects a behavior a user, operator or other component
relies on, and would keep passing through any correct refactor of the code
under it.

**Keep a test when all of these hold:**

1. It asserts an observable outcome: a return value, emitted event, RPC
   response, persisted file, rendered state, error surfaced to the user, or a
   bound being enforced.
2. It names the requirement it protects, in its title or a one-line comment.
3. Breaking the protected behavior makes it fail. Where that is not obvious,
   prove it once with a negative control and note it in the handoff.
4. It runs in the narrowest harness that can observe the behavior, with no
   real-time sleeps (inject the clock).

**Delete or rewrite a test when any of these hold:**

- It fails on a correct refactor: it asserts call order, private state, mock
  interaction counts, internal types, exact log wording or file layout rather
  than outcomes.
- It duplicates another test's protection at a slower or broader level.
- It tests a test helper, a fixture or the framework.
- It snapshots large structures where only a few fields matter.
- It protects dead or speculative code (delete with the code).
- It is a multi-minute end-to-end run whose protection a focused owner test
  already gives.

When a test is removed, its requirement must still be covered, by an existing
test (name it) or a rewritten behavior test.

**The test-then-seam loop.** Test audits run before cleanup in each area,
because tests often force production seams to exist:

1. Audit the area's tests against the bar; delete or rewrite failures and record
   each requirement's surviving coverage.
2. Find the seams those tests demanded: protocols whose only second
   implementation is a fake, injectable clocks or factories nothing else uses,
   symbols exported only for tests, parameters with test-only values.
3. Collapse each seam no remaining test needs. A seam a remaining behavior test
   genuinely needs (such as an injected clock for bounded timing) stays.
4. Re-run the area's focused tests and record wall time before and after.

### Task types

- **Scoping (S-).** Read the unit's code, tests, docs and callers; change no
  code. Produce, in a findings block:
    1. a three-sentence summary of what the unit owns, with its inbound and
       outbound dependencies;
    2. a findings table (file and lines, finding type, purpose, smaller
       alternative, acceptance conditions, UX risk of none, low or needs
       V-0-UX check, and estimated lines removed);
    3. a test map (each test file, the requirements it protects, and keep,
       rewrite or delete). If the unit's tests exceed about 3,000 lines,
       split this into a T- task instead;
    4. a keep list of heavy-looking mechanisms checked and kept, each with its
       requirement;
    5. new C- and T- rows, each sized to one reviewable change of roughly
       under 800 changed lines, plus S- rows for sub-units needing another pass.
- **Test audit (T-).** Apply the test bar and the test-then-seam loop. The
  handoff lists every removed test with the test that now covers its
  requirement.
- **Cleanup (C-).** Work in a worktree on branch `simplify/<task ID>` from the
  latest `main`. Make only the change the row describes. Update the owning docs
  and nearest breadcrumbs in the same change, and delete stale docs rather than
  annotating them. Commit with a message stating what was removed and why
  behavior is unchanged. Merge to `main` only if your session is authorized to;
  otherwise leave the branch and say so.
- **Verification (V-).** Produce evidence only.

### Validation and safety

These apply on top of `AGENTS.md`, which wins on any conflict.

- **Behavior unchanged:** run the focused owner tests for everything touched,
  before and after, and record pass counts and wall times. Run the affected
  package's full suite once before handing off a C- or T- change.
- **UX checks:** for any iOS or Mac change with UX risk above none, re-check
  the affected V-0-UX flows and compare screenshots. A still image does not
  prove motion, scrolling or keyboard behavior; exercise those and say what you
  exercised.
- **Deletions:** show the reference search (code, tests, scripts, CI, docs, RPC
  routing, generated projects) and that it is empty.
- **Evidence labels:** distinguish inspected, inferred, reproduced and verified
  evidence.
- **Structure:** anyone who adds, moves, renames or deletes a file updates every
  reference to it and its owning doc in the same change, and commits no
  temporary files.
- **Operational safety:** never rebuild, restart, update, promote or roll back
  the Gateway, reinstall the Mac app, or run mutating `scripts/tron dev`
  commands. Never touch `~/.tron` data, credentials, iOS app data or Keychain.
  Run `scripts/personal-info-guard.sh` before every commit, and script tests with
  the pinned Node from `.node-version`.
- **Ask the user** before changing anything under the overriding rule, removing
  a migration, persisted format or wire contract, or when agents' findings
  conflict.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| V-0 | Done | Baseline: run and time every focused and full suite (Gateway vitest, scripts `node --test` with the pinned Node, iOS `scripts/tron-ios-test`, Mac `xcodebuild test`); record pass state and wall times in a handoff entry for later comparison | none | simplification session, 2026-09-24 |
| V-0-UX | Ready | UX baseline: list the user flows that must not change (launch, pair, open session, send, stream, scroll history, composer and keyboard, attachments, settings, automations, rebuild from source, rollback), with a simulator screenshot per key screen kept outside the repo and listed in the handoff | none | |
| S-DEAD-1 | Ready | Repo-wide dead-code sweep with tools run ad hoc (not added to the repo): unused TS exports, files and dependencies; unused Swift declarations; unreferenced scripts, assets, docs and fixtures. Verify each hit by hand (runtime registration, RPC routing, reflection, generated code, CI, `scripts/tron`). Output one C-DEAD row per coherent deletion batch | V-0 | |
| S-DEPS-1 | Ready | Dependency audit: every Gateway, relay, iOS and Mac dependency, what uses it, and whether platform API covers it. Output C-DEPS rows | V-0 | |
| S-COMMENTS-1 | Done | Comment sweep method: grep patterns for comments that describe absence, narrate syntax or read as agent diaries; sample 50 hits to calibrate. Output the patterns plus per-area C-COMMENTS rows | none | simplification session, 2026-09-24 |
| S-STRUCT-1 | Done | Structure sweep: every tracked file and directory needs a current owner and reason. Find one-off plans and reports, leftover fixtures (check `display-smoke/`), backup copies, config for tools no longer used (check `.codex` and `.pi`), docs for finished cutovers and tracked generated files. Check each against CI, `scripts/tron` and code references. Output C-STRUCT rows | none | simplification session, 2026-09-24 |
| S-BUILD-1 | Ready | Build-output hygiene. On 2026-09-23 agents had left about 1,100 ad-hoc DerivedData folders in `/tmp` (11 GB, cleared by a restart), and each worktree keeps its own 1.2–3.8 GB build tree (35 GB across 24 worktrees) because `scripts/tron-ios-test` builds into the worktree. That file churn grew `fseventsd` to 49 GB, filled swap and stalled the live Gateway. Scope: where repo scripts and the `tron-ios` skill send build output, one owned location per purpose so agents stop inventing paths, and releasing build output when a worktree is released through the housekeeping procedure. Also: `packages/mac-app/scripts/bundle-gateway.sh` makes the staged payload under `packages/mac-app/Sources/Resources/Gateway` read-only, so `git worktree remove` fails partway through a merged worktree that has staged it (seen on two worktrees on 2026-09-23); release must handle that without force-deleting. Output C-BUILD rows | none | |
| T-IOS-WATCHDOG-1 | Done | Make `withTestWatchdog` (`packages/ios-app/Tests/Support/TestWatchdog.swift`) end a test at its timeout even when the operation is blocked on a non-cancellable wait; today the task group waits for the stuck child, so the run stalls until `scripts/tron-ios-test`'s 180 s no-output or 20 min process deadline (seen 2026-09-24: 5–11 min runs from one hung test) | none | observability session, 2026-09-24 |
| T-IOS-FLAKY-OPENING-1 | Ready | `ChatViewScrollHarnessTests.hostedOpeningRevealIsMonotonic` is flaky on unchanged `main` (failed 4 of 6 isolated runs on 2026-09-24; its monotonic-distance check allows only 0.035 pt of regression). Find whether the reveal genuinely regresses or the oracle samples frames nondeterministically, and fix the owner, not the tolerance | none | |
| T-IOS-DEVICE-PROBE-1 | Needs scoping | Measure whether simulator test runs lose time to xcodebuild probing a paired, passcode-locked physical iPhone (`DTDKRemoteDeviceConnection … passcode protected` in `test.log`), and stop it for simulator destinations if it does | none | |
| C-STRUCT-DELETE-1 | Ready | Delete the verified orphans in one change: `display-smoke/` (4 manual fixtures, no references outside this plan), the one-off `packages/gateway/docs/computer-use-image-g0.md` report (no inbound links; states the old Pi pin), and `packages/ios-app/docs/assets/tron-logo.png` (no references; a duplicate of the smoke photo). Re-run the reference searches and the documentation policy check | S-STRUCT-1 | |
| C-DOCS-GW-1 | Ready | One owner for session-search and knowledge bounds: `packages/gateway/docs/session-search.md` has no inbound links and restates the Gateway README's "Session search" section; keep one owner and link the other, and do the same for the knowledge bounds stated in the README and `packages/gateway/docs/knowledge.md` | S-DOCS-1 | |
| C-DOCS-PIN-1 | Ready | Correct stale Pi pins: the Gateway README (two places), `packages/gateway/docs/agent-home-reference-inventory.md`, `packages/gateway/docs/cutover-runbook.md` and `packages/mac-app/docs/agent-home-cutover.md` still say Pi 0.84.4 and `pi-subagents` 0.59.0; the pin is 0.87.1 and `pi-subagents` is runtime-installed, not a repository dependency | S-DOCS-1 | |
| C-DOCS-OWNER-1 | Ready | Contributor facts owned once: the retired-architecture list, the iOS configuration matrix (four copies), the TronMac test commands (four copies) and the documentation-ownership list (in both `AGENTS.md` and `CONTRIBUTING.md`) keep one owner each and are linked elsewhere | S-DOCS-1 | |
| C-DOCS-SPLIT-1 | Ready | Split the multi-thousand-word paragraphs in `packages/ios-app/docs/development.md`, `packages/ios-app/docs/architecture.md` and `events.md`, the Mac development doc and the Gateway README into titled subsections, deduplicating while splitting; content unchanged otherwise (one file per change, each under 800 changed lines) | S-DOCS-1 | |
| C-COMMENTS-1 | Ready | Fix the four verified misleading comments: the Mac `TronColors.swift` header names a nonexistent iOS file and claims hex values match iOS when they differ; `PairingURLBuilder.swift` and its test name a nonexistent `PairingURLParser` (the consumer is `PairingInvitationParser`); `MenuBarItemBuilder.swift` cites a nonexistent "plan §A"; `OnboardingModels.swift` narrates removed behavior. Also the two weak Gateway and scripts cases in the S-COMMENTS-1 findings | S-COMMENTS-1 | |
| C-COMMENTS-REFCHECK-1 | Needs approval | Extend `scripts/check-documentation-policy.py` to check backticked repository paths inside code comments, the only check that would have caught the stale palette reference (about 30 lines). Adds a CI rule, so the user decides | S-COMMENTS-1 | |
| C-STRUCT-RULES-1 | Ready | Make the structure self-maintaining with the least mechanism: (1) a short `AGENTS.md` rule that whoever adds, moves or removes a file updates its references, owning doc and ownership notes in the same change and commits no temporary files; (2) a two-line "owns / does not own" note in each package's existing README or doc where missing; (3) only if S-STRUCT-1 finds recurring leftovers, one fast CI check for the patterns actually found | S-STRUCT-1 | |
| S-GW-ROOT-1 | Ready | For each migration tool and cutover doc, determine whether it is complete on every supported install. Removal needs the user's approval; record the evidence and the question | V-0 | |
| S-GW-SESS-1 | Ready | Split GW-SESS into sub-units (runtime slot, registry, projection, catalog, search, blobs, process activity, extensions projection); add one S-GW-SESS row per sub-unit with its file list | V-0 | |
| S-GW-SESS-SEARCH-1 | Needs scoping | Moved from observability L-8c: session-search warm-up peaks at 743.9 MiB post-GC heap (1.3 GB RSS) on a 207-session catalog because the canonical read and parse path (`RuntimeRegistry.readSearchCut`) materializes whole sessions up to its 64 MiB cap. First record why 62 of 207 catalog sessions were not indexed and correlate GC samples with read sizes; then bound or stream the parse while keeping full graph and branch validation. Acceptance: peak post-GC heap under 150 MB on a cloned corpus, identical indexed counts and ranked results, warm-up no more than 10% slower | none | |
| T-GW-SESS-1 | Ready | Test audit of `runtime-registry.integration.test.ts` (10,560 lines): map each test to the requirement it protects; propose deletions, merges and rewrites | V-0 | |
| S-GW-TRANS-1 | Ready | Scope GW-TRANS (server, gateway service, receipts, transcript leases, logger, diagnostic export); keep `packages/gateway/docs/observability.md` accurate | V-0 | |
| S-GW-KNOW-1 | Ready | Scope GW-KNOW | V-0 | |
| S-GW-MACH-1 | Ready | Scope GW-MACH | V-0 | |
| S-GW-AUTO-1 | Ready | Scope GW-AUTO | V-0 | |
| S-GW-EXT-1 | Ready | Scope GW-EXT | V-0 | |
| S-GW-ADMIN-1 | Ready | Scope GW-ADMIN (update service, install helpers) | V-0 | |
| S-GW-DISP-1 | Ready | Scope GW-DISP | V-0 | |
| S-GW-SMALL-1 | Ready | Scope the small Gateway modules together | V-0 | |
| S-IOS-STATE-1 | Ready | Scope IOS-STATE, `AppModel.swift` first, including its tests in Tests/Gateway | V-0, V-0-UX | |
| S-IOS-CHAT-1 | Ready | Split IOS-CHAT into sub-units (transcript projection, scroll, composer, media, detail sheets); add one row per sub-unit | V-0, V-0-UX | |
| S-IOS-SET-1 | Ready | Scope IOS-SET | V-0, V-0-UX | |
| S-IOS-UI-OTHER-1 | Ready | Scope IOS-UI-OTHER | V-0, V-0-UX | |
| S-IOS-CORE-1 | Ready | Scope IOS-CORE, including AppLog and log export; keep `packages/gateway/docs/observability.md` accurate | V-0, V-0-UX | |
| S-MAC-1 | Ready | Scope MAC | V-0, V-0-UX | |
| S-MAC-NATIVE-1 | Ready | Scope MAC-NATIVE, including the C launcher | V-0 | |
| S-RELAY-1 | Ready | Scope RELAY | V-0 | |
| S-SCRIPTS-1 | Ready | Scope SCRIPTS: which scripts a maintainer or CI actually runs; the Python reinstall tools and their tests; the deploy helper excluding progress reporting | V-0 | |
| S-DOCS-1 | Done | Docs: one owner per fact per `AGENTS.md`; flag docs that describe finished cutovers or duplicate another doc | none | simplification session, 2026-09-24 |
| S-XMOD-1 | Needs scoping | Cross-module duplication of the same capability across packages (redaction, bounds, JSON helpers, path validation, protocol constants), from candidates the area scopings report | all S-GW, S-IOS and S-MAC scoping rows | |
| T-IOS-TEST-INFRA-1 | Needs scoping | Audit iOS test harness helpers after the iOS test audits, deleting helpers no remaining test uses | all iOS test-audit rows | |
| V-FINAL | Needs scoping | Final check: full suites against V-0 times, V-0-UX flows re-checked, dead-code tools clean, every Done row has a handoff | all rows | |

## Handoff log

### SETUP · Done · 2026-09-23 · planning session

- Result: created this plan, the codebase map from `git ls-files` at `1919394af`, and the seed tasks. The plan started as a shared Claude Doc and moved here the same day when the plans folder was created.
- Evidence: size counts only; no code inspected for findings yet.
- Changes: this file.
- Tasks added: V-0 through V-FINAL.
- For the next agent: start with V-0 and V-0-UX, which every area scoping depends on. S-COMMENTS-1, S-STRUCT-1 and S-DOCS-1 have no dependencies and can run in parallel with V-0. The user's uncommitted iOS README edit and untracked watch-audio plan are theirs; do not touch them.

### T-IOS-WATCHDOG-1 · Done · 2026-09-24 · observability session

- Result: `withTestWatchdog` races the operation (now an unstructured task) against its deadline instead of running both in a task group, so the deadline always ends the test. On expiry it cancels the operation and joins it for a bounded `cancellationGrace` (default 1 s); `TestWatchdogExpired` now carries the timeout and whether the operation exited, and its description says when the operation ignored cancellation and was abandoned. Outer cancellation still cancels and joins the operation.
- Evidence: `TestWatchdogTests` 3/3 in 0.13 s, including a new test with an operation blocked on a non-cancellable continuation (fails with `joined == false` in about 0.1 s) and one that a finishing operation's value and error win. Negative control: the new test against the old task-group watchdog stalled until `scripts/tron-ios-test` killed the run after 176 s. Full unit run (`scripts/tron-ios-test run`) with the new watchdog: 1871 Swift Testing tests in 138 suites plus 140 XCTest tests, 226 s wall, one failure in `hostedOpeningRevealIsMonotonic`, which is pre-existing flakiness (4 of 6 isolated failures with the old watchdog on unchanged `main`, 1 of 6 with the new one), recorded as T-IOS-FLAKY-OPENING-1.
- Changes: this commit (`Tests/Support/TestWatchdog.swift`, `Tests/Support/TestWatchdogTests.swift`).
- Tasks added: T-IOS-FLAKY-OPENING-1.
- Kept on purpose: an operation that ignores cancellation is abandoned (it runs until the test process exits) rather than blocking the run; the failure message names that case.

### T-IOS-WATCHDOG-1 correction · Done · 2026-09-24 · observability session

- Result: corrects the T-IOS-WATCHDOG-1 entry and row. Its row had an extra table cell. One of its tests asserted failure-message wording, which the test bar excludes; that assertion is removed, because `joined == false` on the line above already asserts the outcome.
- Evidence (verified): `TestWatchdogTests` 3/3 and `ChatViewScrollHarnessTests` 59/59 in one 69.5 s run. Full iOS run: 1,872 Swift Testing and 140 XCTest tests in 231 s. The only failure was the pre-existing `hostedOpeningRevealIsMonotonic`, which failed 2 of 6 isolated reruns and remains T-IOS-FLAKY-OPENING-1. The harness's two pixel samplers now share one `renderedLuminance`; by inspection the grid it samples for that test is unchanged.
- Changes: this commit.
- Tasks added: none.
- Kept on purpose: `expiryDoesNotWaitForNonCancellableOperation` asserts a real-time bound (under 2 s for a 50 ms deadline). The deadline is the behavior under test, and an injected clock would add a seam to every watchdog caller. A comment at the assertion says so.
- For the next agent: the harness's opening-cover test (`openingCoverHidesNavigationBand`) was checked against the rule that a test must fail when the behavior breaks: with the cover fix reverted, 65–108 text pixels showed through the band in each of 3 runs.

### V-0 · Done · 2026-09-24 · simplification session

- Result: baseline pass state and wall times at `fd790fb53` on this Mac (the live Gateway running), for later comparison. All suites pass.
- Evidence (verified):

| Suite | Command | Result | Wall |
| --- | --- | --- | --- |
| Gateway, full | `nice -n 19 npx vitest run --maxWorkers=2` in `packages/gateway` | 179 files, 1,941 tests | 80 s |
| Scripts, Node | `node --test scripts/*.test.mjs` (Node 22.22.0) | 67 tests | 133 s |
| Scripts, shell | `scripts/tron-dev-toolchain.test.sh`, `scripts/verify-ci-toolchain.test.sh` | pass | about 1 s |
| Mac reinstall tools | `python3 scripts/test-mac-reinstall.py` | 93 tests, 3 skipped | 2 s |
| Launcher | `packages/mac-app/scripts/test-tron-gateway-launcher.sh` | pass | 271 s |
| Mac payload scripts | `test-update-payload-fingerprint.sh`, `test-push-product-config.sh` | pass | under 1 s |
| Push relay | `npx vitest run` in `packages/push-relay` | 6 files, 39 tests | 4 s |
| iOS, full | `scripts/tron-ios-test run` after `build` | 1,889 Swift Testing tests in 139 suites plus XCTest | build 132 s, run 236 s |
| Mac, full | `xcodebuild build-for-testing` then `test-without-building` (TronMac) | 316 tests in 48 suites | build 227 s, run 134 s |

- Not run: `test-launchd-relaunch-fixture.sh` (opt-in, needs `TRON_RUN_LAUNCHD_FIXTURE=1`), and the payload verifier, npm and signed-payload smoke scripts, which need a staged Mac payload.
- Changes: this commit (plan only).
- For the next agent: the launcher shell test needs Node 22.22.0 on `PATH`, or it exits 2 immediately. `hostedOpeningRevealIsMonotonic` passed in this run; it remains T-IOS-FLAKY-OPENING-1.

### S-COMMENTS-1 · Done · 2026-09-24 · simplification session (DeepSeek lane, checked by the supervisor)

- Result: comment cleanup is nearly empty. Across 10,602 line-start comment lines, absence, syntax-narration and diary patterns reached at most 5% precision on a 50-hit sample, and no comment restates its next line. The real yield came from checking backticked names and paths against the repository: three of the four verified findings (C-COMMENTS-1). Plan task IDs, TODOs and dates in comments are absent, and the three dated comments are legitimate incident or verification evidence.
- Evidence (verified by the supervisor): the Mac `TronColors.swift` header names a nonexistent iOS TronColors.swift, and `PairingURLParser` and "plan §A" appear nowhere else. The lane's tuned patterns and per-area counts are in its run output; they are method, not code.
- Changes: this commit (plan only).
- Tasks added: C-COMMENTS-1, C-COMMENTS-REFCHECK-1 (needs approval).
- Kept on purpose: `MARK:` headers, the security comments in `bundle-gateway.sh`, and rationale comments that mention rejected alternatives.
- For the next agent: about 38 comments claim cross-layer parity ("mirrors the Gateway's …"); only the Mac palette claim was checked. Area scopings should verify such claims in their own units.

### S-STRUCT-1 · Done · 2026-09-24 · simplification session (DeepSeek lane, checked by the supervisor)

- Result: the tree is mostly owned. Three orphans can go (C-STRUCT-DELETE-1), and `packages/gateway/docs/session-search.md` has no inbound links and duplicates the README (C-DOCS-GW-1).
- Evidence (verified by the supervisor): reference searches outside `docs/plans/` return nothing for `display-smoke`, `tron-logo.png`, `computer-use-image-g0` or `session-search.md`.
- Kept on purpose: `.codex/environments/environment.toml` (allowlisted by `scripts/check-agent-policy.sh`), `.pi/prompts/` (deliberately un-ignored), `config/GatewayProtocol.json` (the authored wire contract), and the cutover runbooks. Those are still referenced, and their removal is S-GW-ROOT-1's decision.
- Changes: this commit (plan only).
- Tasks added: C-STRUCT-DELETE-1. C-STRUCT-RULES-1 is now unblocked; its optional CI check has no recurring leftover pattern to target.

### S-DOCS-1 · Done · 2026-09-24 · simplification session (DeepSeek lane, checked by the supervisor)

- Result: the documentation's main debts are stale facts, repeated contributor facts, and very long paragraphs that are hard to navigate.
- Evidence (verified by the supervisor): `0.84.4` still appears in the Gateway README (two places), the agent-home inventory, the cutover runbook and the agent-home cutover doc, while the pin is 0.87.1. The iOS configuration matrix and the TronMac test commands each appear in four files.
- Changes: this commit (plan only).
- Tasks added: C-DOCS-GW-1, C-DOCS-PIN-1, C-DOCS-OWNER-1, C-DOCS-SPLIT-1.
