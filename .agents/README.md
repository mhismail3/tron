# Tron agent guidance

Skills in `.agents/skills/` are the repository-canonical agent guidance. Keep
implementation truth in the owning source and package documentation; skills
route work and enforce evidence and safety boundaries rather than duplicating
volatile implementation inventories.

## Platform skill

- `tron-ios` — required for iOS build, test, simulator, signing, archive,
  physical-device, scheme, configuration, and artifact work. Detailed truth
  remains in `packages/ios-app/docs/`.

## Engineering audit suite

These skills are read-only. Use the narrowest owner for the question.

| Skill | Use |
|---|---|
| `tron-documentation-auditor` | Documentation trust, navigation, claims, and canonical ownership |
| `tron-codebase-auditor` | Broad security, delivery, maintainability, concurrency, and lifecycle health |
| `tron-test-suite-auditor` | Test value, risk coverage, isolation, oracles, and lifecycle |
| `tron-architecture-auditor` | Implemented boundaries, contracts, dependencies, and ownership |
| `tron-persistence-auditor` | Canonical stores, consistency, durability, bounds, and resource lifecycle |

## Engineering optimization suite

These skills may change only the user-approved source/test/documentation scope.
They never authorize Gateway lifecycle transitions, deployment, release, app
replacement, device install, production access, unapproved persisted state, or
OS suspension of Gateway-owned work.

| Skill | Use |
|---|---|
| `tron-performance-optimizer` | A measured bottleneck with a reproducible before/after metric |
| `tron-dependency-upgrader` | Version, lockfile, runtime, or toolchain maintenance |
| `tron-code-modernizer` | Proven net-value replacement or removal of one bounded mechanism |
| `tron-benchmark-comparator` | Symmetric A/B choice between alternatives |
| `tron-surgical-change-implementer` | Smallest complete implementation of one approved product change |

Choose performance optimization for a known bottleneck and benchmark comparison
for an unbiased choice. Choose dependency upgrade for version movement, code
modernization for a justified capability replacement, and surgical change for
ordinary bounded delivery.

Run `scripts/personal-info-guard.sh` and `scripts/check-agent-policy.sh` before finishing. Upstream adaptation
provenance and license terms are recorded in `skills/NOTICE.md`.
