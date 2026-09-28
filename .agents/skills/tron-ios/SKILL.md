---
name: tron-ios
description: Build, test, install, inspect, or release-validate Tron iOS artifacts safely. Use for simulator, physical-device, signing, push-environment, scheme, configuration, and archive work.
---

Run from the repository root. `packages/ios-app/project.yml` is canonical;
the Xcode project is disposable generated output. There is no separately
distributed Beta product.

## Routing table

| Work | Scheme | Configuration | Route / identity |
|---|---|---|---|
| Simulator app iteration | Tron Development | Development | beta route, `com.tron.mobile.beta` |
| Unit tests | Tron Development or Tron Device | Test | `HOSTED_TEST`, isolated test host |
| Physical development device | Tron Device | LocalDevice | optimized development, production-sandbox, `com.tron.mobile` |
| Device performance tests | Tron Device Performance | DevicePerformance | hosted test, production-sandbox |
| Scenario profiling (agents) | `scripts/tron-profile ios` (Tron Device Performance) | DevicePerformance | optimized hosted test on the owned test simulator, shared lease |
| Manual release archive | Tron Release | Release | production; archive/analyze/profile only |
| UI validation | Tron UI Validation | Test (run and test actions) | `HOSTED_TEST` app, Test UI host |

`LocalDevice` is the optimized normal-use configuration: Swift `-O` whole-module
compilation, normal Clang optimization, testability disabled, and
`dwarf-with-dsym` symbols, while development signing remains available for an
explicit Instruments attachment. `Tron Device`'s Run action sets
`debugEnabled: false`; its explicit Profile action is the only profiling action
for the physical normal-use app. Do not create a shadow bundle or add a second
profiling scheme.

The canonical physical install pair is `Tron Device` + `LocalDevice`.
The supervised Rebuild and Install sheet may explicitly select Fast debug (on by
default for UI iteration); it uses the same pair and identity with
`--fast-debug`, unoptimized compilation, and a separate DerivedData cache. Both
install modes compile per file; only the scheme's Profile action builds the
whole-module `LocalDevice` binary. It is never a Release mode. Build role, push route, and exact Gateway protocol range are emitted into
`Info.plist`; signed artifacts are authoritative. Test's beta relay route is
internal compatibility only and is not a real APNs lane. A Stable device install
must follow a verified matching Mac app/Gateway install; the device helper fails
before `devicectl` when their signed protocol metadata differs.

## Commands

```bash
scripts/tron-ios-simulator install
scripts/tron-ios-simulator start
scripts/tron-ios-simulator status
scripts/tron-ios-simulator stop
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/<Suite>
scripts/tron-ios-test checkpoint
scripts/tron-ios-test status --all
scripts/tron-ios-test lanes
scripts/tron-ios-test lane-remove <name>
scripts/tron-ios-test reap
scripts/tron-ios-test prune
scripts/tron-ios-test clean
```

For a physical development device targeting Stable, first complete the Mac
Release reinstall runbook and `scripts/tron mac verify`, then use the device
helper without overriding its safe defaults:

```bash
scripts/tron-ios-device install
scripts/tron-ios-device launch
scripts/tron-ios-device status
scripts/tron-ios-device stop
```

For an explicitly source-built Debug Gateway on 9848, use
`TRON_IOS_GATEWAY_PROTOCOL_TARGET=source scripts/tron-ios-device install`; this
still verifies the source and iOS artifact contract but does not claim Stable is
ready. Never use that target to bypass a mismatched Stable installation.

