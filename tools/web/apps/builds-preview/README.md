# Builds preview (Swift mini-app)

`BuildsPreview.swift` is the canonical, runnable source of the recovered
October 16, 2026 Builds design (#1319, #1162): newest-first build rows, All /
Optimized / Fast debug modes, title-or-branch search and a notes/metadata
detail. It is a **historical snapshot**: its records are baked in, it says
"Not live", and **Install** is disabled. It cannot build, publish, install,
replace the Mac or restart a Gateway, and contains no host URL or credentials.
A live `ios-builds` feed (#1159) does not exist yet; do not present this as one.

## Present it in chat

Copy the file into the session directory and call `display` with
`presentation.surface: "inline"`, an app title and an honest caption, for
example title `Tron builds`, caption `Historical preview · Oct 16 snapshot, not
live`. With **Settings › System › Setup › Run Swift files**
on, the iPhone shows a small app card; tapping it runs the app in the managed
runner sheet. Without the switch it stays an ordinary source card. See
[Swift apps](../../../../packages/ios-app/docs/swift-apps.md#inline-mini-app-card-1339).

## Edit and validate

Edit this file directly; it must stay within the
[supported subset](../../../../packages/ios-app/docs/swift-apps.md#supported-subset).
The `TronSwiftAppUITests` bundle carries this folder and runs these exact bytes
(`testInlineSwiftAppCardOpensRunnerAndReplays`,
`testRecoveredBuildsPreviewFiltersSearchesAndReopens`). Review screenshots go to
`~/.tron/workspace/files/mini-apps/swift-apps/evidence/<review-id>/`, never here.

## Installation design review (#1162)

`BuildsInstallDesign.swift` is a second **visual-only** proposal in this existing
preview owner, not a new installable app. It uses two synthetic records, wrapping
metadata and the existing interpreter host defaults. Install Build is disabled;
there is no feed, network or filesystem access. The historical source is unchanged.

`TronMobileUITests` also carries this folder so
`TronAppsInstallDesignUITests` can run both exact sources through the real
interpreter and capture light/dark/default/XXXL list/detail comparisons. A separate
hosted-only Install App review composes shared settings/document components.
Captures are diagnostic, not real-Gateway install or receipt acceptance.

```sh
TRON_IOS_TEST_BUILD_TIMEOUT_SECONDS=300 scripts/tron-ios-test build
TRON_IOS_TEST_FOCUSED_TIMEOUT_SECONDS=300 scripts/tron-ios-test run \\
  --only-testing TronMobileUITests/TronAppsInstallDesignUITests
```

The native result bundle retains originals. For this maintainer-requested review,
the combined contact sheets and design/manual-test notes go to Home's explicitly
specified `files/apps-install-flow/`, not the default mini-app evidence location.
Visible UI must be approved before landing. The real install/update grant,
receipt flow, declared feed and persisted-format decision remain unimplemented.
