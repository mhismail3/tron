# HRA-8 iOS Project Map

Status: `running`

Last updated: 2026-06-08

Plan source: `/Users/moose/Downloads/TRON_REARCHITECTURE_PLAN.md`.

## Scope

HRA-8 is the red-gate and map checkpoint for the iOS hierarchy campaign. It
does not move Swift production files. It records the target path for every live
Swift file under `packages/ios-app/Sources` and `packages/ios-app/Tests`, adds
SourceGuard tests that fail on the current broad buckets, and confirms the
XcodeGen target-membership model that later move phases must preserve.

Machine-readable map:

- `packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv`

Coverage at HRA-8 creation:

- `packages/ios-app/Sources`: 355 Swift files
- `packages/ios-app/Tests`: 192 Swift files
- Total mapped Swift source/test files: 547

## Target Phase Ownership

| Phase | Scope |
| ----- | ----- |
| HRA-9 | `Sources/Engine` moves to `Engine/Transport`, `Engine/Protocol`, `Engine/Events`, `Engine/Persistence`, and `Engine/Models`. |
| HRA-10 | `Sources/Session` moves to `Session/Chat`, `Session/Timeline`, `Session/Attachments`, and `Session/Parsing`. |
| HRA-11 | `Sources/UI/Views` moves to feature-owned `UI/Chat`, `UI/Settings`, `UI/Onboarding`, `UI/RuntimeSurfaces`, `UI/Capabilities`, `UI/Components`, and `UI/System`. |
| HRA-12 | `Sources/App` and `Sources/Support` move to app lifecycle/composition and scoped support foundation, diagnostics, pairing, storage, feedback, and share-extension owners. |
| HRA-13 | `Tests` moves to `Infrastructure`, `Engine`, `Session`, `UI`, and `Support` mirrors. |

## SourceGuard Red Gates

`packages/ios-app/Tests/Infrastructure/SourceGuardTests.swift` now contains HRA
hierarchy checks that intentionally fail until HRA-9 through HRA-13 complete:

- `testIOSSourcesUseHRAFeatureOwnedHierarchy`
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
`Sources/Support/Share/SharedContent.swift`. HRA-12 may move that shared file
only if it updates `project.yml`, regenerates the project, and proves the share
extension target still compiles.

## Open Loops

- HRA-9 must consume the map rows whose target phase is `HRA-9`.
- HRA-10 must consume the map rows whose target phase is `HRA-10`.
- HRA-11 must consume the map rows whose target phase is `HRA-11`.
- HRA-12 must consume the map rows whose target phase is `HRA-12`.
- HRA-13 must consume the map rows whose target phase is `HRA-13`, decompose
  SourceGuard if it remains over budget, regenerate XcodeGen, and pass the
  SourceGuard target.
