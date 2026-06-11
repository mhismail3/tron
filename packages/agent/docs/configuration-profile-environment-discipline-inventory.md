# Configuration / Profile / Environment Discipline Inventory

Status: Complete

Machine-readable inventory:
`packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv`

This inventory covers the original CPE slice: canonical settings, managed
profile defaults, sparse user overrides, environment variables, malformed
configuration, iOS settings parity, README examples, generated defaults, and
runtime load/reset behavior.

## Findings Summary

The Rust settings schema is canonical for internal runtime settings under
`packages/agent/src/domains/settings/profile/types/`. The public paired-client
contract is intentionally smaller and lives in `packages/agent/src/shared/protocol/settings.rs`;
iOS mirrors that public contract through `EngineProtocolTypes+Settings.swift`,
`SettingsState.swift`, and Settings pages.

The slice found and fixed three source-backed risks:

- The managed default profile retained a stale `queueDrainMode` session key.
- Several nested settings structs accepted unknown fields.
- Invalid numeric environment overrides were ignored instead of failing the
  higher-priority environment layer.

No iOS source edit was required because the audited public paired-client surface
was already represented on the Swift decode/update/state/UI path.

## Proof Map

The CPE static gate verifies artifact presence, scorecard closure, evidence
commands, inventory shape, quality/CI wiring, HRA ownership rows, strict
settings decode markers, transactional env override markers, stale default
profile removal, README Settings documentation, and Rust/Swift public settings
parity markers.
