# iOS test execution and simulator consolidation plan

Status: Implemented in this worktree, but not accepted. The real E2E and CI gates remain maintainer-owned, and the full unit checkpoint currently exposes product-test failures recorded below; no completion claim is made.

## Objective

Make iOS development and test execution deterministic, bounded, minimal, and easy to operate:

- routine failed tests must return a normal `xcodebuild` failure instead of hanging after the Swift Testing summary;
- every simulator action must target one exact owned device and supported runtime;
- development app state must never share a lifecycle with hosted tests;
- one canonical runner must own routine unit-test behavior across local agents and CI;
- UI E2E, physical-device, release, policy, and artifact-validation scripts must retain only their distinct responsibilities;
- stale aliases, unused generators, duplicate orchestration, and conflicting command documentation must be removed;
- no simulator test may depend on an Apple account, iCloud state, production credential, remembered Gateway pairing, or another user's app data.

The work is a staged consolidation, not a big-bang rewrite. Add the safe owner, migrate callers, prove parity, and only then delete the replaced surface.

## Non-goals

- Do not change the open tool-detail presentation work.
- Do not recreate a test scheduler, event journal, simulator database, or another build system.
- Do not automate a production archive, upload, release, deployment, Gateway rebuild, or Gateway restart.
- Do not erase the persistent Development simulator, a physical device, application data, or Keychain data.
- Do not infer test success from console text. The `xcodebuild` exit status and finalized result bundle remain authoritative.
- Do not paper over a product test failure with a retry. Infrastructure retry may occur only after an explicitly classified infrastructure failure and must preserve the first attempt's evidence.

## Confirmed failure chain

The repeated post-summary hang is an Xcode failure-path problem, not a Pi transcript problem:

1. Swift Testing finishes and prints `Test run with … failed`.
2. The generated hosted-test run has `DiagnosticCollectionPolicy = 1`.
3. Xcode begins verbose failure diagnostics before finalizing the xcresult and printing `TEST EXECUTE FAILED`.
4. Simulator/test-management diagnostic collection intermittently stalls.
5. `xcodebuild` remains alive, so Bash and Pi correctly keep waiting.

Stored session evidence contains 32 verified failed summaries followed by manual abort; every command used the default diagnostic policy. Twelve failed runs using `-collect-test-diagnostics never` all reached `TEST EXECUTE FAILED`, including presentation-guard and `TestWatchdogExpired` failures. Routine diagnostics must therefore be disabled at the test plan and command boundaries.

Additional conditions amplify the failure:

- name-only destinations can resolve among multiple `iPhone 17 Pro` devices and runtimes;
- the currently booted match can be a long-lived beta runtime with a stale `testmanagerd`;
- `TronMobileTests` launches the full application host, whose normal scene startup creates notification, Gateway, event-stream, and other long-lived work;
- current scripts have no process-level deadline covering Xcode teardown and result finalization;
- development and hosted-test execution are conflated in `scripts/tron-ios-simulator check-affected`;
- Swift test watchdogs are cooperative and cannot forcibly terminate a blocked framework operation.

`testmanagerd` SIGTERM-timeout reports prove simulator teardown instability, but do not alone prove a hang: the same report class can occur immediately before a clean `xcodebuild` exit. AVFoundation imports, Pi pipe draining, and one particular test suite are not established universal causes.

## Canonical ownership

