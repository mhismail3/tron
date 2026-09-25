# Simplification program

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-25, T-GW-KNOW-1, T-MAC-1/2, C-GW-TRANS-2, C-GW-MACH-1, C-GW-DISP-1, C-GW-ADMIN-1, C-GW-SMALL-1
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
| S-DEAD-1 | Done | Repo-wide dead-code sweep with tools run ad hoc (not added to the repo): unused TS exports, files and dependencies; unused Swift declarations; unreferenced scripts, assets, docs and fixtures. Verify each hit by hand (runtime registration, RPC routing, reflection, generated code, CI, `scripts/tron`). Output one C-DEAD row per coherent deletion batch | V-0 | simplification session, 2026-09-25 |
| C-DEAD-1 | Done | Remove the five compiler-verified unused Gateway declarations: `readdir` and `isMissingFilesystemError` in `runtime-registry.ts`, `createHash` in `session-search-index.ts`, `semanticForState` in `projection.ts`, `OBJECT_SCHEMA_VERSION` in `knowledge-store.ts`, and the `KnowledgeSearchRequest` import in `knowledge-service.ts` | S-DEAD-1 | simplification session, 2026-09-25 |
| S-DEAD-2 | Ready | Finish the dead-code sweep S-DEAD-1 did not cover: repo-wide unused TS exports (not only file-local unused symbols), unused Swift declarations in iOS and Mac, and unreferenced scripts, assets, docs and fixtures, each hand-verified against registration, RPC routing, generated projects and CI | S-DEAD-1 | |
| S-DEPS-1 | Ready | Dependency audit: every Gateway, relay, iOS and Mac dependency, what uses it, and whether platform API covers it. Output C-DEPS rows | V-0 | |
| S-COMMENTS-1 | Done | Comment sweep method: grep patterns for comments that describe absence, narrate syntax or read as agent diaries; sample 50 hits to calibrate. Output the patterns plus per-area C-COMMENTS rows | none | simplification session, 2026-09-24 |
| S-STRUCT-1 | Done | Structure sweep: every tracked file and directory needs a current owner and reason. Find one-off plans and reports, leftover fixtures (check `display-smoke/`), backup copies, config for tools no longer used (check `.codex` and `.pi`), docs for finished cutovers and tracked generated files. Check each against CI, `scripts/tron` and code references. Output C-STRUCT rows | none | simplification session, 2026-09-24 |
| S-BUILD-1 | Done | Build-output hygiene. On 2026-09-23 agents had left about 1,100 ad-hoc DerivedData folders in `/tmp` (11 GB, cleared by a restart), and each worktree keeps its own 1.2–3.8 GB build tree (35 GB across 24 worktrees) because `scripts/tron-ios-test` builds into the worktree. That file churn grew `fseventsd` to 49 GB, filled swap and stalled the live Gateway. Scope: where repo scripts and the `tron-ios` skill send build output, one owned location per purpose so agents stop inventing paths, and releasing build output when a worktree is released through the housekeeping procedure. Also: `packages/mac-app/scripts/bundle-gateway.sh` makes the staged payload under `packages/mac-app/Sources/Resources/Gateway` read-only, so `git worktree remove` fails partway through a merged worktree that has staged it (seen on two worktrees on 2026-09-23); release must handle that without force-deleting. Output C-BUILD rows | none | simplification session, 2026-09-24 |
| T-IOS-WATCHDOG-1 | Done | Make `withTestWatchdog` (`packages/ios-app/Tests/Support/TestWatchdog.swift`) end a test at its timeout even when the operation is blocked on a non-cancellable wait; today the task group waits for the stuck child, so the run stalls until `scripts/tron-ios-test`'s 180 s no-output or 20 min process deadline (seen 2026-09-24: 5–11 min runs from one hung test) | none | observability session, 2026-09-24 |
| T-IOS-FLAKY-OPENING-1 | Ready | `ChatViewScrollHarnessTests.hostedOpeningRevealIsMonotonic` is flaky on unchanged `main` (failed 4 of 6 isolated runs on 2026-09-24; its monotonic-distance check allows only 0.035 pt of regression). Find whether the reveal genuinely regresses or the oracle samples frames nondeterministically, and fix the owner, not the tolerance | none | |
| T-IOS-DEVICE-PROBE-1 | Needs scoping | Measure whether simulator test runs lose time to xcodebuild probing a paired, passcode-locked physical iPhone (`DTDKRemoteDeviceConnection … passcode protected` in `test.log`), and stop it for simulator destinations if it does | none | |
| C-STRUCT-DELETE-1 | Done | Delete the verified orphans in one change: the display-smoke directory (4 manual fixtures, no references outside this plan), the one-off Gateway docs computer-use-image-g0.md report (no inbound links; states the old Pi pin), and the iOS docs asset tron-logo.png (no references; a duplicate of the smoke photo). Re-run the reference searches and the documentation policy check | S-STRUCT-1 | simplification session, 2026-09-24 |
| C-DOCS-GW-1 | Done | One owner for session-search and knowledge bounds: `packages/gateway/docs/session-search.md` has no inbound links and restates the Gateway README's "Session search" section; keep one owner and link the other, and do the same for the knowledge bounds stated in the README and `packages/gateway/docs/knowledge.md` | S-DOCS-1 | simplification session, 2026-09-25 |
| C-DOCS-PIN-1 | Done | Correct stale Pi pins: the Gateway README (two places), `packages/gateway/docs/agent-home-reference-inventory.md`, `packages/gateway/docs/cutover-runbook.md` and `packages/mac-app/docs/agent-home-cutover.md` still say Pi 0.84.4 and `pi-subagents` 0.59.0; the pin is 0.87.1 and `pi-subagents` is runtime-installed, not a repository dependency | S-DOCS-1 | simplification session, 2026-09-24 |
| C-DOCS-OWNER-1 | Done | Contributor facts owned once: the retired-architecture list, the iOS configuration matrix (four copies), the TronMac test commands (four copies) and the documentation-ownership list (in both `AGENTS.md` and `CONTRIBUTING.md`) keep one owner each and are linked elsewhere | S-DOCS-1 | simplification session, 2026-09-25 |
| C-DOCS-SPLIT-1 | Ready | Split the multi-thousand-word paragraphs in `packages/ios-app/docs/development.md`, `packages/ios-app/docs/architecture.md` and `events.md`, the Mac development doc and the Gateway README into titled subsections, deduplicating while splitting; content unchanged otherwise (one file per change, each under 800 changed lines) | S-DOCS-1 | |
| C-COMMENTS-1 | Done | Fix the four verified misleading comments: the Mac `TronColors.swift` header names a nonexistent iOS file and claims hex values match iOS when they differ; `PairingURLBuilder.swift` and its test name a nonexistent `PairingURLParser` (the consumer is `PairingInvitationParser`); `MenuBarItemBuilder.swift` cites a nonexistent "plan §A"; `OnboardingModels.swift` narrates removed behavior. Also the two weak Gateway and scripts cases in the S-COMMENTS-1 findings | S-COMMENTS-1 | simplification session, 2026-09-24 |
| C-COMMENTS-REFCHECK-1 | Done | Extend `scripts/check-documentation-policy.py` to check backticked repository paths inside code comments, the only check that would have caught the stale palette reference (about 30 lines). Adds a CI rule, so the user decides. Approved by the user on 2026-09-25 | S-COMMENTS-1 | simplification session, 2026-09-25 |
| C-BUILD-1 | Done | One owned per-user iOS build root shared by all worktrees: point the defaults in `scripts/tron-ios-test`, `scripts/tron-ios-simulator` and `scripts/tron-ios-device` at one root with a subfolder per purpose (test derived data, test runs, simulator, device), keep every existing override and the test lease, drop the duplicate defaults in `scripts/ios-ci-test.sh`, and name the root once in the iOS development doc and the `tron-ios` skill | S-BUILD-1 | simplification session, 2026-09-24 |
| C-BUILD-2 | Done | Release the eight unowned ad-hoc build folders agents invented under `packages/ios-app/build` (about 3.5 GB in the main checkout; no tracked reference) after re-running the reference search; no code change | C-BUILD-1 | simplification session, 2026-09-25 |
| C-BUILD-3 | Done | Housekeeping skill release step: before `git worktree remove`, run the worktree's own build cleaners, make exactly the generated payload root `packages/mac-app/Sources/Resources/Gateway` writable (the bundler makes it read-only, which is why removal fails partway), then plain `git worktree remove` with no force; refuse symlinks and any other path | S-BUILD-1 | simplification session, 2026-09-24 |
| C-BUILD-4 | Done | Give the documented TronMac build and test commands an explicit `-derivedDataPath` inside the package build folder, so they stop filling the global Xcode DerivedData (11 TronMac folders, 5.7 GB) | S-BUILD-1 | simplification session, 2026-09-24 |
| C-STRUCT-RULES-1 | Ready | Make the structure self-maintaining with the least mechanism: (1) a short `AGENTS.md` rule that whoever adds, moves or removes a file updates its references, owning doc and ownership notes in the same change and commits no temporary files; (2) a two-line "owns / does not own" note in each package's existing README or doc where missing; (3) only if S-STRUCT-1 finds recurring leftovers, one fast CI check for the patterns actually found | S-STRUCT-1 | |
| S-GW-ROOT-1 | Ready | For each migration tool and cutover doc, determine whether it is complete on every supported install. Removal needs the user's approval; record the evidence and the question | V-0 | |
| S-GW-SESS-1 | Done | Split GW-SESS into sub-units (runtime slot, registry, projection, catalog, search, blobs, process activity, extensions projection); add one S-GW-SESS row per sub-unit with its file list | V-0 | simplification session, 2026-09-24 |
| S-GW-SESS-SLOT-1 | Ready | Scope `runtime-slot.ts` in three passes by line range: core (1–2905: types, lane, binding, ownership, durable-write retry, attention), events (2906–5003: `onEvent`, streaming identity, completion ownership, artifact reads) and API (5004–end: progress, queue, snapshot, pages, prompt/abort, compaction, export, dispose) | S-GW-SESS-1 | |
| S-GW-SESS-REGISTRY-1 | Ready | Scope `runtime-registry.ts`, `session-attention-store.ts`, `session-presentation-presence.ts`, `session-branch.ts` | S-GW-SESS-1 | |
| S-GW-SESS-PARTS-1 | Ready | Scope the smaller GW-SESS sub-units in one pass: projection (`projection.ts`), catalog (`catalog-*`, `history.ts`, `summary-text.ts`), search (`session-search-*`, distinct from the performance row S-GW-SESS-SEARCH-1), blobs and export, process activity, extension activity (`extension-*`, `semantic-ui-broker.ts`, `hook-projection.ts`), receipts (`invocation-receipts.ts`, `resource-invocation.ts`, `context-delivery-receipts.ts`) and ownership (`run-markers.ts`, `delegated-provider.ts`, `gateway-work-registry.ts`, `fork-boundary.ts`, `restart-drain.ts`, `agent-runtime-lock.ts`). `delegated-root-migration.ts` stays with S-GW-ROOT-1 | S-GW-SESS-1 | |
| C-GW-SESS-1 | Done | Small verified GW-SESS cleanups in one change: one receipt validator (`invocation-receipts.ts:29-38,99-133` and `extension-notification-receipts.ts:7-49` duplicate `MAX_ID_BYTES`, the origin sets and `validText`/`validTimestamp`/`validOrigin`); one `MAX_EXTENSION_ARTIFACT_BYTES` (declared in both `runtime-slot.ts` and `runtime-registry.ts`); move the `RuntimeSlot` class doc from `observationBranchIdFor` to the class; delete the test-only `projectSkillInvocation` re-export in `projection.ts` and import it from `resource-invocation.ts` in the test; drop `export` from declarations used only in their own file | S-GW-SESS-1 | simplification session, 2026-09-25 |
| S-GW-SESS-SEARCH-1 | Needs scoping | Moved from observability L-8c: session-search warm-up peaks at 743.9 MiB post-GC heap (1.3 GB RSS) on a 207-session catalog because the canonical read and parse path (`RuntimeRegistry.readSearchCut`) materializes whole sessions up to its 64 MiB cap. First record why 62 of 207 catalog sessions were not indexed and correlate GC samples with read sizes; then bound or stream the parse while keeping full graph and branch validation. Acceptance: peak post-GC heap under 150 MB on a cloned corpus, identical indexed counts and ranked results, warm-up no more than 10% slower | none | |
| T-GW-SESS-1 | Done | Test audit of `runtime-registry.integration.test.ts` (10,560 lines): map each test to the requirement it protects; propose deletions, merges and rewrites | V-0 | simplification session, 2026-09-25 |
| T-GW-SESS-2 | Ready | The body-level T-GW-SESS-1 audit flagged 64 registry tests that reach private methods, fields or call counts (list in the T-GW-SESS-1 handoff). Classify each: (a) the count or order is the requirement (bounded work, coalescing, lock order, drain ordering), so keep it, name the requirement in the title and make the seam as narrow as possible; or (b) private access is only setup, so drive it through the public registry or slot boundary. Rewrite only (b), a few tests per change, each with a negative control. Do not mass-rewrite: the audit's suggested rewrites would drop the protection in several (a) cases, e.g. `coalesces concurrent fallback acquisition scans` | T-GW-SESS-1 | |
| S-GW-TRANS-1 | Done | Scope GW-TRANS (server, gateway service, receipts, transcript leases, logger, diagnostic export); keep `packages/gateway/docs/observability.md` accurate | V-0 | simplification session, 2026-09-25 |
| C-GW-TRANS-1 | Done | Make `diagnosticExportPolicy` in `transport/diagnostic-export.ts` module-private (its only caller is its test) and assert the byte and retention limits through export behavior | S-GW-TRANS-1 | simplification session, 2026-09-25 |
| T-GW-TRANS-1 | Done | Test audit of the 32 transport test files (12,819 lines) against the test bar, in batches under 800 changed lines | S-GW-TRANS-1 | simplification session, 2026-09-25 |
| C-GW-TRANS-2 | Done | Apply the T-GW-TRANS-1 map: 5 deletions (including the test for dead `releaseOwnedSubscription`, deleted with the function), 6 merges into table tests, 6 rewrites (framing tests move to the wire so the test-only `encodeOutboundFrame` export goes; the aborted-reservation test asserts capacity; the subagent-stop test uses a real lease store) | T-GW-TRANS-1 | simplification session, 2026-09-25 |
| S-GW-KNOW-1 | Done | Scope GW-KNOW | V-0 | simplification session, 2026-09-24 |
| C-GW-KNOW-1 | Done | Delete the test-only `knowledge/semantic-notes.ts` (its only importer is `source-capture.test.ts`; production calls the store directly) and rewrite those test calls against the store APIs | S-GW-KNOW-1 | simplification session, 2026-09-25 |
| C-GW-KNOW-2 | Done | Remove dead knowledge code: the unreachable store-sniffing branch in `legacy-import.ts` `resolveSource` (a named root always sets the store) with its "or path" comment and error wording, the unused `awaitAbortable` in `model-await.ts`, unneeded exports (`SOURCE_CAPTURE_USER_AGENT`, `redactSourceUrl`, the `JEV_REQUEST_MODEL` alias) and the single-implementation `KnowledgeTable` interface | S-GW-KNOW-1 | simplification session, 2026-09-25 |
| C-GW-KNOW-3 | Done | One credential-query-key predicate for the four copies (`x-public-post.ts`, `source-capture.ts`, `legacy-import.ts`, `knowledge-contract.ts`; source capture keeps its X-embed exception) and one normalized-URL helper for `source-capture.ts` and `knowledge-store.ts` | S-GW-KNOW-1 | simplification session, 2026-09-25 |
| C-GW-KNOW-4 | Done | Move the test-only `InMemoryConnectorCredentialStore` out of `connector-credentials.ts` into test support (7 test files across knowledge, sessions and integrations) | S-GW-KNOW-1 | simplification session, 2026-09-25 |
| T-GW-KNOW-1 | Done | Test audit of the GW-KNOW tests (3,708 lines): replace the real-time waits in `knowledge-observation.test.ts`, `connectors.test.ts` and `source-capture.test.ts` with an injected clock, and delete tests that assert internals; keep the two scale tests | C-GW-KNOW-1 to C-GW-KNOW-4 | simplification session, 2026-09-25 |
| S-GW-KNOW-2 | Ready | Scope the knowledge provider sub-unit (`connectors.ts`, the Jev client, assessment and extension, `fixed-host-transport.ts`) and pass redaction and bounds overlaps to S-XMOD-1 | S-GW-KNOW-1 | |
| S-GW-MACH-1 | Done | Scope GW-MACH | V-0 | simplification session, 2026-09-25 |
| C-GW-MACH-1 | Done | Machine test audit and seams (T-GW-MACH-1 + C-GW-MACH-1 + C-GW-MACH-2 from the scoping): delete the constant-only filesystem test and the node-pty chmod test; rewrite the upload-store private reach-ins and the `parseCuaOutput` table through `invoke()`; un-export test-only bounds and `CuaComputerResult`; construct `CuaComputerClient` from the binding only; drop the redundant replay clamp; one listing-bound module, one containment predicate and one fsync helper inside `machine/` | S-GW-MACH-1 | simplification session, 2026-09-25 |
| S-GW-AUTO-1 | Done | Scope GW-AUTO | V-0 | simplification session, 2026-09-25 |
| T-GW-AUTO-1 | Done | Make the timeline raw-occurrence bound private and delete its constant-positivity assertion; decide whether the scheduler test's exact `store.snapshot` call count is a protected bound or an internal detail | S-GW-AUTO-1 | simplification session, 2026-09-25 |
| S-GW-EXT-1 | Done | Scope GW-EXT | V-0 | simplification session, 2026-09-25 |
| S-GW-ADMIN-1 | Done | Scope GW-ADMIN (update service, install helpers) | V-0 | simplification session, 2026-09-25 |
| C-GW-ADMIN-1 | Done | Admin cleanup (C-GW-ADMIN-1, C-GW-ADMIN-2, T-GW-ADMIN-1 from the scoping): one `admin/document-admission.ts` for the duplicated failure-text, trusted-directory and timestamp rules in the update and iOS-install services; one atomic JSON writer in the update service with identical bytes; fix the stale "health-era" comment; replace wall-clock waits in `auth-broker.test.ts` and `global-provider-resources.test.ts`; classify `activeOperationCount` uses and the nine test-only exports, rewriting only setup-only ones | S-GW-ADMIN-1 | simplification session, 2026-09-25 |
| C-GW-ADMIN-3 | Done | Drop the flat and `candidate` `deployment-state.json` read shapes in `gateway-update-service.ts`; no writer has ever produced them (verified in history). Approved by the user on 2026-09-25 | S-GW-ADMIN-1 | simplification session, 2026-09-25 |
| C-GW-ADMIN-4 | Done | A stale `schema: 1` iOS-install `active.json` from before `7f23eba1a` makes `activeStatus()` throw, which blocks install and also `gateway.update`/`gateway.rollback`. Decide the owning-boundary fix (treat an unreadable old-schema document as stale). Approved by the user on 2026-09-25 | S-GW-ADMIN-1 | simplification session, 2026-09-25 |
| S-GW-DISP-1 | Done | Scope GW-DISP | V-0 | simplification session, 2026-09-25 |
| C-GW-DISP-1 | Done | Display cleanup (T-GW-DISP-1, C-GW-DISP-1 to 3 from the scoping): first add the missing NUL/invalid-UTF-8 ingest test and reduce the prompt-prose test to invariants; then remove the never-set `now`/`maximumReaders`/`maximumIngests` options and the test-only `initialize(liveSessionIDs)` branch, drop the redundant prefix NUL check, use one schema constant, artifact-ID pattern, kind list and bounded-text predicate, and un-export 12 unused declarations | S-GW-DISP-1 | simplification session, 2026-09-25 |
| C-GW-DISP-UTF8-1 | Done | Invalid (non-NUL) UTF-8 in a text display artifact makes ingest throw the decoder's `ERR_ENCODING_INVALID_ENCODED_DATA` instead of the intended `invalid_request`; nothing is published either way. Fixing it changes the error a client sees. Approved by the user on 2026-09-25; ingest now reports `invalid_request` and the test asserts that code | C-GW-DISP-1 | simplification session, 2026-09-25 |
| C-GW-DISP-PIN-1 | Done | Remove the revision-pinned `pi-agent-browser-native` spelling from `TRUSTED_BROWSER_EXTENSION_SOURCES` if no installed agent config names it (narrows trust only). Kept: the user agent settings name the revision-pinned source, so the entry is live | S-GW-DISP-1 | simplification session, 2026-09-25 |
| S-GW-SMALL-1 | Done | Scope the small Gateway modules together | V-0 | simplification session, 2026-09-25 |
| C-GW-SMALL-1 | Done | Dead surface in the small Gateway modules: delete `integrations/index.ts`, the empty capabilities block and one-line `createMcpAdapter` factory in `mcp-adapter.ts`, `ProtocolEvent`, and needless exports; one local-credential document validator (C-GW-SMALL-3); util/lifecycle/security test seams (T-GW-SMALL-1: private mutex queue assertion, `retainedKeyCount`, the shutdown-step clock); make `featureInitialized` read the key its writer uses. Not `client/restart-gateway.ts` (C-GW-SMALL-RESTART-1) | S-GW-SMALL-1 | simplification session, 2026-09-25 |
| C-GW-SMALL-SEAMS-1 | Done | Two test seams S-GW-SMALL-1 wanted gone turn out to be the only witnesses of a bound: `RateLimiter.retainedKeyCount` (prune is otherwise unobservable) and the mutex's private `waiting` size (a cancelled queued read is removed). Keep both with the requirement named, or add an observable. The user chose to keep both; each now names the bound it witnesses | C-GW-SMALL-1 | simplification session, 2026-09-25 |
| C-GW-SMALL-RESTART-1 | Done | Delete `client/restart-gateway.ts`: no `scripts/tron` command, bin entry, test or doc references it; the Mac app has its own restart client. Approved by the user on 2026-09-25 | S-GW-SMALL-1 | simplification session, 2026-09-25 |
| C-GW-SMALL-2 | Done | One JSON publisher: move `atomicWriteJson` callers (push grant store, artifact and upload metadata, iOS-install documents, locked settings) to `durableAtomicWriteJson`, adding file and directory fsync with identical bytes and modes; measure upload and artifact write latency. Approved by the user on 2026-09-25 | S-GW-SMALL-1 | simplification session, 2026-09-25 |
| T-GW-SMALL-2 | Ready | Notifications test audit: classify each spy/call-count assertion as the requirement or setup; rewrite only setup | S-GW-SMALL-1 | |
| T-GW-SMALL-3 | Ready | Providers and protocol test audit; decide whether `pi-image-serialization.test.ts` belongs beside `check-pi-sdk.mjs` | S-GW-SMALL-1 | |
| T-GW-SMALL-4 | Ready | Integrations and client test audit | S-GW-SMALL-1 | |
| T-GW-SMALL-5 | Ready | Workspace and runtime test audit | S-GW-SMALL-1 | |
| S-GW-PROTO-1 | Ready | Scope `protocol/types.ts` against its Swift and TS consumers for unused types and fields | S-GW-SMALL-1 | |
| S-IOS-STATE-1 | Ready | Scope IOS-STATE, `AppModel.swift` first, including its tests in Tests/Gateway | V-0, V-0-UX | |
| S-IOS-CHAT-1 | Ready | Split IOS-CHAT into sub-units (transcript projection, scroll, composer, media, detail sheets); add one row per sub-unit | V-0, V-0-UX | |
| S-IOS-SET-1 | Ready | Scope IOS-SET | V-0, V-0-UX | |
| S-IOS-UI-OTHER-1 | Ready | Scope IOS-UI-OTHER | V-0, V-0-UX | |
| S-IOS-CORE-1 | Ready | Scope IOS-CORE, including AppLog and log export; keep `packages/gateway/docs/observability.md` accurate | V-0, V-0-UX | |
| S-MAC-1 | Done | Scope MAC | V-0, V-0-UX | simplification session, 2026-09-24 |
| C-MAC-DEAD-1 | Done | Delete verified dead Mac code: 8 unused `TronPaths` members, `GatewayPayloadStore+Wrapper.swift` (no production caller; the launcher reads the channel) and its 4 expectations, `MacRuntimeVariant.isReadOnlyDebug`/`isManagedRelease`, `DebugGatewayMenuState.admissionIsPairable`, two unused typography tokens, `LocalComputerName.currentPairingName`, the uncalled `LaunchAgentManaging.isRegistered` and its three implementations, the test-only and uncalled hello checks in `ServerPing.swift` and `GatewayRestartClient.swift`, the unread `Response.scheduled`, and the history narration in `TronMacApp.swift` and `WizardButtonStyle.swift` | S-MAC-1 | simplification session, 2026-09-25 |
| T-MAC-1 | Done | Test audit of Mac Tests/Server and Tests/Support, then collapse the seams no remaining test needs, including the test-only `environment:` overloads in `TronPaths` (`activeProfile(environment:)` ignores its argument, so its test asserts a tautology). At least two changes, each under 800 lines | S-MAC-1 | simplification session, 2026-09-25 |
| T-MAC-2 | Done | Test audit of Mac Tests/Wizard, Tests/MenuBar, Tests/App and the shared fakes | S-MAC-1 | simplification session, 2026-09-25 |
| C-MAC-DEAD-2 | Done | Remove `TronPaths.launchAgentLabel(profile:)` and `defaultServerPort(profile:)` (no production caller after T-MAC-1), the retired-UserDefaults narration at `WizardState.swift:85`, and the unread `"scheduled"` key in `GatewayRestartClientTests.responseDecoding` | T-MAC-1 | simplification session, 2026-09-25 |
| C-MAC-RPC-1 | Ready | One decoder for the `{type,id,ok,result,error}` envelope shared by `MenuBarLogReader.swift`, `ServerPing.swift` and `GatewayRestartClient.swift`; each client keeps its own errors and bounds | T-MAC-1 | |
| C-MAC-SMALL-1 | Done | Use `TailscaleProbe.isIPv6` instead of the 59-line IPv6 validator in `PairingURLBuilder.swift`, pinning the accepted hosts with a negative case; and one private atomic JSON writer for `WizardState.swift`, `OnboardedSentinelWriter.swift` and `MacAppStartupMaintenance.swift`, keeping bytes and modes | S-MAC-1 | simplification session, 2026-09-25 |
| C-MAC-PAYLOAD-1 | Done | Delete the second, injectable payload validation in `ExistingInstallDetector.swift:116-207` in favor of `GatewayPayloadValidator`; the lane says the extra package checks are already covered by the manifest fingerprint. Touches payload validation, so the user sets the equivalence bar. Approved by the user on 2026-09-25 on condition that a test first shows the canonical validator rejects every tampered fixture the removed check rejected | S-MAC-1 | simplification session, 2026-09-25 |
| C-MAC-REDACT-1 | Done | Make `TronLog.redact` call `DiagnosticsRedactor` behind an equivalence corpus. Touches redaction, so the user decides. Approved by the user on 2026-09-25 on condition that a corpus test shows identical output, or strictly more redaction, for inputs from both entry points | S-MAC-1 | simplification session, 2026-09-25 |
| C-MAC-REDACT-2 | Done | Add TronLog's bare key/value patterns (for example `api-key=…`) to `DiagnosticsRedactor`, which widens what feedback exports redact; then C-MAC-REDACT-1 can proceed behind its corpus test. Approved by the user on 2026-09-25 | C-MAC-REDACT-1 | simplification session, 2026-09-25 |
| C-MAC-REDACT-URL-1 | Done | Neither Mac redactor masks URL userinfo (`https://user:password@host`); add it to `DiagnosticsRedactor`, masking the whole userinfo as `[redacted:userinfo]` and keeping scheme, host, port and path, behind a corpus test showing URLs without userinfo are unchanged. Approved by the user on 2026-09-25. Run after T-MAC merges, which edits the same test area | C-MAC-REDACT-1 | simplification session, 2026-09-25 |
| S-MAC-2 | Ready | Scope `Sources/NativeHost` and `Sources/Search` together with MAC-NATIVE | S-MAC-1 | |
| S-MAC-3 | Ready | Scope the payload and launcher contract across `GatewayPayloadStore.swift`, `tron-gateway-launcher.c` and `hash-gateway-payload.sh`, so the fail-closed policy is stated once | S-MAC-1 | |
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
- Changes: this commit (`Tests/Support/TestWatchdog.swift`, Tests/Support/TestWatchdogTests.swift (since deleted by the low-signal test prune)).
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
| Scripts, shell | scripts/tron-dev-toolchain.test.sh, scripts/verify-ci-toolchain.test.sh (since deleted by the low-signal test prune) | pass | about 1 s |
| Mac reinstall tools | `python3 scripts/test-mac-reinstall.py` | 93 tests, 3 skipped | 2 s |
| Launcher | `packages/mac-app/scripts/test-tron-gateway-launcher.sh` | pass | 271 s |
| Mac payload scripts | `test-update-payload-fingerprint.sh`, `test-push-product-config.sh` | pass | under 1 s |
| Push relay | `npx vitest run` in `packages/push-relay` | 6 files, 39 tests | 4 s |
| iOS, full | `scripts/tron-ios-test run` after `build` | 1,889 Swift Testing tests in 139 suites plus XCTest | build 132 s, run 236 s |
| Mac, full | `xcodebuild build-for-testing` then `test-without-building` (TronMac) | 316 tests in 48 suites | build 227 s, run 134 s |

