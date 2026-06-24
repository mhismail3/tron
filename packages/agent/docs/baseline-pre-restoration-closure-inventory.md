# Baseline Pre-Restoration Closure Inventory

Status: `complete`

Machine-readable inventory:
[`baseline-pre-restoration-closure-inventory.tsv`](baseline-pre-restoration-closure-inventory.tsv)

This inventory classifies the current primitive baseline before any feature
restoration begins. It records three kinds of truth:

- active baseline artifacts and gates that must remain current;
- foundational engine/iOS substrate that future features may build on;
- restoration backlog rows for every feature bucket in the feature index.

## Controlled Vocabulary

Record types:

- `artifact`: BPRC-owned scorecard, evidence, inventory, invariant, or README
  wiring.
- `baseline_reference`: immutable commit, branch, tag, or external architecture
  reference.
- `substrate`: current engine/iOS surface that future modules may use.
- `restoration_backlog`: missing feature bucket that is explicitly not present
  in the baseline.
- `entry_contract`: mandatory requirement for future restoration slices.

Classifications:

- `active_current`: current source of truth.
- `source_truth`: source code or rule path that governs current behavior.
- `external_reference`: inspected external reference, not authority over this
  repository.
- `future_restoration`: backlog item to restore later.
- `static_gate`: verification or CI surface.
- `scope_boundary`: explicit no-feature line.

Restoration status values:

- `current_baseline`: retained current behavior.
- `not_in_baseline`: absent by design before restoration.
- `future_contract`: requirement that future restoration work must satisfy.

## iii Alignment Contract

The target baseline is compatible with `iii-hq/iii` in architecture, not in
code import or license inheritance. The invariant we keep is the mental model:
everything is a worker. Worker, function, and trigger are the foundational
runtime nouns. The Tron engine already has a live catalog, workers, functions,
triggers, resources, grants, queues, streams, replay, and generic UI resources.
Restoration work must add capability through those extension points instead of
hardcoded product domains or fixed iOS panels.

## Pre-Restoration Entry Contract

Every future feature restoration slice must define and verify:

- worker or module owner;
- function and trigger contracts;
- resource and event schemas;
- authority and grant policy;
- replay/evidence/rollback strategy;
- iOS parity decision: generic runtime surface, native stable platform view, or
  no iOS surface with rationale;
- tests and static gates;
- docs and README updates;
- migration and retention policy if data is introduced;
- explicit proof that the feature is not a hardcoded harness expansion.

## Restoration Backlog

The TSV contains one `restoration_backlog` row for each feature bucket from
`primitive-baseline-vs-modular-capability-engine-feature-index.md`. Each row is
`not_in_baseline` and points to the future constraint that must be resolved
before implementation.

## Current Boundary

BPRC certifies that the baseline is ready for future restoration planning. It
does not approve any restoration itself. Old product domains, repo-managed
skills, fixed iOS product panels, runtime-authored worker implementation,
learned-memory/rule stores, tool-synthesis runtime paths, and provider-visible
tool widening remain absent.