| Truth | Canonical owner | Rule |
|---|---|---|
| Build configurations and schemes | `packages/ios-app/project.yml` plus checked-in test plans | Generated Xcode projects and `.xctestrun` files are disposable projections. |
| Apple toolchain versions | `config/ci-toolchain.env` | CI-test, local-test, and release purposes must be explicitly named; no duplicate version literal in scripts or prose. |
| Local Development simulator | `scripts/tron-ios-simulator` | Persistent user-owned app iteration only; no hosted tests. |
| Routine unit-test execution | one canonical iOS test runner | Local focused runs and CI checkpoints share destination, diagnostics, timeout, log, result, and exit semantics. |
| Real-Gateway UI E2E | `scripts/ios-gateway-e2e-test` | Owns only the isolated Gateway fixture and E2E scenario; delegates simulator/process mechanics. |
| Physical development device | `scripts/tron-ios-device` | Remains separate because signing, device discovery, protocol verification, and overwrite install are distinct safety boundaries. |
| Release toolchain validation | one explicit manual release doctor | It must be called and documented or deleted; syntax-check-only existence is not ownership. |
| Artifact metadata validation | `scripts/validate-ios-artifact.py` | Device and archive paths call the same validator. |
| Archive privacy validation | `packages/ios-app/scripts/verify-archive-privacy.sh` | Archive-only; no simulator behavior. |
| Source/build matrix policy | package-owned policy scripts | Static/generated-project checks remain separate from runtime orchestration. |
| Contributor procedure | `packages/ios-app/docs/development.md` | Other docs summarize and link; they do not copy raw `xcodebuild` recipes. |
| Agent routing | `.agents/skills/tron-ios/SKILL.md` | It names canonical commands and stop rules, not a second implementation manual. |

## Minimal simulator topology

Keep two persistent roles locally and no persistent CI simulator:

### 1. Development simulator

- One explicit user-selected and remembered UDID.
- Runs `Tron Development` with `Development` and bundle `com.tron.mobile.beta`.
- Preserves pairing, app container, and Keychain state.
- May be started, installed, launched, inspected, or stopped only by the Development simulator owner.
- Must never run unit tests, UI tests, E2E tests, or test cleanup.
- Must never be deleted or erased by repository automation.

### 2. Test simulator

- One repository-owned local UDID with an ownership marker, or one newly created CI-job UDID.
- Uses the exact supported test runtime and device type from canonical toolchain resolution.
- Runs hosted unit tests and UI E2E serially under one exclusive lease.
- Contains no user Apple account, personal data, production credential, or retained Development pairing.
- Local execution may retain it for build/test speed, but runtime/toolchain drift retires only this repository-owned test device.
- CI creates it for the job and deletes only that exact owned device in a final trap.
- UI E2E resets its own app state and Gateway fixture before each run. A third persistent simulator is not justified unless measured parallel execution later requires one; a parallel job may create another disposable test device rather than broadening local topology.

Physical devices remain outside this topology.

### Destination contract

Normal execution always uses:

```text
platform=iOS Simulator,id=<exact-udid>
```

Name-only or `OS + name` matching is allowed only inside provisioning code that resolves exactly one runtime and device type, creates or selects a device, validates its ownership and runtime, records the UDID, and then passes the ID to Xcode. A missing, duplicated, unavailable, wrong-runtime, or Development-owned destination fails before build/test execution.

The runner must record the selected Xcode version/build, simulator runtime/build, device type, UDID hash or non-personal run identity, boot state, and DerivedData/result locations. It must not persist CoreSimulator paths or personal labels in source.

## Canonical unit-test runner

Introduce one routine test owner, either by evolving `scripts/ios-ci-test.sh` behind a neutral local/CI interface or by adding `scripts/tron-ios-test` and making the CI script a thin adapter. It owns:

- pinned toolchain verification;
- exact test-simulator provisioning and exclusive locking;
- `xcodegen generate` through the pinned XcodeGen resolver;
- one explicit DerivedData root per lane;
- build-for-testing and test-without-building phases;
- repeated `--only-testing` selectors without shell-generated command fragments;
- serial execution by default;
- unique full output logs and result bundles;
- diagnostic policy;
- process-level deadlines and signal handling;
- xcresult summary extraction;
- stable exit codes for build failure, test failure, timeout, destination failure, and runner failure;
- CI artifact publication inputs;
- cleanup of only runner-owned temporary state.

Required modes:

```text
prepare/checkpoint     provision, generate, build, and run the complete unit target
build                  provision, generate, and build-for-testing
run --only-testing …   reuse products and run focused owners
status                 report toolchain, owned simulator, lock, products, and last result
clean                   remove only test-owned simulator state, DerivedData, and results
diagnose …              explicit opt-in rerun with verbose diagnostics and a larger bound
```

Names may change during implementation, but there must be one documented human/agent surface and one internal process owner. CI must invoke the same core rather than maintain a divergent command body.

## Diagnostic policy

Routine unit and UI test plans set:

```json
"diagnosticCollectionPolicy": "Never"
```

Every routine `xcodebuild test…` command also passes:

```text
-collect-test-diagnostics never
```

The checked-in plan is canonical behavior for Xcode and generated schemes; the CLI flag is defense in depth for direct and `.xctestrun` execution. Routine runs still preserve assertion output, the ordinary xcresult, and full console logs.

Verbose collection is available only through an explicit `diagnose` mode. That mode:

- uses the owned test simulator, never the Development simulator or a physical device by default;
- uses a unique result/log directory;
- states that sysdiagnose/log archives may be slow;
- has a larger but finite process deadline;
- captures the process tree before termination;
- never runs automatically as a retry of a product failure.

Remove direct numeric edits such as `DiagnosticCollectionPolicy = 0` from generated `.xctestrun` files once the test plan and explicit CLI policy cover the same boundary. E2E may continue patching fixture environment into its generated run file, but no other policy belongs in that patcher.

## Process deadline and hang evidence

Per-test XCTest/Swift Testing timeouts do not cover Xcode teardown. All build and test subprocesses must run through one process owner that:

1. creates a separate process group;
2. streams stdout/stderr while preserving a complete log;
3. tracks overall and no-output deadlines appropriate to build, focused test, full test, and E2E modes;
4. on expiry captures bounded `ps` trees and short samples of `xcodebuild`, the test host, and relevant test-management processes;
5. records the simulator/runtime identity and partial result-bundle state;
6. sends TERM to the owned process group, waits a bounded grace period, then sends KILL;
7. returns a distinct timeout code and never rewrites it as a test pass/failure;
8. preserves evidence for CI upload and local inspection.

Do not add a dependency on GNU `timeout`. Prefer one small repository-owned process helper with fixture tests for process groups, silent children, signal forwarding, output streaming, deadline classification, and interrupted cleanup.

Xcode per-test timeout flags and `withTestWatchdog` remain useful secondary bounds. Test-owned tasks must still cancel and join, and every hosted waiter must release continuations, display links, observers, windows, and other resources on cancellation. They do not replace the process owner.

## Hosted test application

The `HOSTED_TEST` application entry must be inert:

- install only the minimum root required for the test bundle and hosted view probes;
- do not configure push callbacks, clear badges, start `AppModel`, reconcile push state, connect a Gateway, prune artifacts, or start ambient production tasks from the app scene;
- let tests instantiate the precise model/view owners they exercise;
- keep UI E2E on the `Development` app path, where its launch argument owns test-state reset.

Add a focused guard proving hosted-test startup cannot create production transport, notification, background-checkpoint, dashboard-pool, or artifact-pruning work.

## Script disposition

### Retain and harden

- `scripts/ios-ci-test.sh`: canonical CI adapter to the shared unit-test runner; no independent destination or process logic.
- `scripts/tron-ios-simulator`: Development app lifecycle only.
- `scripts/ios-gateway-e2e-test`: unique Gateway fixture/E2E owner; share simulator, lock, toolchain, timeout, log, and result primitives with the unit runner.
- `scripts/tron-ios-device`: physical-device safety owner; keep signing/protocol/install logic separate.
- `scripts/tron-ios-device-test`: hardware-free contract tests for the physical helper.
- `scripts/install-ci-tools.sh` and `scripts/verify-ci-toolchain.sh`: shared pinned tool installation and verification.
- `scripts/validate-ios-artifact.py` and its fixture test: sole artifact metadata/protocol validator.
- `packages/ios-app/scripts/test-source-policy.sh`: source/resource/generated-project policy.
- `packages/ios-app/scripts/test-build-matrix-policy.sh`: configuration/scheme matrix policy, extended to require the canonical test plan.
- archive privacy verifier and fixture test: archive-only ownership.
- `scripts/validate-push-service-config.sh` and protocol-contract verification: shared cross-product boundaries, not simulator helpers.

### Consolidate or remove after caller migration