The iOS build-output root, its worktree-local test products and its shared-test
lease ownership are documented
in [iOS development](../../../packages/ios-app/docs/development.md#test-runner-safety-contract);
the lanes, release, sweep and memory admission this skill depends on are in
[Simulator lifecycle](#simulator-lifecycle) below.

Generate Xcode with `scripts/tron ios generate`; it resolves the pinned
repository-managed XcodeGen. If the tool is absent, install it with
`scripts/install-ci-tools.sh xcodegen`.
Use `scripts/validate-ios-artifact.py` on signed products and
`packages/ios-app/scripts/verify-archive-privacy.sh` for a manually-created
archive. Never install Release or DevicePerformance through the ordinary helper.
Do not archive, upload, deploy, or erase app/Keychain data.

To measure an iOS change, agents run `scripts/tron-profile ios --self-test`,
then the relevant `--scenario`, before and after, and judge with
`scripts/tron-profile compare`; usage, scenarios, metrics and caveats are in
[iOS development](../../../packages/ios-app/docs/development.md#ios-scenario-profiler).

For a real slowdown on a device, the user selects **Product → Profile** on `Tron Device` to
open Instruments, or attaches Instruments to an already normally launched
optimized app. Start with Time Profiler, Points of Interest, SwiftUI, and
Concurrency/System Trace as indicated by the hypothesis; correlate existing
bounded Logs Share diagnostics and signposts, then repeat the same interaction
under matched conditions. Keep the matching dSYM and verify its UUID against the
profiled app binary. This is user-owned profiling: agents may generate and
validate source/build artifacts but must not install the app or mutate Gateway
state. Performance Trace/processor tracing is optional hardware-assisted
follow-up, not default telemetry; device/OS support and trace size are limits.

## Simulator lifecycle

Lanes, release, the sweep and memory admission are owned by
`scripts/ios-test-simulator.py` and shared by `scripts/tron-ios-test`,
`scripts/tron-profile ios` and `scripts/ios-gateway-e2e-test`; do not release or
reclaim simulators yourself.

- A lane is one state directory and one device name: `--lane NAME` (or
  `TRON_IOS_TEST_LANE`) uses `$HOME/.tron/internal/ios-test-NAME` and the device
  `Tron iOS Tests (NAME)`, while the default lane keeps
  `$HOME/.tron/internal/ios-test` and `Tron iOS Tests`. Lanes do not serialize
  against each other; lanes of one worktree share its single products directory,
  so build in one lane per worktree at a time.
- Every command that provisions a lane's simulator releases it when the command
  ends - success, failure, timeout, SIGINT, SIGTERM or SIGHUP - unless
  `--keep-booted` asks to reuse it for a tight test-fix loop. A signal reaches
  the whole command tree and the release waits for it, so nothing of a stopped
  test is left running under a released simulator. A lane a live
  process leases is never disturbed, by the tooling or by an agent.
- Every command that provisions a lane's simulator first sweeps: orphaned owned
  lanes (booted with no live lease) are shut down, and lanes unused for 7 days
  are removed. The runner's sweep also prunes runs beyond the retention windows
  and the products of worktrees that no longer exist. `scripts/tron-ios-test
  reap` runs that same sweep on demand, and `prune` reclaims disk alone.
- A boot is admitted on the Mac's memory. Below 8 GB free the command fails
  fast with exit 73 and the simulator table instead of pushing the Mac - and the
  phone's connection through the Gateway - into swap; swap in use is reported in
  that table and never refuses a boot, because it drains slowly. Boots also
  serialize on one machine-wide admission lock, so concurrent starts see the
  memory earlier boots took. Wait for memory and retry;
  `TRON_IOS_TEST_MEMORY_RESERVE_BYTES` moves the reserve.
- `scripts/tron-ios-test status --all` is the read-only view of everything
  holding this Mac's memory: the Mac's own free memory and swap in use, every
  lane with its worktree, lease holder, uptime
  and disk, booted devices no lane owns, the remembered Development simulator,
  and `Simulator.app`. Run it before a final response. `lanes` lists lanes
  alone, `lane-remove NAME` reclaims one lane with its simulator and state, and
  `clean` reclaims this lane's simulator, its runs and this worktree's products;
  the shared results root is never removed wholesale.
- The remembered Development simulator (`scripts/tron-ios-simulator`) is only
  ever shut down by its own `stop`; no test tool deletes it. The simulators the
  test tooling does own - the ones with its own marker - are deleted by `clean`,
  `lane-remove` and the sweep.

## Stop rules

- Never initiate a Gateway rebuild, update, rollback, promotion, restart, or
  mutating `scripts/tron dev` lifecycle command. Prepare and validate source or
  artifacts, report the required action, and wait for the user or maintainer to
  perform the Gateway transition.
- Never infer push routing from `DEBUG`, bundle naming, or a scheme; inspect the
  emitted artifact metadata and entitlements.
- Never install iOS before its target Gateway contract is verified. A protocol
  bump is Mac-first; do not widen the advertised minimum as a migration shortcut.
- Never use retired build names. A narrowly bounded compatibility adapter
  exists only for the untouched external-harness environment; agents must use
  the canonical `Tron Device` + `LocalDevice` pair.
- Never shut down, delete or erase a simulator by hand, and never touch one a
  live lease, another session or the Development helper owns. Release one you
  booted outside the test tooling with its owning helper
  (`scripts/tron-ios-simulator stop` for the Development simulator).
- Never force a boot past memory admission (exit 73) by booting the device
  another way; free memory first, or report the shortage.
- Never install a production Release artifact through the ordinary device
  helper or automate signing, archive delivery, upload, or deployment.
- Never modify `.codex/environments/environment.toml`; old names may appear only
  there and in the bounded compatibility branch above.
