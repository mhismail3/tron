# Structure scorecard (#2297)

Baseline is `047805caf` (the program's start); the pilot column is main after the scripts/tools pilot (other workers' landings included in the size rows). Rows come
from `scripts/tron metrics <rev>` (`M2`, `M3`, `M4.structure`), `scripts/tron layers gateway`
and the pilot's `scripts/tron probe` runs. Lower is better except carded modules and precise units.

| Row | Baseline `047805caf` | Pilot `55490feeb` |
|---|---:|---:|
| Tracked files | 1,930 | 1,943 |
| All lines (every category) | 541,431 | 544,703 |
| Production lines | 247,666 | 247,689 |
| Test lines | 182,038 | 183,377 |
| Tooling lines | 39,743 | 40,501 |
| Docs lines | 16,668 | 16,863 |
| Hand-written files over 500 lines | 219 | 219 |
| Root entries | 15 | 15 |
| Files directly in `scripts/` | 95 | 93 |
| Modules | 99 | 100 |
| Modules without a card | 99 | 83 |
| Cross-module file references | 1,494 | 1,510 |
| Module pairs that reference each other | 622 | 625 |
| Source files no tracked file names (non-Swift) | 58 | 56 |
| Gateway layer pairs: upward / two-way / undeclared | 0 / 1 / 57 | unchanged (no Gateway change) |
| iOS layer pairs | not measured (needs an Xcode index) | not measured (needs an Xcode index) |
| Probed units: precise / cascade / silent | not measurable (no probe) | 52 of 91 decided: 39 / 7 / 6; after fixes, re-probed: 43 / 3 / 6 (2 silent units since given guardians, not yet re-probed) |

Largest files at baseline: `packages/gateway/src/sessions/runtime-registry.integration.test.ts`
(13,350), `scripts/test-ios-test-infrastructure.py` (6,844),
`packages/gateway/src/sessions/run.lock.integration.test.ts` (6,588),
`packages/ios-app/Sources/State/AppModel.swift` (5,500),
`packages/gateway/src/kernel/run/runtime-slot.ts` (4,821).
