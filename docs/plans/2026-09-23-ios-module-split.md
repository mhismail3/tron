# iOS module split

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-27, MS-3 scoped into MS-3a and MS-3b; both claimed
- **Goal:** Give the iOS app compiler-enforced layers, so its structure stays clean, one-directional and easy for agents to work in, and cannot silently regress into cycles.

Follow the [plan protocol](README.md#protocol) to claim tasks and hand off.

## Goal and constraints

The app is one module of about 110,000 lines, and MS-1 found every layer
except App and Auth in a single dependency cycle. Nothing stops a low layer
from reaching up into State or UI, so structure erodes one convenient reference
at a time. Separate modules make the layering a compiler rule: a lower module
cannot see a higher one, each module declares the surface it offers, and an
agent editing a module sees only what that module may use. The user set this
goal on 2026-09-26: a robust, maintainable and extensible codebase that agents
can work in without introducing regressions. Faster incremental builds are a
possible side effect, not the reason.

- **No product change:** UI, UX, scroll continuity, composer and keyboard
  behavior, persisted data, Keychain entries and signed artifacts stay the
  same. This is a build-structure change only.
- **One owner per type:** a type moves to exactly one module. No duplicate
  copies, re-export shims or compatibility typealiases in the app module.
- **Structure is the acceptance test:** each split lands with its module
  boundary compiling with no cycle, no widened access beyond what another
  module actually uses (`package` by default, `public` only when required),
  the full iOS test suite passing, and the product unchanged.
- **Builds must not get worse:** each split records before/after timings for
  a cold build, a no-change build and a one-file edit (recipe in the MS-1
  handoff). A clear slowdown is a finding to fix or bring to the user, not a
  reason to keep the change silently.
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

Recounted 2026-09-26 (MS-1):

| Directory | Files | Lines |
| --- | --- | --- |
| `packages/ios-app/Sources/UI` | 151 | 65,622 |
| `packages/ios-app/Sources/State` | 43 | 25,385 |
| `packages/ios-app/Sources/Models` | 20 | 7,625 |
| `packages/ios-app/Sources/Gateway` | 13 | 4,356 |
| `packages/ios-app/Sources/Support` | 24 | 3,876 |
| `packages/ios-app/Sources/Notifications` | 3 | 1,606 |
| `packages/ios-app/Sources/App` | 9 | 1,536 |
| `packages/ios-app/Sources/Auth` | 1 | 781 |

The share extension already compiles `packages/ios-app/Sources/Support/SharedContent.swift`
directly, and unit tests reach the app through `@testable import TronMobile`.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| MS-1 | Done | Map the dependency graph of Models, Gateway, Support, State and UI/Theme; propose module boundaries with no cycles | none | module-split session, 2026-09-26 |
| MS-2 | Done | First real slice of `TronMobileCore`, an XcodeGen framework target with `SWIFT_PACKAGE_NAME` set so `package` access works: move a few leaf types from Models, Gateway or Support into it (kept, not a throwaway spike); prove all five configurations build, the share extension, `@testable` tests, both test plans and the source-policy scripts; record baseline and after timings. Device install and **Product → Profile** are checked by the user or supervisor | MS-1, D1, D2 | module-split session, 2026-09-26 |
| MS-3a | Claimed | Inside the one app module, relocate declarations so Models, Gateway and Support reference nothing in State, Notifications, Auth, UI or App and import no UI framework (see MS-3 scope); no framework change yet | MS-2 | module-split session, 2026-09-27 |
| MS-3b | Claimed | Move Models, Gateway and Support into `TronMobileCore` with `package` access, a Core privacy manifest and a no-UI-import guard; record timings | MS-3a | module-split session, 2026-09-27 |
| MS-4 | Needs scoping | Extract `Notifications`, then `State` (with `Auth`), then `UI`, one per task, each with timings, after the simplification program has cleaned up State and Chat (D1); split UI by folder where its boundaries are clean | MS-3b, simplification S-IOS-STATE and S-IOS-CHAT work | |
| MS-5 | Needs scoping | Move the share extension onto `Core` instead of compiling `SharedContent.swift` itself | MS-3b | |

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

## MS-1 findings (2026-09-26)

Method: two read-only lanes. Declarations came from the compiler's parser (`swiftc -dump-parse`, with `#if`
regions flattened because the dumper skips them), and references from identifier tokens with comments and
strings removed. Measured accuracy: all 186 references found only by the token scan were read, and all were
real; 0 of 1,654 top-level names is declared in two layers. The scratch scripts were not committed; once
modules exist, the compiler enforces the boundaries itself.

**Graph (measured).** 264 files, 1,742 top-level declarations, 579 symbols crossing a layer. Every layer
except `App` and `Auth` sits in one cycle of 12 layers. Examples: Models throws Gateway's `GatewayFailure`
(`Models/TranscriptModels.swift:169`) while Gateway uses Models' `SessionSnapshot`; Models uses State's
`GitInspection` (`Models/SessionSourceControlModels.swift:59`); Support's chat trace uses UI/Chat's
`ChatLayoutMutation` (`Support/ChatInteractionTrace.swift:439`); UI/Theme uses UI/Chat's
`TronTopBlurOverlay` (`UI/Theme/TronPresentation.swift:163`).

