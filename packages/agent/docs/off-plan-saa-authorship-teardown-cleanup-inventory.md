# Off-Plan SAA Authorship Teardown Cleanup Inventory

Status: `complete`

Machine-readable inventory:
[`packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv`](off-plan-saa-authorship-teardown-cleanup-inventory.tsv)

## Classification Policy

| Classification | Meaning |
| --- | --- |
| `delete` | Surface exists only to support off-plan SAA as completed current architecture and is removed. |
| `revert_to_pre_saa` | Surface existed before SAA and is returned to its pre-`e781a6aef` behavior or wording. |
| `retain_generic_preexisting` | Surface predates SAA and remains required by retained primitive-engine behavior. |
| `retain_with_rewording` | Surface remains but is reworded so future self-adapting-agent work is successor/readiness scope, not current completed architecture. |

## Source-Grounded Findings

- `packages/agent/src/domains/capability/operations/resource.rs` was added by
  `e781a6aef` and is deleted as SAA execute-surface widening.
- `resource_create`, `resource_update`, `resource_link`, `resource_inspect`, and
  `resource_list` were added to `capability::execute` provider schema,
  dispatcher, validation, OpenAI clarification, README, and SAA tests by
  `e781a6aef`; they are removed from active provider-visible surfaces.
- `agent_memory` and `agent_rule` built-in resource definitions and worker
  namespace claims were added by `e781a6aef`; they are removed from active
  runtime substrate.
- Generic resource primitives, stores, validation, wrappers, and preexisting
  resource kinds such as artifact, goal, decision, claim, evidence, ui_surface,
  materialized_file, patch_proposal, execution_output, and agent_result predate
  `e781a6aef`; they remain.
- Active predecessor inventories are reconciled to remove SAA rows and add OPSAA
  cleanup rows. Historical evidence files may discuss future/successor
  self-adapting-agent scope, but active README/inventories must not present SAA
  as completed current architecture.

## Required Retained Primitive Operations

`capability::execute` remains limited to these model-visible operations:
`observe`, `state_get`, `state_set`, `state_list`, `file_read`, `file_write`,
`process_run`, `trace_list`, `trace_get`, `log_recent`, and
`replay_manifest`, plus inspect/evidence-only `catalog_search`,
`catalog_inspect`, and `catalog_conformance`.

The underlying engine `resource::*` primitive worker remains available to
trusted engine callers. This cleanup only removes the off-plan provider-facing
SAA adapter and SAA-specific memory/rule resource kinds.
