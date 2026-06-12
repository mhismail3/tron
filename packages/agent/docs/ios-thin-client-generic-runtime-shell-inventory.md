# iOS Thin Client / Generic Runtime Shell Inventory

Status: **closed**

Scorecard row: `ITC-1`

Machine-readable inventory:
[`ios-thin-client-generic-runtime-shell-inventory.tsv`](ios-thin-client-generic-runtime-shell-inventory.tsv)

Full path: `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv`.

## Source Audit Scope

The inventory was created before source edits from the requested iOS roots,
test roots, generated project surfaces, CI/static-gate surfaces, and existing
scorecards/inventories that mention iOS thin-client boundaries.

Required source roots audited:

- `packages/ios-app/Sources/App`
- `packages/ios-app/Sources/Engine`
- `packages/ios-app/Sources/Session`
- `packages/ios-app/Sources/Support`
- `packages/ios-app/Sources/UI`

Required test roots audited:

- `packages/ios-app/Tests/Infrastructure/Guards`
- `packages/ios-app/Tests/Support/Pairing`
- `packages/ios-app/Tests/Support/Storage`
- `packages/ios-app/Tests/Session/Chat`
- `packages/ios-app/Tests/Session/Timeline`
- `packages/ios-app/Tests/Engine/Events`
- `packages/ios-app/Tests/Engine/Protocol`
- `packages/ios-app/Tests/Engine/Transport`
- `packages/ios-app/Tests/UI/RuntimeSurfaces`
- `packages/ios-app/Tests/UI/Onboarding`
- `packages/ios-app/Tests/UI/System`

## Retained Thin-Client Surfaces

- Pairing/onboarding/server selection: strict bare-host parsing, pairing probe,
  local paired-server metadata, and per-server Keychain token custody.
- Settings: iOS decodes and renders public server settings snapshots, sends
  sparse updates/resets, and keeps local device preferences out of server truth.
- Chat/session/timeline: session list, composer, message rendering, stored-event
  reconstruction, stream cursor diagnostics, and fork lineage from server facts.
- Generic runtime results: capability chips and generated runtime surfaces use
  server/agent-authored schema and runtime data.
- Errors/logs/diagnostics: canonical server failure envelopes, local transport
  classification only when no server response exists, redacted local/server log
  ingestion, and bounded diagnostics bundles.

## Deleted Product Boundaries

Deleted boundaries include fixed product roots, repository-specific panels,
media workflow surfaces, assistant-management panels, extension-source panels,
audio transcription, memory/rules/skills panels, prompt queue and hook
suggestion roots, product clients/state objects, fixed tree-only projections,
and hardcoded product event plugins. These names may appear in historical
evidence and source guard needles only, not ordinary iOS source or tests.

## Generated Project And CI Surfaces

`packages/ios-app/project.yml` remains the XcodeGen source of truth. Because
this checkpoint adds a Swift test file, `packages/ios-app/TronMobile.xcodeproj`
must be regenerated and checked with `git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj`.
The new Rust invariant target is wired into `scripts/tron.d/quality.sh` and
`.github/workflows/ci.yml` with no production deploy automation expansion.

## Closeout State

The ITC scorecard and evidence manifest are closed at 100/100. The retained
inventory remains the source-audited boundary map for iOS thin-client surfaces,
deleted product boundaries, generated project drift, and local/GitHub static
gate wiring.
