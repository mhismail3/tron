# iOS Thin Client / Generic Runtime Shell Scorecard

Status: **closed**

Current score: **100/100**

Passing threshold: **100/100**

Branch: `codex/ios-thin-client-generic-runtime-shell`

Base commit: `b44a096295f76a2a2a4b00add2d040982b8a73ec` (`Harden release install rollback discipline`)

Scope: harden the iOS app as a generic `/engine` shell. This slice may remove,
guard, or document iOS drift that source proves stale. It must not add new
server APIs, public `/engine` surfaces, product panels, provider features,
scheduler/autostart behavior, deploy automation, repo-managed skills, or new
app features.

## Artifacts

| Artifact | Status | Purpose |
| --- | --- | --- |
| `packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md` | closed | Weighted ITC adoption gate. |
| `packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md` | closed | Command matrix, source findings, residual risks. |
| `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md` | closed | Human-readable thin-client inventory summary. |
| `packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv` | closed | Machine-readable inventory consumed by static gates. |
| `packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs` | closed | Rust static guard for artifacts, inventory, source boundaries, and gate wiring. |
| `packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+ThinClientShell.swift` | closed | Swift source guard for retained generic shell and deleted product surfaces. |

## Rows

| Row | Name | Weight | Status | Evidence | Notes |
| --- | --- | ---: | --- | --- | --- |
| ITC-0 | Harness, Baseline, and Scope Control | 5 | passed | Branch/base verified before edits; new artifacts are tracked and wired into local/GitHub gates. | No deploy automation was added. |
| ITC-1 | iOS Thin-Shell Inventory | 8 | passed | Inventory TSV covers source roots, test roots, retained surfaces, deleted boundaries, generated project, CI, and predecessor docs. | Rust ITC invariant validates inventory shape and required rows. |
| ITC-2 | Deleted Product Surface Absence | 12 | passed | Existing `SourceGuardTests` plus ITC thin-shell extension cover deleted roots, product clients/state, panels, prompt queue, hook suggestions, memory/rules/skills, audio, media, and tree projections. | No iOS production source rewrite was justified. |
| ITC-3 | Pairing, Server Selection, Token Custody | 10 | passed | Pairing parser/validator/persistor/token-store source and focused tests passed on iOS 26.5. | Bare host validation, reversible setup, and Keychain custody remain source-owned. |
| ITC-4 | Settings Thin-Client / Server Authority | 10 | passed | Settings DTO/state/client/UI docs assert server snapshots and sparse server writes; focused settings tests passed on iOS 26.5. | iOS remains snapshot/mutation UI, not settings authority. |
| ITC-5 | Chat, Session, Timeline Reconstruction | 10 | passed | Chat view model, session repositories, stored-event cache, and `UnifiedEventTransformer` are retained generic surfaces. | Error/capability/timeline/generated renderer batch passed on iOS 26.5. |
| ITC-6 | Generic Capability / Primitive / Runtime Result Rendering | 12 | passed | Capability chips and `GeneratedRuntimeSurfaceView` remain schema/runtime-data driven. | Capability display and generated renderer tests passed on iOS 26.5. |
| ITC-7 | Server Errors, Diagnostics, Logs, Redaction | 10 | passed | `CanonicalFailurePayload`, error projections, transport classifiers, log ingestion, diagnostics redaction, and LogViewer are retained surfaces. | Diagnostics, transport, and personal-info guard passed after evidence redaction. |
| ITC-8 | iOS 26.5 Simulator Coverage and Generated Project Drift | 8 | passed | iPhone 17 Pro iOS 26.5 destination was used for all focused simulator batches. | XcodeGen and generated project drift check passed. |
| ITC-9 | README, iOS Docs, Inventories, Static Guards, and CI Wiring | 8 | passed | README links, iOS docs, HRA/PCC/SACB rows, local/GitHub static gates, and source guards are synchronized. | Full `scripts/tron ci fmt check clippy test` passed after documented inventory repairs. |
| ITC-10 | Evidence, Adversarial Audit, Clean State, and Commit | 7 | passed | Evidence manifest records command results, repair history, simulator destination, and final closeout checks. | Commit is the final state transition for this closed slice. |

Total weight: **100**

## Current Source Finding

The first source scan did not justify iOS production-source edits. The retained
thin-client surfaces already exist in `Sources/App`, `Sources/Engine`,
`Sources/Session`, `Sources/Support`, and `Sources/UI`; deleted fixed-product
surface hits were limited to existing source guard needles and generic
capability argument parsing tests. This checkpoint therefore adds docs and
static guards rather than broad rewrites.

## Residual Risk

No iOS production source changes were made because the source audit did not find
a retained stale product panel/client/state surface. Remaining risk is future
drift: the new Swift SourceGuard, Rust ITC invariant, README/docs links, and
HRA/PCC/SACB inventory rows are the ongoing guardrails for that boundary.
