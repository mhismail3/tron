# Builds preview (Swift mini-app)

`BuildsPreview.swift` is the canonical, runnable source of the recovered
October 16, 2026 Builds design (#1319, #1162): newest-first build rows, All /
Optimized / Fast debug modes, title-or-branch search and a notes/metadata
detail. It is a **historical snapshot**: its records are baked in, it says
"Not live", and **Install** is disabled. It cannot build, publish, install,
replace the Mac or restart a Gateway, and contains no host URL or credentials.
This historical preview does not consume the Gateway's live `ios-builds` feed.

## Present it in chat

Copy the file into the session directory and call `display` with
`presentation.surface: "inline"`, an app title and an honest caption, for
example title `Tron builds`, caption `Historical preview · Oct 16 snapshot, not
live`. A source snapshot remains readable code, even with the Swift experiment
on; its filename never authorizes execution. Native execution requires an admitted
folder session. The folder DTO/UI pairing is not yet release-ready; see
[Swift apps](../../../../packages/ios-app/docs/swift-apps.md#folder-backed-apps).

## Edit and validate

Edit this file directly; it must stay within the
[supported subset](../../../../packages/ios-app/docs/swift-apps.md#supported-subset).
The `TronSwiftAppUITests` bundle carries these exact bytes. Its legacy raw-run
journeys (`testInlineSwiftAppCardOpensRunnerAndReplays`,
`testRecoveredBuildsPreviewFiltersSearchesAndReopens`) still require canonical-folder
fixture wiring; they are not current acceptance evidence. Review screenshots go to
`~/.tron/workspace/files/mini-apps/swift-apps/evidence/<review-id>/`, never here.