**Proposed modules (simulated acyclic: 0 cycles, 14 module edges).**

1. `Core` = Models, Gateway, Auth and Support. Moves down into it: 24 small diagnostic and admission value
   types now in State (for example `GitInspection`, `GatewayConnectionDiagnostic`, `GatewayLogRecord`,
   `ComposerDraftScope`, `DashboardServerConnectionState`), and 6 chat viewport value types now in UI/Chat
   (`ChatLayoutMutation`, `ChatScrollCommand`, `ChatViewportIntent`, `ChatViewportMode`,
   `ChatPhysicalTailClassification`, `ChatTranscriptGeometry`). Moves out: `ComposerDraftStore.swift`,
   `IOSMetricKitDiagnostics.swift`, `GatewayLogExport.swift` and `SnapshotCache.swift` to State; the two
   hosted-test probes to UI/Chat.
2. `Notifications` (3 files), depending only on `Core`.
3. `State`, once `ChatSessionPresentation.swift`, `ReadOnlySubagentSessionStore.swift` and
   `SessionHistoryStore.swift` (used only by UI/Chat) move up, and three small UI/Chat value types
   (`ChatAttachmentEnvelopePolicy`, `ExtensionFormDraft`, `ChatTranscriptPageRequest`) move down.
4. `UI`, then the `App` target. Splitting UI by folder leaves one cycle, UI/Onboarding and UI/Settings
   (six `ProviderUsage*` types one way; `ModelPicker`, `OnboardingView`, `ProviderSetupRow` and
   `WorkspaceBrowser` the other), plus eight small moves; order Theme, Components, Automations, Terminal,
   Settings with Onboarding, Chat.

**Constraints (inspected unless marked).**

