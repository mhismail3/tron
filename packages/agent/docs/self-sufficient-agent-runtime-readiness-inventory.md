# Self-Sufficient Agent Runtime Readiness Inventory

Status: **inventory_built_pre_edit**

Base commit audited: `f931c3126a2ee62940f42512278715c9c65c2079`

Branch audited: `codex/self-sufficient-agent-runtime-readiness`

Machine-readable inventory:
[`self-sufficient-agent-runtime-readiness-inventory.tsv`](self-sufficient-agent-runtime-readiness-inventory.tsv)

Full path:
`packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.tsv`.

This inventory was built before SARR source edits. It covers the retained
engine, capability, session runner, durable resource, authority, protocol,
client shell, predecessor scorecard, cleanup guardrail, README, CI, and
evidence surfaces named by the original Self-Sufficient Agent Runtime Readiness
slice.

## Surface Classes

| Class | Meaning |
|---|---|
| `sarr_artifact` | Required SARR scorecard, evidence, inventory, TSV, and invariant target. |
| `execute_primitive` | Provider-visible `capability::execute` contract and operation dispatch. |
| `engine_substrate` | Durable engine ledger, queue, stream, resource, replay, trace, worker, trigger, and invocation substrate. |
| `authored_state` | Durable goals, evidence, decisions, memories, rules, patch proposals, UI surfaces, and materialized files. |
| `authority_promotion` | Grants, policy hashes, promotion contracts, and human-control boundary points. |
| `public_protocol` | Server transport DTOs, route exposure, settings contracts, and iOS protocol DTOs. |
| `client_shell` | iOS generic runtime surface and settings shell boundaries. |
| `predecessor_evidence` | Completed scorecards, evidence manifests, inventories, and invariant targets that SARR treats as source evidence. |
| `static_gate` | Local, GitHub, README, and Rust invariant gates. |
| `absent_guardrail` | Removed or forbidden runtime paths that must not be reintroduced by readiness work. |

## Pre-Edit Findings

- The requested DESI base commit was present and the SARR branch was created
  from it.
- The current engine has durable ledger, queue, stream, resource, grant,
  trace, replay, external worker, trigger, generated UI, and materialized file
  substrate, but SARR does not activate new generated workers or scheduler
  behavior.
- Existing SAA docs and invariants provide evidence for agent-authored durable
  state, generated UI, and promotion boundaries; OPSTC provides evidence that
  off-plan activation, launch, orchestration, and schedule surfaces were removed.
- Public `/engine` transport and iOS DTOs remain thin shells. SARR must not
  document future internal worker/tool/memory machinery as public API.
- Predecessor inventories need rows for SARR artifacts so HRA, PCC, TPC, SACB,
  and DESI coverage remains synchronized.

## Closeout Policy

SARR may document readiness boundaries, create static guards, synchronize
README and predecessor inventories, and record command evidence. It must not add
runtime features, scheduler/autostart behavior, worker execution, promotion
automation, repo-managed skills, public launch surfaces, product panels, or
production deployment automation.
