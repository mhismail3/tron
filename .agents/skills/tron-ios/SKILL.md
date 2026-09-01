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
| Physical development device | Tron Device | LocalDevice | production-sandbox, `com.tron.mobile` |
| Device performance tests | Tron Device Performance | DevicePerformance | hosted test, production-sandbox |
| Manual release archive | Tron Release | Release | production; archive/analyze/profile only |
| UI validation | Tron UI Validation | Development / Test action | Development app, Test UI host |

The canonical physical install pair is `Tron Device` + `LocalDevice`.
Build role, push route, and exact Gateway protocol range are emitted into
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

Generate Xcode with `scripts/tron ios generate`; it resolves the pinned
repository-managed XcodeGen. If the tool is absent, install it with
`scripts/install-ci-tools.sh xcodegen`.
Use `scripts/validate-ios-artifact.py` on signed products and
`packages/ios-app/scripts/verify-archive-privacy.sh` for a manually-created
archive. Never install Release or DevicePerformance through the ordinary helper.
Do not archive, upload, deploy, or erase app/Keychain data.

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
- Never install a production Release artifact through the ordinary device
  helper or automate signing, archive delivery, upload, or deployment.
- Never modify `.codex/environments/environment.toml`; old names may appear only
  there and in the bounded compatibility branch above.
