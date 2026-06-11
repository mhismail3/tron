# Configuration / Profile / Environment Discipline Inventory

Status: Complete

Scorecard:
[`configuration-profile-environment-discipline-scorecard.md`](configuration-profile-environment-discipline-scorecard.md)

Evidence:
[`configuration-profile-environment-discipline-evidence-manifest.md`](configuration-profile-environment-discipline-evidence-manifest.md)

Machine-readable inventory:
`packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv`

## Scope

This inventory was built before source edits for the CPE slice. It covers the
Rust settings/profile schema, profile default seeding and loading, sparse user
overrides, settings capability DTOs, README settings examples, iOS public
settings parity, intentional environment-variable surfaces, local/GitHub static
gates, and HRA ownership rows for the new CPE artifacts.

## Closed Findings

- Rust server settings were strict, but several nested settings structs accepted
  unknown fields. The touched nested settings structs now use strict serde
  unknown-field rejection.
- The managed default profile carried a stale `queueDrainMode` key under
  `[settings.session]`, while Rust `SessionSettings` is empty. The stale key is
  removed and the bundled default profile is tested against Rust defaults.
- Settings environment overrides were hard-coded in the loader and malformed
  `TRON_HEARTBEAT_INTERVAL` values were logged and ignored instead of failing
  closed. Overrides now use an explicit allowlist and transactional parsing.
- iOS settings parity already narrows to the public server settings DTO and is
  covered by existing Swift tests; no public settings field changed in this
  slice, so no iOS settings/protocol/UI source files were touched.

## Inventory

The TSV is the authoritative machine-readable row set. It uses this schema:

`id`, `path`, `surface_kind`, `owner`, `configuration_dimension`,
`current_source_of_truth`, `current_default_override_env_behavior`, `risk`,
`proof_target`, and `action_rationale`.
