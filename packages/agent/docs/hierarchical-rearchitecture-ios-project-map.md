# HRA-8 iOS Project Map

Status: `running`

Last updated: 2026-06-08

Plan source: `/Users/<USER>/Downloads/TRON_REARCHITECTURE_PLAN.md`.

## Scope

HRA-8 was the red-gate and map checkpoint for the iOS hierarchy campaign. HRA-9
has since consumed the Engine rows, HRA-10 has consumed the Session rows,
HRA-11 has consumed the UI rows, HRA-12 has consumed the App/Support rows, and
HRA-13 has consumed the test rows. This artifact records the target path for
every live Swift file under `packages/ios-app/Sources` and
`packages/ios-app/Tests`, the SourceGuard checks that now enforce the completed
iOS hierarchy, and the XcodeGen target-membership model that later maintenance
must preserve.

Machine-readable map:

- `packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv`

Coverage after HRA-13:

- `packages/ios-app/Sources`: 361 Swift files
- `packages/ios-app/Tests`: 205 Swift files
- Total mapped Swift source/test files: 566

## Target Phase Ownership

| Phase | Scope |
| ----- | ----- |
| HRA-9 | `Sources/Engine` moves to `Engine/Transport`, `Engine/Protocol`, `Engine/Events`, `Engine/Persistence`, and `Engine/Models`. |
| HRA-10 | `Sources/Session` moves to `Session/Chat`, `Session/Timeline`, `Session/Attachments`, and `Session/Parsing`. |
| HRA-11 | `Sources/UI/Views` moves to feature-owned `UI/Chat`, `UI/Settings`, `UI/Onboarding`, `UI/RuntimeSurfaces`, `UI/Capabilities`, `UI/Components`, and `UI/System`. |
| HRA-12 | `Sources/App` and `Sources/Support` move to app lifecycle/composition and scoped support foundation, diagnostics, pairing, storage, feedback, and share-extension owners. |
| HRA-13 | `Tests` moves to `Infrastructure`, `Engine`, `Session`, `UI`, and `Support` mirrors. |

## SourceGuard Red Gates

`packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests.swift` and its
same-suite extensions contain HRA hierarchy checks that enforce the completed
iOS source/test hierarchy:

- `testIOSTestsMirrorHRASourceBoundaries`

The same file also confirms XcodeGen constraints with
`testXcodeGenKeepsRecursiveIOSTargetMembership`.

## XcodeGen Constraints

`packages/ios-app/project.yml` is the source of truth for iOS target membership.
The app target includes `Sources` recursively with `createIntermediateGroups:
true`; the test target includes `Tests` recursively with
`createIntermediateGroups: true`. Later Swift moves should therefore require
XcodeGen regeneration, not hand-edited `.xcodeproj` membership.

The ShareExtension target has its own source root and explicitly includes
`Sources/Support/Share/SharedContent.swift`. HRA-12 retained that file in
`Support/Share`, so the share-extension include remains valid after XcodeGen
regeneration.

## Open Loops

- HRA-9 consumed the map rows whose target phase is `HRA-9`; those rows now
  live under the target Engine owners and are marked `passed_after_fix`.
- HRA-10 consumed the map rows whose target phase is `HRA-10`; those rows now
  live under the target Session owners and are marked `passed_after_fix`.
- HRA-11 consumed the map rows whose target phase is `HRA-11`; those rows now
  live under feature-owned UI roots and are marked `passed_after_fix`.
- HRA-12 consumed the map rows whose target phase is `HRA-12`; those rows now
  live under app lifecycle, composition, diagnostics, foundation, pairing,
  share, feedback, and storage owners and are marked `passed_after_fix`.
- HRA-13 consumed the map rows whose target phase is `HRA-13`; those rows now
  live under mirrored Engine, Session, UI, Support, and Infrastructure test
  owners and are marked `passed_after_fix`.
