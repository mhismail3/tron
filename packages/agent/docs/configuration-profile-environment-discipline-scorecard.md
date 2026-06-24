# Configuration / Profile / Environment Discipline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/configuration-profile-environment-discipline-current`
Baseline: `codex/performance-resource-governance-current` at `c1d266e224f87fb57f18f85846f2c8931e038ec8` (`Harden performance resource governance`)
Lineage: DSEMD `fccdbbd54161e82bc4c837d68b7c4d0ca62be0cf` -> PPACD `30dbf4b6bfd45edbee00ed7e55be2fb1ed964b19` -> post-PPACD reconciliation `c7deea13d1bcb37b0348406329d503c043933ae6` -> PMBD `c99a5439d9538dfc88de2883bf6b4383c8e1c037` -> PERF `c1d266e224f87fb57f18f85846f2c8931e038ec8`

Stale branches quarantined as quarry-only: `codex/configuration-profile-environment-discipline`, `codex/configuration-profile-environment-discipline-recovery`.

| Row | Name | Weight | Status | Closure |
| --- | --- | ---: | --- | --- |
| CPE-0 | Baseline, lineage, and stale-branch quarantine | 5 | passed | Verified the requested PERF baseline and ancestor chain by branch refs, created the current branch from `c1d266e22`, and recorded stale CPE branches as quarry-only. |
| CPE-1 | Whole configuration/profile/env inventory | 8 | passed | Added structured markdown and TSV inventory covering Rust settings, profile documents, default seeding, sparse overlays, env overrides, bootstrap/runtime, scripts, README, iOS DTO/state/UI/tests, Mac wrapper surfaces, CI, generated artifacts, and predecessor audit links. |
| CPE-2 | Canonical settings schema and defaults | 12 | passed | Tightened nested Rust settings structs with `deny_unknown_fields`, removed inert `settings.session.queueDrainMode` from bundled defaults, and added a default-profile parity test against `TronSettings::default()`. |
| CPE-3 | Sparse user overlay and atomic update discipline | 12 | passed | Existing `SettingsStore` tests prove serialized atomic writes, reset, cache reload, malformed-file preservation, partial update merge, and no default-copy reset; CPE inventory and static gate anchor the owning code. |
| CPE-4 | Profile inheritance, versioning, seeding, and recovery | 10 | passed | Existing profile/constitution tests prove inheritance, current-version checks, active profile failure, managed default restoration, and malformed profile rejection; Mac wrapper seed now emits current v3 sparse user-profile metadata. |
| CPE-5 | Environment variable ownership and override discipline | 10 | passed | Inventory records every retained `TRON_*` and settings-affecting env surface, owner, precedence, and validation behavior; path helpers reject unsafe `TRON_HOME_NAME` and settings env parsers are range-tested. |
| CPE-6 | iOS settings parity | 12 | passed | Swift settings decode/update/state/UI/tests are inventoried; decoder now fails on missing or mistyped server-owned fields instead of masking malformed server state with local defaults. |
| CPE-7 | Malformed config safe failure and error surfacing | 10 | passed | Added nested unknown-key Rust regressions, stale default-profile drift regression, and Swift malformed payload regressions; existing tests cover invalid TOML, wrong `[settings]` shape, invalid provider config, bad numeric ranges, and sparse overlay corruption. |
| CPE-8 | Docs, README, predecessor inventories, and CI wiring | 9 | passed | Added CPE docs, README entries, CI/local static gate wiring, profile docs updates, and predecessor inventory links for current lineage and retained-source inventories. |
| CPE-9 | Targeted static gates and verification harness | 8 | passed | Added `configuration_profile_environment_discipline_invariants.rs` with scorecard, inventory, default drift, env ownership, iOS parity, sparse overlay, stale branch, README, and predecessor wiring checks. |
| CPE-10 | Broad closeout and clean commit | 4 | passed | Focused Rust settings/profile tests passed; CPE invariant, iOS 26.5 settings protocol tests, generated project drift check, full CI, personal-info guard, diff hygiene, ignored-file hygiene, and clean status are recorded in the evidence manifest. |

## Corrections Made

- The bundled default profile no longer contains `settings.session.queueDrainMode`; there is no Rust runtime owner for that key.
- Rust nested settings schema types now reject unknown keys so stale profile settings fail safely instead of being silently ignored.
- iOS `ServerSettings` decoding now requires the server-owned fields used by the iOS settings UI and rejects malformed payloads.
- The Mac wrapper's missing-overlay seed now matches the v3 sparse user profile shape and does not inherit managed defaults.
