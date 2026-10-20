# App

## Purpose

The `TronMobile` application target's composition: the app entry, the production scene root,
background checkpoints and bundled resources.

## Owns

`App/TronMobileApp.swift`, `App/ProductionSceneRoot.swift`, `App/AppBackgroundCheckpointCoordinator.swift`,
`Assets.xcassets`, `Info.plist`, `PrivacyInfo.xcprivacy`, `Resources/` (fonts, third-party notices,
`tron-notification.caf`). The hosted `App/Hosted*Fixture.swift` files belong to the hosted-fixtures
module.

## Contract

- `TronMobileApp` creates `AppModel` and, per scene, the `PresentationActivityCoordinator`, the
  presentation-state root (`TronPresentationStateRoot`) and the in-app notice window;
  `ProductionSceneRoot` feeds network-path facts to lifecycle recovery hints and diagnostics.
  Everything else is composed by the owning modules ([State](State/README.md), [`UI`](UI/README.md)).
- The app embeds `TronMobileCore` and links `TronSwiftAppEngine` statically; module rules are in
  [Core](../Core/README.md#contract).
- Backgrounding checkpoints the composer draft and the snapshot cache inside one UIApplication
  assertion; it retires the transport epoch but never tears down accepted Gateway work.
- Both packaged targets (app and share extension) declare the required-reason UserDefaults privacy
  manifest; archive verification fails if either is absent.
- Directory sources exclude `**/*.module.json` and `**/README.md`, so manifests and owner docs never
  reach the bundle (`project.yml`).

## Invariants

- Test-only hosted fixtures compile only under `HOSTED_TEST`; production never runs a fixture seed.

## Entry points

`App/TronMobileApp.swift`, `App/ProductionSceneRoot.swift`.

## Signals

None of its own.

## Verify

```bash
scripts/tron-ios-test checkpoint                         # build, then the smoke set
scripts/tron-ios-device compile                          # the shipping (non-HOSTED_TEST) compile
packages/ios-app/scripts/test-build-matrix-policy.sh     # optimized app and share-extension settings
packages/ios-app/scripts/test-verify-archive-privacy.sh  # privacy-manifest archive check
```

`scripts/ios-gateway-e2e-test run-ui` drives `ProductionSceneRoot` against a real Gateway
([runbook](../docs/development.md#gateway-fixture-work)).

## Not here

Architecture index: [iOS architecture](../docs/architecture.md).
