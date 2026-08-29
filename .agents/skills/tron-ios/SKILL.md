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
Build role and push route are emitted into `Info.plist`; signed artifacts are
authoritative. Test's beta relay route is internal compatibility only and is
not a real APNs lane.

## Commands

```bash
scripts/tron-ios-simulator install
scripts/tron-ios-simulator start
scripts/tron-ios-simulator status
scripts/ios-ci-test.sh
```

For a physical development device, use the device helper without overriding its
safe defaults:

```bash
scripts/tron-ios-device install
scripts/tron-ios-device launch
scripts/tron-ios-device status
scripts/tron-ios-device stop
```

Generate Xcode with `xcodegen generate`; if it is not on `PATH`, install the
pinned repository-managed tool with `scripts/install-ci-tools.sh xcodegen`.
Use `scripts/validate-ios-artifact.py` on signed products and
`packages/ios-app/scripts/verify-archive-privacy.sh` for a manually-created
archive. Never install Release or DevicePerformance through the ordinary helper.
Do not archive, upload, deploy, or erase app/Keychain data.

## Stop rules

- Never infer push routing from `DEBUG`, bundle naming, or a scheme; inspect the
  emitted artifact metadata and entitlements.
- Never use retired build names. A narrowly bounded compatibility adapter
  exists only for the untouched external-harness environment; agents must use
  the canonical `Tron Device` + `LocalDevice` pair.
- Never install a production Release artifact through the ordinary device
  helper or automate signing, archive delivery, upload, or deployment.
- Never modify `.codex/environments/environment.toml`; old names may appear only
  there and in the bounded compatibility branch above.
