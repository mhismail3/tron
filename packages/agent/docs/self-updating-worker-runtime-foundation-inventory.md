# Self-Updating Worker Runtime Foundation Inventory

Status: `complete`

Machine-readable inventory:
[`self-updating-worker-runtime-foundation-inventory.tsv`](self-updating-worker-runtime-foundation-inventory.tsv)

This inventory records the first post-BPRC restoration substrate. It classifies
the new package lifecycle surfaces and the boundaries that must remain absent.

## Controlled Vocabulary

Record types:

- `artifact`: SUWRF scorecard, evidence, inventory, invariant, or README wiring.
- `source`: implementation path that owns lifecycle behavior.
- `resource_kind`: generic engine resource kind used for lifecycle state.
- `boundary`: explicit no-feature or no-sprawl line.
- `validation`: focused test, invariant, or closeout command.

Classifications:

- `active_current`: current source of truth.
- `static_gate`: test or CI-owned guard.
- `scope_boundary`: behavior intentionally absent from this slice.
- `generic_visibility`: iOS/server visibility through existing generic surfaces.

## Lifecycle Contract

The package lifecycle owner is `domains::worker_lifecycle`, not
`engine::runtime::external_workers`. `/engine/workers` remains a protocol for
already-running workers to register functions and triggers. Lifecycle launch
may mint a scoped token and start a local process, but conformance is accepted
only after the worker reconnects through the existing protocol and the live
catalog matches the package manifest.

Full package validation verifies `packageDigest` against a deterministic
source-tree digest of every regular file below the canonical package source
root. Symlinks and other non-regular paths fail closed; OS metadata is ignored;
there are no excluded files.

Stopping a tracked launch attempt marks that launch attempt `stopped` and
returns the package and installation resources to `enabled` so a trusted caller
can relaunch immediately. If process ownership is missing, stop fails without
writing clean stopped evidence. Startup reconciliation marks durable
`launching`/`running` attempts `unhealthy` with ownership-loss evidence and
returns the package and installation records to `enabled`.

The lifecycle domain is intentionally split by primitive owner:
`authority.rs` owns trusted-apply checks, `manifest.rs` owns package schema and
root validation, `launcher.rs` owns local process isolation and conformance,
`resources.rs` owns generic resource/event evidence, and `handlers.rs` owns
state transitions. The root `mod.rs` is wiring and constants only.

## Resource Kinds

SUWRF adds these generic resource kinds:

- `worker_package`
- `worker_package_installation`
- `worker_package_proposal`
- `worker_package_conformance_report`
- `worker_launch_attempt`

These records are generic resources and lifecycle stream events, so iOS can
observe them without fixed native product panels.

## Current Boundary

SUWRF does not restore MCP, skills, memory, hooks, rules, web/browser research,
scheduler, subagents, prompt library, program execution, fixed iOS product
panels, or provider-visible tool widening. Later approved Phase 2 restorations
must be tracked in the Phase 2 inventory and remain outside SUWRF's
worker-lifecycle scope. Agent self-adaptation in this slice means inert
proposals plus trusted apply paths, not autonomous code activation.