- Not run: test-launchd-relaunch-fixture.sh (since deleted by the low-signal test prune) (opt-in, needs `TRON_RUN_LAUNCHD_FIXTURE=1`), and the payload verifier, npm and signed-payload smoke scripts, which need a staged Mac payload.
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

### C-STRUCT-DELETE-1, C-DOCS-PIN-1, C-COMMENTS-1 · Done · 2026-09-24 · simplification session

- Result: three small cleanups in one change, none of which alters behavior.
  - Deleted the display-smoke fixtures, the one-off Gateway computer-use-image-g0.md report and the unreferenced iOS tron-logo.png.
  - Stale Pi pins now point at `packages/gateway/package.json` instead of naming 0.84.4, and `pi-subagents` is described as runtime-installed (version 0.59.0 today), in the Gateway README, the agent-home inventory, the cutover runbook and the agent-home cutover doc.
  - Fixed the misleading comments: the Mac palette header (it named a nonexistent iOS file and claimed identical values), `PairingURLParser` to `PairingInvitationParser` in the builder and its test, the dangling "plan §A" reference, and history narration in `OnboardingModels.swift`, `catalog-metadata-index.ts` and `tron_wizard_migration.py`.
- Evidence (verified): reference searches for the deleted paths outside `docs/plans/` are empty; no `0.84.4` or `0.59.0` remains in authored docs; the documentation policy check passes; `tsc --noEmit` passes for the Gateway; the migration script compiles. The Mac edits are comments only, so no Mac build was run.
- Changes: this commit.
- Tasks added: none.

