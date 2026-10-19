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
live`. With **Settings › Tools & Diagnostics › Setup & Experiments › Run Swift files**
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