- Access: no declaration is `public` or `package` today, so every crossing symbol needs one, plus explicit
  initialisers where another module constructs a struct (measured: 116 sites build `GatewayFailure` with its
  memberwise initialiser). Correction to a lane claim: Xcode framework targets can use `package` access by
  setting `SWIFT_PACKAGE_NAME` (present in the installed Xcode's `Swift.xcspec`), so `public` is not forced.
- Build settings are project-level, so new targets inherit Swift 6, strict concurrency, `HOSTED_TEST` and
  testability per configuration. Only two conditions exist: `HOSTED_TEST` (115 blocks in 42 files, 7 layers)
  and `TRON_PRIVATE_VARIABLE_BLUR` (UI/Chat only).
- Tests: 155 of 158 test files use `@testable import TronMobile`; about two thirds would also import the new
  module. Both `.xctestplan` files hard-code the test target's identifier.
- Tooling to update with a move: `packages/ios-app/scripts/presentation-source-policy.py` names
  `State/PresentationActivityCoordinator.swift`; the only Objective-C bridging header
  (`Support/PrivateVariableBlurBridge.h`) serves `UI/Chat/ChatTopVariableBlur.swift`; `project.yml`'s
  generate step asserts the exact scheme names.
- Resources stay in the app: code uses only `Bundle.main` (unchanged in a framework), the asset catalog, fonts,
  the notification sound, `TronBuildIdentity.json` and app-Info.plist keys. A framework that reads
  UserDefaults needs its own privacy manifest, which `PrivacyManifestTests` would have to cover.
- `App/Hosted*Fixture*.swift` (`HOSTED_TEST` only) reach 87 types in other layers, so those types become
  module API unless the fixtures move with their subjects.
- Low-layer framework imports to resolve: `Gateway/LiveViewing.swift` returns `UIImage`,
  `Models/KnowledgeModels.swift` declares `@Observable` stores, `Support/RetiredNotificationBadge.swift` uses
  UserNotifications.

**Decisions needed before MS-2 (user).**

- D1 Coordination: decided by the user on 2026-09-26. Extract `Core` now (its moves out of State and UI/Chat
  are small and mechanical), and split State and UI only after the simplification program cleans that code up.
  The `Core` boundary then protects that cleanup: lower code cannot reach back up.
- D2 Module form: the user asked for the most robust and scalable form; the supervisor chose XcodeGen framework
  targets on 2026-09-26. `Core` code has `HOSTED_TEST` blocks (`GatewayClient`, `DisplayModels`,
  `ChatInteractionTrace`) and the app has five build configurations. Framework targets inherit every
  configuration and condition exactly; a Swift package knows only debug and release and would need unsafe flags
  per configuration. The module is named `TronMobileCore`, not `TronCore`, because `tron-core` already names a
  Gateway extension.
- D3 Value check: resolved by the user on 2026-09-26. The goal is structure (see Goal and constraints), so
  timings guard against a slowdown instead of deciding whether the split is worth doing.

## MS-3 scope (2026-09-27)

Supervisor decisions, from the MS-1 findings:

- **Core is Foundation-only.** It may import Foundation and system non-UI frameworks (CryptoKit, Network, OSLog,
  Security and similar), never SwiftUI, UIKit, Observation or UserNotifications. A source-policy check enforces it.
- **Auth stays in the app** and moves with State in MS-4: `ProviderOAuthBrowser` presents from a `UIWindowScene`,
  and its only users are State and Onboarding.
- **The three low-layer framework imports are resolved by ownership, not by importing UI into Core:**
  `KnowledgeModels.swift`'s `@Observable` presentation stores move to State; `RetiredNotificationBadge` moves to
  Notifications; `LiveViewing`'s `UIImage` decoding moves up to its State or UI consumer, while the transport and
  bytes stay in Gateway.
- **Declarations move to the file and directory that own their concept,** never into a catch-all file.
- **Two steps.** MS-3a relocates declarations inside the single app module, so the compiler and the full suite
  prove each move with no access or target change. MS-3b then moves the three directories into the framework,
  which is mechanical once MS-3a leaves no upward reference. Models, Gateway and Support reference each other,
  so they move in one commit.
- **Core reads UserDefaults** (`GatewayProfileStore`, `SharedContent`), so the framework ships its own privacy
  manifest and `PrivacyManifestTests` covers it.

## Handoff log

### MS-1 · Done · 2026-09-26 · module-split session (two deepseek-worker lanes, reviewed by the supervisor)

- Result: the findings above. The plan's layout table is recounted; MS-2 is scoped and waits for D1 to D3.
- Evidence: the supervisor reran the graph lane (same one cycle today, acyclic after the proposed moves) and
  checked four cross-layer examples and the `SWIFT_PACKAGE_NAME` setting by hand.
- Deviation: the constraints lane said framework targets force `public`; the installed Xcode shows otherwise.
- For the next agent: the build-timing recipe is `xcodebuild build -scheme 'Tron Device' -configuration
  LocalDevice -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` with a scratch DerivedData, run cold,
  unchanged and after a one-file edit, for whole-module `-O`, `SWIFT_COMPILATION_MODE=singlefile`, and
  `-Onone` singlefile, reading `SwiftEmitModule` from the result bundle's build log.

### MS-2 · Done · 2026-09-27 · module-split session (deepseek-worker, reviewed by the supervisor)

- Result: the app now has a second module, the `TronMobileCore` framework (sources in `packages/ios-app/Core/`,
  each file under the layer directory it will keep). It holds the Gateway wire contract: `GatewayProtocolContract`,
  `GatewayRequestTimeout` and `GatewayConnectionPolicy`, the only Models, Gateway or Support files with no outgoing
  reference to anything else. App, framework and unit tests share `SWIFT_PACKAGE_NAME = TronIOSApp`, so crossing
  declarations are `package`, never `public`. The framework has its own bundle identifier and a generated plist
  without the app-only keys. `scripts/gateway_protocol_contract.py` follows the moved file and now accepts only
  `package` access.
- Evidence (verified): all five configurations build (Development simulator, Test, and LocalDevice,
  DevicePerformance and Release for a generic device without signing); the share extension builds and ships in
  each; the LocalDevice app contains `Frameworks/TronMobileCore.framework`. On combined `main` the supervisor
  reran the build and the full suite: 1,719 Swift Testing tests in 139 suites plus 87 XCTest, 0 failures; the
  source policy and protocol-contract checks pass. Negative control: a `Core` file referencing `AppModel` or
  `TronTheme` fails to compile.
- Timings, install path, measured back to back on the old and new tree: cold 116.5 s → 113.3 s, no change
  2.2 s → 2.1 s, one-file UI/Chat edit 17.0 s → 17.1 s; the app module's `SwiftEmitModule` is unchanged. No
  slowdown.
- Deviation: the MS-1 timing script had three bugs (an inverted assertion, a fresh DerivedData per case, and a
  hard-coded mode name); the worker fixed its copy in `/tmp`, so the recipe in the MS-1 handoff stands.
- Device check (verified 2026-09-27): the user rebuilt the Gateway and installed the phone from `55d3b4074`.
  The Gateway runs that revision; the installed LocalDevice app embeds `TronMobileCore.framework` signed by the
  team, passes `scripts/validate-ios-artifact.py --configuration LocalDevice --require-profile` and a strict
  deep `codesign --verify`; the phone has since connected as a paired mobile client with no Gateway errors. A
  **Product → Profile** run is optional and not yet done; nothing in MS-2 changed the Profile action's
  configuration.
- Found while verifying, fixed on `main` outside this plan (`1491db2dc`, `e1f8e23ac`): the iOS source policy
  and the documentation policy already failed on `main` (two raw sheets; a comment naming a gitignored
  `test-results/` file), and `TronAccessibilityUITests` had stale dashboard menu expectations. All three now pass.
  Run `packages/ios-app/scripts/test-source-policy.sh` and `python3 scripts/check-documentation-policy.py` as
  part of each MS task.
- For the next agent: `packages/ios-app/scripts/presentation-source-policy.py` scans only `Sources/`, which is
  correct while `Core` holds no SwiftUI; the module that receives State must extend that scan.
