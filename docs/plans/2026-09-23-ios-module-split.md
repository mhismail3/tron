# iOS module split

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, none
- **Goal:** Split stable iOS code out of the single `TronMobile` module so a typical edit rebuilds and re-optimizes only the module it touches.

Follow the [plan protocol](README.md#protocol) to claim tasks and hand off.

## Goal and constraints

Every iOS build compiles one 106k-line module. Any edit re-runs the whole
module's interface step, and the whole-module Profile build re-optimizes
everything. Splitting stable layers into local modules makes those costs
proportional to what changed and lets modules build in parallel.

- **No product change:** UI, UX, scroll continuity, composer and keyboard
  behavior, persisted data, Keychain entries and signed artifacts stay the
  same. This is a build-structure change only.
- **One owner per type:** a type moves to exactly one module. No duplicate
  copies, re-export shims or compatibility typealiases in the app module.
- **Measure, don't assume:** each split lands with before/after timings for a
  cold build, a no-change build and a one-file edit, taken as in Context.
  A split that does not measurably help is reverted, not kept.
- **Tooling stays canonical:** project structure lives in
  `packages/ios-app/project.yml`; device installs keep using
  `scripts/tron-ios-device`; tests keep using `scripts/tron-ios-test`.
- **Operational safety:** never install on a device another session owns and
  never rebuild or restart the Gateway.

**Coordination:** the [simplification program](2026-09-23-simplification-program.md)
covers the same iOS source (IOS-STATE, IOS-CHAT). Claim a split only for code
that plan is not cleaning up at the same time; a module boundary should follow
its cleanup, not race it.

## Context

### Build measurements (2026-09-23)

Taken with `-destination generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` and a
scratch DerivedData on an 18-core Mac.

| Build | Cold | One-file edit |
| --- | --- | --- |
| Profile / `LocalDevice` (`-O`, whole module) | 226 s | 158 s |
| Device install (`-O`, per file) | 127 s | 16–24 s |
| Fast debug (`-Onone`, per file) | 51 s | 14 s |

`SwiftEmitModule` takes 9–13 s on every incremental build, whatever the edit.
That step is the floor a module split can lower.

### Current layout

| Directory | Files | Lines |
| --- | --- | --- |
| `packages/ios-app/Sources/UI` | 142 | 63,231 |
| `packages/ios-app/Sources/State` | 42 | 24,322 |
| `packages/ios-app/Sources/Models` | 20 | 7,299 |
| `packages/ios-app/Sources/Gateway` | 12 | 4,278 |
| `packages/ios-app/Sources/Support` | 24 | 3,803 |
| `packages/ios-app/Sources/Notifications` | 3 | 1,608 |
| `packages/ios-app/Sources/App` | 8 | 1,303 |
| `packages/ios-app/Sources/Auth` | 1 | 762 |

The share extension already compiles `packages/ios-app/Sources/Support/SharedContent.swift`
directly, and unit tests reach the app through `@testable import TronMobile`.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| MS-1 | Needs scoping | Map the dependency graph of Models, Gateway, Support, State and UI/Theme; propose module boundaries with no cycles | none | |
| MS-2 | Needs scoping | Choose the module form (XcodeGen framework targets or a local Swift package) and prove signing, share-extension embedding and the Profile action still work | MS-1 | |
| MS-3 | Needs scoping | Extract the lowest layer (likely Models plus Gateway protocol types) and record timings | MS-2 | |
| MS-4 | Needs scoping | Extract further layers MS-1 identifies, one per task, each with timings | MS-3 | |
| MS-5 | Needs scoping | Move the share extension onto the shared module instead of compiling app source files | MS-3 | |

## Task details

### MS-1 — Dependency map

Owning files: `packages/ios-app/Sources`. Output is a findings block in this
plan: which directories import SwiftUI or UIKit, which types cross layers, and
which `internal` symbols would need `public` or `package` access. Acceptance:
proposed boundaries are acyclic and name the access-level changes each needs.

### MS-2 — Module form

Owning file: `packages/ios-app/project.yml`. Compare framework targets and a
local package on incremental time, `@testable` test access, dSYM output and the
generated schemes. Acceptance: one spike module builds, installs through
`scripts/tron-ios-device install` and profiles through **Product → Profile**.

## Handoff log

No entries yet.