### S-BUILD-1 · Done · 2026-09-24 · simplification session (DeepSeek lane, checked by the supervisor)

- Result: build output has no single owner. The iOS test and device scripts default into the worktree (`packages/ios-app/build`), the simulator script and runbooks into `/tmp`, and the Mac developer commands into the global Xcode DerivedData. Agents also invented eight unowned folders. Measured on 2026-09-24: 19.4 GB of build output across worktrees (8.1 GB in the main checkout), 10 GB in the global DerivedData and 9.6 GB of `/tmp/tron-*`. `git worktree remove` fails partway on a worktree that staged the Mac payload, because the bundler's `chmod -R a-w` leaves 4,536 read-only directories, and unlinking an entry needs a writable parent. The plan's other suspect, read-only files in DerivedData, is not a cause: the files are removable while their parents are writable.
- Evidence: `du -sh` per worktree and cache, and `find -perm` counts (verified by the lane); script defaults and overrides at their file:line (inspected); the chmod in `bundle-gateway.sh` (verified by the supervisor).
- Kept on purpose: the iOS test lease lock and ownership marker (they make one shared build root safe), the payload's read-only mode (anti-tampering, together with the launcher fingerprint), and `safe_remove_tree`'s symlink guard.
- Changes: this commit (plan only).
- Tasks added: C-BUILD-1 to C-BUILD-4. A small release script was proposed and not added, because the skill step is enough unless the user wants it automated.
- For the next agent: several merged worktrees under `/private/tmp` and `tron-bounded-restart` still hold about 1.1 GB each. Releasing them is housekeeping (C-BUILD-3's step) and needs their owner's agreement where they are dirty.

### S-GW-SESS-1, S-GW-KNOW-1, S-MAC-1 · Done · 2026-09-25 · simplification session (DeepSeek lanes, checked by the supervisor)

- Result: all three units are mostly load-bearing; the findings are small deletions and deduplication, with no wire, persisted-format or UI change.
  - GW-SESS splits into slot, registry and a set of smaller parts (new S- rows). Only the registry's tests exceed 3,000 lines, so T-GW-SESS-1 stays the one test-audit row.
  - GW-KNOW: the legacy importer is live (iOS dashboard → `knowledge.import*` RPC → importer) and the catalog storage upgrade runs every start and short-circuits on its manifest, so neither is removable now; the upgrade's removal is S-GW-ROOT-1's question.
  - MAC: the 12 Mac events match the `observability.md` catalog exactly.
- Evidence (verified by the supervisor with reference searches): the duplicate receipt validators and the duplicate 256 KiB artifact bound; `projectSkillInvocation`'s re-export used only by `projection.test.ts`; `semantic-notes.ts` imported only by `source-capture.test.ts`; `awaitAbortable` defined and never called; the unreachable store sniffing in `resolveSource`; the 12 unused Mac members, the test-only `GatewayPayloadStore.channel(environment:)`, and `isRegistered` with implementations but no caller. Other rows' counts and line ranges are the lanes' (inspected).
- Kept on purpose (from the lanes' keep lists): the per-session mutation lane, the durable-write retry, the read-only child 64 MiB bound, the frozen real producer fixtures, the runtime lock, presentation presence for idle eviction, knowledge SSRF pinning, observation redaction and bounds, the payload validator, the launchd registration plan, bounded subprocesses and the owner-only credential reader.
- Changes: this commit (plan only).
- Tasks added: S-GW-SESS-SLOT-1, S-GW-SESS-REGISTRY-1, S-GW-SESS-PARTS-1, C-GW-SESS-1, C-GW-KNOW-1 to C-GW-KNOW-4, T-GW-KNOW-1, S-GW-KNOW-2, C-MAC-DEAD-1, T-MAC-1, T-MAC-2, C-MAC-RPC-1, C-MAC-SMALL-1, C-MAC-PAYLOAD-1 and C-MAC-REDACT-1 (both need approval), S-MAC-2, S-MAC-3. The lane's Wizard and menu bar UI scoping waits on V-0-UX and is not a row yet.
- For the next agent: the user reaffirmed that the program should remove all over-engineering and all unnecessary tests; the test bar and finding types above are how that is judged.

### C-GW-SESS-1, C-GW-KNOW-1, C-GW-KNOW-2, C-MAC-DEAD-1, C-BUILD-1 to C-BUILD-4 · Done · 2026-09-25 · simplification session (GPT-6 Luna lanes, reviewed by the supervisor)

- Result: dead and duplicated code removed with no behavior change, and build output given owners.
  - Sessions: the notification receipt now uses the invocation receipt's validators (`validText` gained the notification's newline allowance; `validOrigin`'s key and bound checks were already identical); one `MAX_EXTENSION_ARTIFACT_BYTES` in `extension-run-projection.ts`; the `RuntimeSlot` doc is on its class; the test-only `projectSkillInvocation` re-export and five own-file-only exports are gone. `RuntimeSlotDependencies` stays exported: the registry imports it.
  - Knowledge: `semantic-notes.ts` deleted, its test rewritten against the store APIs; the unreachable store sniffing in `resolveSource`, `awaitAbortable`, the `JEV_REQUEST_MODEL` alias, two needless exports and the `KnowledgeTable` interface removed.
  - Mac: every C-MAC-DEAD-1 item removed; `ServerPingTests` now asserts the same hello fixtures against the live `GatewayWebSocketTransport.validHello`.
  - Build: `scripts/tron-ios-test` and `scripts/tron-ios-simulator` default to the per-user root `$HOME/Library/Developer/Tron/ios` (`test-derived-data`, `test-runs`, `simulator-derived-data`); all overrides kept. Device builds stay in the worktree. The housekeeping skill now unlocks the staged payload before plain `git worktree remove`. The TronMac commands in `AGENTS.md`, `CONTRIBUTING.md`, the README and the Mac development doc use `-derivedDataPath build/DerivedData`. C-BUILD-2 removed the six unreferenced Sept 21 folders under `packages/ios-app/build` (accessibility-runs, development-derived-data, followup-runs, nonhosted-derived-data, ui-test-derived-data, ui-test-runs; about 4 GB).
- Evidence (verified): full Gateway suite on the combined `main`: 179 files, 1,949 tests, 83 s (V-0: 80 s); `tsc --noEmit` passes. Full Mac suite on the Mac branch: 316 tests in 48 suites. One `scripts/tron-ios-test build` into the new root. The rewritten knowledge note test fails when `updateNote` is disabled (negative control). Reference searches for every deleted symbol and folder are empty outside `docs/plans/`.
- Supervisor corrections to the build lane: reverted an unrequested device DerivedData rename, which had left `packages/ios-app/docs/development.md` naming the old folder; moved the simulator default to the shared root instead of into each worktree; fixed the housekeeping step numbering.
- Kept on purpose: `packages/ios-app/build/test-derived-data` and `test-runs` in the main checkout (the old defaults, last written today by another session; release them once no session runs the old script) and `prose-reflow-preview` (another session's, created today).
- Changes: this series of commits.
- For the next agent: never symlink a worktree's `packages/gateway/node_modules` to the main checkout's when that worktree builds the Mac app. `bundle-gateway.sh` runs `npm ci` in `packages/gateway` (line 262), which emptied the shared tree through the link during this run; the supervisor restored it with `npm ci`. Symlinking is fine for Gateway-only lanes.

### T-GW-SESS-1 · partial · 2026-09-25 · simplification session

- Result: the first pass mapped all 242 tests but kept 241 on title-derived requirements; it only rewrote `orders startup phases and acquires one structural evidence cut` to assert phase order instead of a private method's call count (focused file 242 tests, 43 s before, 49 s after). That is not a test-bar audit, so the row stays claimed for a body-level second pass that compares test bodies for duplicate protection.

### T-GW-SESS-1 · Done · 2026-09-25 · simplification session (GPT-6 Luna lanes, checked by the supervisor)

- Result: `runtime-registry.integration.test.ts` is mostly load-bearing. A body-level pass by four read-only lanes (one per quarter of the file) found three tests whose protection another test already asserts, now deleted; 239 remain. It also flagged 64 tests that use private methods, fields or call counts; they are T-GW-SESS-2, not deletions.
- Deleted, with the surviving coverage (verified by reading both bodies):
  - `announces a final successful Pi settlement through the inline notification hook` → `runtime-terminal-notifications.integration.test.ts` `notifies exactly once for final %s, after its canonical terminal receipt` asserts the same `agent_finished` payload for `stop`, plus exact-once and terminal-receipt ordering.
  - `emits exact removals when process producer identity is replaced` → `keeps process overview active while an async workflow child awaits producer identity` asserts `removedProcessIds` for the replaced process.
  - `still rejects distinct genuine launch owners for the same delegated run` → `binds artifact refresh to the canonical run directory and keeps admission time authoritative` asserts the same ambiguous, ownerless run fact.
- Flagged for T-GW-SESS-2 (line numbers as of `62745629a`). Chunk 1: 636, 660, 718, 750, 1065, 1411, 1438, 1535, 1590, 1714, 1845, 1875, 1971. Chunk 2: 2160, 2184, 2204, 2225, 2247, 2431, 2508, 3130, 3393. Chunk 3: 5081, 5145, 5239, 5642, 5755, 5835, 6032, 6078, 6150, 6257, 6358, 6472, 6869, 6930, 6947, 6999, 7036, 7063, 7284, 7368, 7404, 7640, 7776, 7800, 7821. Chunk 4: 8105, 8256, 8353, 8411, 8579, 8688, 8744, 8791, 8868, 9561, 9660, 10043, 10063, 10105, 10537, 10597, 10622.
- Evidence (verified): the focused file has 239 tests passing in 41 s (242 in 43 s before); `tsc --noEmit` passes. No production code changed. The first pass's rewrite of `orders startup phases…` (landed earlier) remains.
- For the next agent: the lanes' rewrite suggestions are unreliable where a count is the protected bound; read the test body before accepting any of them.

### C-GW-KNOW-3, C-GW-KNOW-4, C-COMMENTS-REFCHECK-1, C-MAC-REDACT-1 · 2026-09-25 · simplification session (GPT-6 Luna lanes, reviewed by the supervisor)

- C-GW-KNOW-3 (done): `isCredentialQueryKey` and `normalizeKnowledgeSourceUrl` in `knowledge-contract.ts` replace four and two copies. The lane first adopted `xPostIdentity`'s substring rule for everyone, which would have refused ordinary keys such as `author` or `session_id` at capture, import and persisted-record validation; the supervisor restored the exact list the three admission sites used, and `xPostIdentity` keeps its broader rule inline. A table test pins both refused and ordinary keys.
- C-GW-KNOW-4 (done): `InMemoryConnectorCredentialStore` now lives in `packages/gateway/test-support/connector-credentials.ts`, outside `src`, and `dist` no longer contains it (verified by a build).
- C-COMMENTS-REFCHECK-1 (done): `check-documentation-policy.py` now checks backticked repository paths in source comments (TS/JS, Swift, Python, shell, C), about 0.1 s slower. Negative control: re-adding the old Mac palette reference fails the check. The supervisor added scripts/test-documentation-policy.py (since deleted by the low-signal test prune) to CI, which the lane had left unwired. The check found no other stale paths.
- C-MAC-REDACT-1 (blocked): the corpus test showed `DiagnosticsRedactor` leaves bare `api-key=…` values that `TronLog.redact` masks, so merging would weaken log redaction. Nothing changed; C-MAC-REDACT-2 asks the user whether to widen the exporter first.
- Evidence (verified): full Gateway suite on combined `main` 179 files, 1,968 tests, 81 s; `tsc --noEmit` passes; documentation policy tests pass.

### S-DEAD-1, S-GW-TRANS-1, S-GW-EXT-1, S-GW-AUTO-1 · Done · 2026-09-25 · simplification session (GPT-6 Luna lanes, checked by the supervisor)

- Result: transport, extensions and automations are nearly all load-bearing. Extensions has no finding; transport has one test-only export (C-GW-TRANS-1) and a 12,819-line test corpus for a separate audit (T-GW-TRANS-1); automations has one test-only export and one call-count assertion (T-GW-AUTO-1). S-DEAD-1 covered only Gateway file-local unused symbols (C-DEAD-1); the rest is S-DEAD-2.
- Not adopted: the automations lane's proposal to drop the service-level timeline-window validation, because it would change when a bad window is rejected for a saving of one line.
- Kept on purpose (lanes' keep lists): command receipts, transcript leases, server admission and frame bounds, logger redaction and retention, diagnostic export bounds, extension registration admission and the exact ask-user package check, presentation epochs, automation storage modes, bounds, recovery without replay, and DST handling.

### C-DEAD-1, C-GW-TRANS-1, T-GW-AUTO-1 · Done · 2026-09-25 · simplification session (GPT-6 Luna lane, reviewed by the supervisor)

- Result: five unused Gateway declarations removed; `diagnosticExportPolicy` and `MAXIMUM_TIMELINE_RAW_OCCURRENCES` are module-private. The diagnostic export test now asserts the 512 KiB limit at the boundary (one byte under succeeds, one over fails) and that the ten newest exports are retained; the timeline test's constant-positivity assertion is gone.
- The scheduler test's `store.snapshot` call count (3) is removed. It guarded the 2026-09-13 change that made `arm()` read one snapshot instead of two, but the total also counted the scan's own reads, so any correct scan refactor broke it; the saving is one in-memory copy, not a resource bound. The test now asserts only the 60-second timer cap.
- Evidence (verified): full Gateway suite on combined `main` 179 files, 1,968 tests; `tsc --noEmit` passes; reference searches for each removed symbol empty.

### C-MAC-PAYLOAD-1, C-MAC-SMALL-1, C-MAC-REDACT-1, C-MAC-REDACT-2 · Done · 2026-09-25 · simplification session (GPT-6 Luna lane, reviewed by the supervisor)

- C-MAC-PAYLOAD-1: `ExistingInstallDetector.validateGatewayPayload` now only calls `GatewayPayloadValidator`; its second, injectable check is gone. The user's proof condition is met by `canonical validation rejects each payload tamper rejected by install detection`: each of 18 tamper cases (manifest, entrypoint size, package files, `node_modules`, the seven dependency manifests with the fingerprint left as computed, helper scripts, and both Node runtimes too small or not executable) starts from a fixture that first validates successfully, then fails validation. The lane's first proof used a fixture that failed on its fingerprint regardless; the supervisor sent it back.
- C-MAC-SMALL-1: `PairingURLBuilder` uses `TailscaleProbe.isIPv6`, with explicit refusals for embedded IPv4 and `%`-scoped addresses, which `inet_pton` accepts and the old validator rejected. `AtomicFileWriter` replaces three copies of the temp-file-and-replace write; the onboarding sentinel and version marker are now 0600 rather than umask 0644 (stricter; same-user readers only, and the wizard migration accepts either).
- C-MAC-REDACT-2 (approved by the user): `DiagnosticsRedactor` now also masks bare and quoted `authorization`, `api-key`, `access-token`, `refresh-token`, `password`, `secret` and `token` values, and Bearer tokens with punctuation.
- C-MAC-REDACT-1: `TronLog.redact` calls `DiagnosticsRedactor`. A corpus test asserts it masks every case the old log rules masked and leaves plain text unchanged. `mac.jsonl` event names and fields are unchanged; its placeholders are now `[redacted:len=N]` and `[redacted:path]`, and paths under `/tmp`, `/var`, `/Volumes` and `/Applications` are also masked. Nothing in the repository reads the old placeholders.
- Evidence (verified): full Mac suite 318 tests in 48 suites; focused payload, redactor, feedback and log suites 33 tests; reference searches for the removed validator and IPv6 helpers empty.
- Tasks added: C-MAC-REDACT-URL-1 (needs approval): URL userinfo credentials pass through both redactors.

### C-DOCS-GW-1, C-DOCS-OWNER-1 · Done · 2026-09-25 · simplification session (DeepSeek lane, reviewed by the supervisor)

- Result: `packages/gateway/docs/session-search.md` and `packages/gateway/docs/knowledge.md` own session search and knowledge bounds; the Gateway README links to them. CONTRIBUTING's repository map owns the retired-architecture list, the iOS development doc's Build matrix section the iOS configurations, the Mac development doc's Efficient focused tests section the TronMac commands, and AGENTS.md the documentation-ownership list. Every fact that existed only in a removed copy was moved to its owner; the supervisor restored "event journals" to the retired list. README is 182 lines. The documentation policy check passes.

### T-GW-TRANS-1, S-GW-MACH-1, S-GW-ADMIN-1, S-GW-DISP-1, S-GW-SMALL-1 · Done · 2026-09-25 · simplification session (DeepSeek lanes, checked by the supervisor)

- T-GW-TRANS-1: body-level map of all 32 transport test files (226 tests): 5 deletions, 6 merges and 6 rewrites; everything else protects a bound, ordering, idempotency, revocation or durability requirement. The supervisor confirmed `releaseOwnedSubscription` has no production caller and `encodeOutboundFrame` is used only by `server-frame.test.ts`, and that the thumbnail-receipt test cannot fail because a URL-less refresh has no effect. Applied by C-GW-TRANS-2.
- Scopings: machine, display, admin and the small modules are mostly load-bearing (keep lists in the lanes' outputs: upload durability and quotas, worktree ownership proofs, native-capture identity binding, artifact integrity and bounds, HMAC browser references, device-store and secure-JSON boundaries). Findings became C-GW-MACH-1, C-GW-DISP-1, C-GW-ADMIN-1 and C-GW-SMALL-1, plus five rows that need the user.
- Live compatibility found and kept (persisted formats; removal needs the user): upload metadata v1 migration, the pre-inbox notification document, device `lastSeenAt` legacy acceptance, the workspace marker v1, historical multiline update failures, and the connection-migration CLI (S-GW-ROOT-1).

### T-GW-KNOW-1, T-MAC-1, T-MAC-2, C-GW-TRANS-2, C-GW-MACH-1, C-GW-DISP-1, C-GW-ADMIN-1, C-GW-SMALL-1 · Done · 2026-09-25 · simplification session (DeepSeek v4.1 Flash lanes, reviewed by the supervisor)

- T-GW-KNOW-1: all knowledge tests map to a requirement; no deletion met the rule. Nine real-time waits became fake-clock advances (about 1.3 s of sleeps gone); one timing-based test was rewritten to prove non-replay positively. `connectors.test.ts:239` waits on abort, not time. `knowledge-catalog.test.ts` paging stays because `vitest.config.ts` excludes the scale test from the default run.
- T-MAC-1/2: `TronPaths`'s environment-injection overloads are gone (no production caller passed a non-default environment) and `activeProfile` is the constant it always was. Deleted `tightPermissionsAccepted` (identical to `validJSONObject`) and `explicitHostBuildsSocketURL` (covered by `ServerPingTests.socketURLSupportsIPv6`); merged two identical startup-repair tests; the enrollment test now exercises expiry and permissions separately; two sleeps became signals. Mac suite 316 tests (318 − 3 + 1).
- C-GW-TRANS-2: the transport map applied as mapped: 5 deletions, 6 merges, 6 rewrites; `releaseOwnedSubscription` (dead) and the test-only `encodeOutboundFrame` are gone, with framing boundaries now asserted at the wire.
- C-GW-MACH-1: two deletions (constant-only listing test → `rejects directory listings above the bounded entry ceiling`; node-pty chmod test → `repairs execute permission on Darwin`), three rewrites off private state, 20 needless exports and the redundant replay clamp removed, `CuaComputerClient` built from its binding only, and one listing-bound module, containment predicate and fsync helper in `machine/`.
- C-GW-DISP-1: a new ingest test covers NUL anywhere in a text artifact, including past the 4 KiB prefix; never-set store options and the test-only `initialize` filter are gone (the startup empty-owner cleanup stays, now with its own test); one schema constant, artifact-ID pattern, kind list and bounded-text predicate; 11 exports removed. Found C-GW-DISP-UTF8-1.
- C-GW-ADMIN-1: `admin/document-admission.ts` owns failure-text, trusted-directory (every check and message preserved; supervisor compared both), timestamp and command-ID rules; the update service has one atomic writer with identical bytes; the stale comment is fixed; auth-broker and global-resource tests no longer sleep; 6 setup-only `activeOperationCount` assertions and 2 test-only exports removed, the other 7 exports kept with their reason.
- C-GW-SMALL-1: dead barrel, `ProtocolEvent`, the one-line MCP factory and empty capabilities block, and 8 exports removed; one local-credential validator (the supervisor confirmed it is identical to the client's old check, and it now also rejects impossible dates); the shutdown-step clock is gone; `featureInitialized` reads its writer's key. `retainedKeyCount` and the mutex queue assertion stayed (C-GW-SMALL-SEAMS-1).
- Supervisor fix: `sync-protocol.integration.test.ts` "converges an overflowed catch-up…" raced its own socket under load (asserted the recovered event before waiting for it; 1 of 3 runs failed under load, 0 of 6 unloaded before and after the merge). The bounded wait now covers both frames; 8 of 8 passes.
- Evidence (verified): full Gateway suite on combined `main` 179 files, 1,964 tests, 79 s; `tsc --noEmit` passes; each lane's negative controls are in its output.

### C-GW-DISP-UTF8-1, C-GW-SMALL-SEAMS-1, C-GW-DISP-PIN-1 · Done · 2026-09-25 · simplification session

- C-GW-DISP-UTF8-1: a text display artifact with invalid UTF-8 now fails with `invalid_request` ("Display text artifacts must contain valid UTF-8 text without NUL bytes") instead of the decoder's `ERR_ENCODING_INVALID_ENCODED_DATA`; nothing is published either way. Negative control: with the old check restored, the test fails on the decoder error.
- C-GW-SMALL-SEAMS-1: `RateLimiter.retainedKeyCount` and the mutex test's `waiting` assertion stay, each with a comment naming the bound it is the only witness for.
- C-GW-DISP-PIN-1: kept. The agent home's `settings.json` names `pi-agent-browser-native@d6cde09a…`, so the pinned trust entry is live.
- Evidence (verified): focused display, rate-limiter and mutex tests 21 of 21; full Gateway suite passes.

### C-GW-ADMIN-3, C-GW-ADMIN-4, C-GW-SMALL-2, C-GW-SMALL-RESTART-1, C-MAC-REDACT-URL-1, C-MAC-DEAD-2 · Done · 2026-09-25 · simplification session (DeepSeek v4.1 Flash lanes, reviewed by the supervisor)

- C-GW-ADMIN-3: the update service reads only `candidateIdentity`; `git log -S` confirms the deploy script never wrote the flat shapes. No test covers the removed branches because no fixture ever produced them.
- C-GW-ADMIN-4: `readActiveInstall()` is the one reader of `active.json`. A document declaring any schema other than 2 is cleared through the existing cleanup, so it no longer blocks `activeStatus()`, install, `bindTarget()` or the `gateway.update`/`gateway.rollback` gate; a malformed schema-2 document still fails closed and is left in place. Negative control: without the fix the new test fails at the `gateway.update` gate.
- C-GW-SMALL-RESTART-1: `client/restart-gateway.ts` deleted; nothing referenced it.
- C-GW-SMALL-2: `durableAtomicWriteJson` is the only JSON publisher and `atomicWriteJson` is gone. Bytes (2-space JSON plus newline), mode 0600 and the temp-file name pattern are unchanged, verified on five document shapes. Measured over 200 writes: upload metadata unchanged; artifact metadata about +4 ms median (under the 5 ms bar), because it gains the directory fsync it lacked. A new test fails when that directory sync fails.
- C-MAC-REDACT-URL-1: `DiagnosticsRedactor` masks `scheme://userinfo@` as `[redacted:userinfo]` before its other passes, so the Mac log and feedback exports both mask it; scheme, host, port, path and query stay. The corpus covers user:pass, user only, percent-encoded passwords, IPv6 with a port, and a later path mask; plain emails, URLs without userinfo and `mailto:` are unchanged. Mac architecture doc updated. Negative control: 7 assertions fail without the pass. Known edge (errs toward more redaction): a `?` or `#` before an `@` in the authority is also treated as userinfo.
- C-MAC-DEAD-2: the two profile-scoped `TronPaths` pass-throughs are deleted, the WizardState comment rewritten, and the unread `"scheduled"` key removed from `responseDecoding`. Unknown-key tolerance stays proven by `matchingCanonicalResponseProjectsVersion`.
- Evidence (verified): full Gateway suite on combined `main` 179 files, 1,967 tests; full Mac suite on the Mac branch 319 tests in 48 suites; documentation policy exit 0.
