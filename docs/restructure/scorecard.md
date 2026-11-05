# Structure scorecard (#2297)

Baseline is `047805caf` (the program's start); current is the latest pilot landing. Rows come
from `scripts/tron metrics <rev>` (`M2`, `M3`, `M4.structure`), `scripts/tron layers gateway`
and the pilot's `scripts/tron probe` runs. Lower is better except carded modules and precise units.

| Row | Baseline `047805caf` | Current |
|---|---:|---:|
| Tracked files | 1,930 | |
| All lines (every category) | 541,431 | |
| Production lines | 247,666 | |
| Test lines | 182,038 | |
| Tooling lines | 39,743 | |
| Docs lines | 16,668 | |
| Hand-written files over 500 lines | 219 | |
| Root entries | 15 | |
| Files directly in `scripts/` | 95 | |
| Modules | 99 | |
| Modules without a card | 99 | |
| Cross-module file references | 1,494 | |
| Module pairs that reference each other | 622 | |
| Source files nothing names (non-Swift) | 58 | |
| Gateway layer pairs: upward / two-way / undeclared | 0 / 1 / 57 | |
| iOS layer pairs | not measured (needs an Xcode index) | |
| Probed units: precise / cascade / silent | not measurable (no probe) | |

Largest files at baseline: `packages/gateway/src/sessions/runtime-registry.integration.test.ts`
(13,350), `scripts/test-ios-test-infrastructure.py` (6,844),
`packages/gateway/src/sessions/run.lock.integration.test.ts` (6,588),
`packages/ios-app/Sources/State/AppModel.swift` (5,500),
`packages/gateway/src/kernel/run/runtime-slot.ts` (4,821).