- Remove `check-affected` and `iterate` test orchestration from `scripts/tron-ios-simulator`; a convenience command may delegate to the canonical test runner but cannot reimplement it.
- Replace raw local/agent `xcodebuild` recipes with canonical runner commands.
- Keep `scripts/tron ios generate` only if it delegates through the pinned XcodeGen resolver. Otherwise fold generation into the canonical commands and remove the duplicate public route.
- `scripts/ios-release-toolchain-doctor.sh` must become a documented manual release gate with fixture/self-tests or be removed and folded into the shared toolchain verifier. Its current syntax-check-only CI presence is not sufficient.
- `scripts/generate-ios-icons.mjs` has no external caller. Either give it explicit asset ownership, deterministic verification, a documented command, and a tested dependency path, or delete it together with dependencies used only by it. Checked-in outputs alone do not justify an orphan executable.
- Remove stale legacy scheme/configuration compatibility from `scripts/tron-ios-device` after the sole bounded external harness no longer requires it. Until then it remains isolated, tested, absent from normal help, and documented as a compatibility exception rather than a second workflow.
- Delete no script solely because it is infrequently invoked. Deletion requires zero live callers, replacement of unique safety checks, updated CI/docs/tests, and a repository-wide reference scan.

## Instruction consolidation

After migration:

- `packages/ios-app/docs/development.md` owns the detailed workflow and troubleshooting.
- `.agents/skills/tron-ios/SKILL.md` contains only routing, canonical commands, artifact authority, and stop rules.
- `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, and `packages/ios-app/README.md` contain short summaries and links. They do not embed destination strings or multi-line raw Xcode test commands.
- CI calls canonical scripts and contains no duplicate simulator/runtime policy.
- script `--help` text describes only behavior that script owns.
- historical plans may retain historical commands only when clearly marked non-canonical; active plans and performance instructions use the canonical runner.
- `.codex/environments/environment.toml` remains the bounded untouched external compatibility input required by repository policy; normal source and guidance must not copy its retired names.

Add a policy test that scans active scripts and documentation for:

- name-only simulator destinations outside the provisioning owner;
- routine test commands missing diagnostics-off and the process owner;
- retired scheme/configuration names outside the compatibility allowlist;
- references to deleted scripts;
- duplicated Apple toolchain version literals;
- raw focused-test recipes outside the canonical development owner.

## E2E hardening

The E2E fixture remains persistent only for an explicit local iteration lease. Add:

- an atomic lock covering fixture, DerivedData, test simulator, and result path;
- traps that stop owned Gateway work and release the lock on normal exit, interrupt, or timeout;
- stale-lock recovery only when the recorded owner is dead and every path/identity matches the current user-owned fixture;
- exact test-simulator UDID validation;
- unique result bundles per attempt with a stable `latest` reference outside the bundle;
- bounded build and run phases through the shared process owner;
- no numeric diagnostic-policy mutation in `.xctestrun`;
- environment patching limited to the fixture values that XCTest cannot receive through the ordinary plan;
- `stop` that removes fixture state but preserves test products, and `clean` that removes only E2E/test-owned artifacts;
- no shared state with the Development simulator or a real Gateway profile.

## CI behavior

The iOS job must:

1. select and verify the canonical test Xcode and runtime;
2. provision one exact disposable test simulator;
3. install/verify pinned XcodeGen;
4. run source, matrix, agent, artifact, and archive-verifier policy checks;
5. run the shared full unit checkpoint with diagnostics disabled and serial execution;
6. always upload the full log, metrics, xcresult or partial bundle, and timeout evidence;
7. delete only its owned simulator in an unconditional final step.

The workflow should not duplicate destination construction. A CI runtime pin that exists in the manifest but is not the runtime of the selected simulator is a hard failure.

## Implementation sequence

### Phase 0 — freeze and characterize

- Record current scripts, references, help output, CI callers, test-plan projection, and known hang evidence.
- Add no deletion in this phase.
- Decide the one supported stable test Xcode/runtime pair and update the canonical manifest before changing destinations.

### Phase 1 — stop the known hang

- Add checked-in unit/UI test plans with diagnostic collection set to Never.
- Attach them through `project.yml` and guard generated schemes.
- Add `-collect-test-diagnostics never` to every routine runner.
- Add a focused regression using an intentionally failing fixture test and require a normal nonzero Xcode footer within the bound.

### Phase 2 — simulator provisioning and process ownership

- Implement exact owned test-simulator provisioning, validation, locking, and cleanup.
- Implement the shared process owner and hardware-free fixture tests.
- Change unit and E2E execution to exact UDIDs and unique result/log paths.

### Phase 3 — canonical unit runner

- Move local focused and CI full-suite orchestration into one core.
- Make `ios-ci-test.sh` a thin CI adapter.
- Remove test execution from the Development simulator helper.
- Add stable status and clean commands.

### Phase 4 — inert hosted app and E2E migration

- Make `HOSTED_TEST` startup inert and add focused guards.
- Move E2E onto the shared test-simulator/process primitives.
- Preserve its unique Gateway fixture and environment injection only.

### Phase 5 — script and instruction cleanup

- Migrate CI, skill, AGENTS, README, CONTRIBUTING, package README, development docs, performance docs, and active plans.
- Resolve each review candidate with retain-and-wire or delete evidence.
- Remove replaced commands, aliases, dependencies, tests, and help in the same change.
- Run the reference/policy scan and personal-info guard.

### Phase 6 — acceptance and closure

- Run focused policy/helper fixture tests first.
- Validate passing, failing, hanging, interrupted, and stale-lock paths.
- Run the complete unit checkpoint once on the canonical test runtime.
- Run the focused real-Gateway E2E once on the test simulator.
- Verify Development simulator app/container/Keychain preservation before and after.
- Update this document with exact evidence and only then mark it implemented.

## Acceptance gates

### Static and fixture gates

- Generated test actions reference the checked-in plans and routine diagnostics are Never.
- No active normal command uses a name-only simulator destination.
- No test command bypasses the shared process owner.
- Fake `simctl` fixtures cover missing runtime, duplicate names, wrong runtime, foreign UDID, stale owned UDID, and cleanup refusal for an unowned device.
- Process fixtures cover pass, ordinary failure, silence timeout, continuous output timeout, descendant process, TERM refusal, interrupt forwarding, and partial artifact preservation.
- Script-reference tests prove every retained executable has an owner and every deleted executable has no caller.
- Agent/document policy proves one canonical command account.
- `scripts/personal-info-guard.sh` passes.

### Real simulator gates

- A passing focused suite reaches `TEST EXECUTE SUCCEEDED` and a finalized result bundle.
- An intentionally failing focused suite reaches `TEST EXECUTE FAILED` without starting verbose diagnostics or requiring manual abort.
- A deliberately blocked fixture is bounded by the process owner, captures evidence, kills its process group, and leaves no running test host.
- A full unit checkpoint runs serially on the exact pinned test runtime.
- E2E renews its fixture and app state, runs on the exact test UDID, and releases its lock.
- Concurrent second unit/E2E invocation fails before Xcode rather than sharing the simulator.
- The Development simulator retains its original UDID, app identity, data container, and pairing state and is never selected by a test command.

### CI gates

- The selected simulator runtime equals the manifest pin.
- Failure and timeout artifacts upload unconditionally.
- The job leaves no owned simulator or fixture process.
- No release/archive/upload/deployment action is added.

## Completion record

Do not mark this plan complete with prose alone. Record:

- changed and deleted script paths;
- the final public command surface;
- toolchain/runtime and test-plan evidence;
- fixture-test commands and results;
- passing/failing/hang real-simulator evidence;
- CI run evidence and artifact names;
- Development simulator preservation evidence;
- remaining compatibility exceptions, owner, and explicit removal gate.

## Implementation record — 2026-09-01

This record describes the current worktree and does **not** mark the acceptance
gates complete.

### Changed and deleted ownership surfaces

Added the canonical public runner `scripts/tron-ios-test`; shared internal owners
`scripts/ios-test-simulator.py`, `scripts/ios-test-lock.py`, and
`scripts/ios-test-process.py`; pinned generation adapter
`scripts/generate-ios-project`; hardware-free fixture coverage in
`scripts/test-ios-test-infrastructure.py`; static ownership policy in
`scripts/test-ios-test-policy.sh`; checked-in `UnitTests.xctestplan` and
`UIValidation.xctestplan`; inert hosted-startup coverage; and the opt-in real
Xcode failure/hang fixture.

`scripts/ios-ci-test.sh` is now a thin checkpoint/metrics/cleanup adapter.
`scripts/ios-gateway-e2e-test` retains only its Gateway fixture and scenario
ownership while using the shared test simulator, lease, process deadline, pinned
generator, and unique result paths. `scripts/tron-ios-simulator` now owns only
explicitly remembered Development app lifecycle; `check-affected` and `iterate`
were removed. `scripts/tron ios generate` was retained only as a delegate to the
pinned generator. The manual release doctor was retained, documented, and wired
to CI self-test without adding archive/upload behavior.

Deleted the orphan `scripts/generate-ios-icons.mjs` and its sole dependency files
`packages/ios-app/package.json` and `packages/ios-app/bun.lock` after a
repository-wide reference scan found no live owner.

### Final public command surface

```text
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/<Suite> [repeatable]
scripts/tron-ios-test checkpoint
scripts/tron-ios-test status
scripts/tron-ios-test clean
scripts/tron-ios-test diagnose --only-testing TronMobileTests/<Suite>
scripts/tron-ios-simulator remember|install|start|status|stop
scripts/ios-gateway-e2e-test prepare|build|run|iterate|all|status|logs|stop|clean
scripts/ios-ci-test.sh                 # CI adapter
scripts/ios-ci-test.sh cleanup         # unconditional CI cleanup
```

### Evidence collected

- Canonical test toolchain: Xcode 26.6 (`17F113`), iOS simulator runtime 26.5
  (`23F77`), and the manifest-pinned XcodeGen. Generated schemes reference the
  checked-in plans; both plans contain `diagnosticCollectionPolicy: Never`.
- `python3 scripts/test-ios-test-infrastructure.py`: 15 hardware-free tests pass,
  covering exact provisioning/cleanup refusal/runtime drift/Development rejection,
  lock contention/release, output streaming, ordinary failure, silent and
  continuous-output deadlines, descendants, TERM refusal, interrupt forwarding,
  and partial-artifact preservation.
- Source, generated matrix/test-plan, iOS ownership, agent, release-doctor
  self-test and manual read-only doctor, personal-info, Python syntax, shell
  syntax, and `git diff --check` gates pass.
- Focused hosted-startup run `20260901T215918Z-run.6QauG9` passed and reached
  `TEST EXECUTE SUCCEEDED` with a finalized xcresult.
- Opt-in product failure run `20260901T214509Z-run-85578` returned stable exit 65,
  reached `TEST EXECUTE FAILED`, wrote `summary.json`, and contained no diagnostic
  collection start.
- Opt-in blocked run `20260901T214526Z-run-85694` returned stable timeout exit 75,
  recorded a no-output timeout, process tree, samples/partial-result inventory,
  killed the process group, and left no matching test host.
- A concurrent second invocation returned exit 73 before Xcode.
- The remembered Development simulator UDID hash and shutdown state were identical
  before and after. Its Development app container was absent both times, so there
  was no pairing container to compare; the test runner selected a distinct owned
  UDID on runtime 26.5.
- Full serial checkpoint `20260901T214602Z-checkpoint-85999` remained bounded and
  reached `TEST EXECUTE FAILED` normally. Its xcresult reports 1,411 passed, 25
  failed, and 3 skipped tests. Failures include current presentation/source
  guards, scenario expectations, watchdog expirations, and signal traps outside
  this consolidation's allowed scope. They were not retried or hidden.

### Pending acceptance evidence

The real-Gateway UI E2E was not invoked because repository agent policy forbids
agents from initiating Gateway build/lifecycle transitions. A maintainer must run
it and record the result. GitHub CI has not yet executed this worktree; the workflow
now uploads logs, metadata, metrics, xcresults/partial bundles, and timeout evidence
unconditionally, then invokes exact owned-simulator cleanup in an `always()` step.
Those two receipts, plus disposition of the full-checkpoint product failures, are
required before changing this status to accepted.

The bounded external compatibility input `.codex/environments/environment.toml`
remains untouched. Its retired physical names are still isolated behind
`scripts/tron-ios-device` fixture coverage; the external harness owns removal, and
the adapter may be deleted only after that input is retired and a repository-wide
caller scan proves zero references.
