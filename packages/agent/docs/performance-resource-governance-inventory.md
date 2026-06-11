# Performance / Resource Governance Inventory

Status: Complete. Initial inventory was built before PRG source edits; this
file now records the final post-patch proof state.

This inventory covers the resource surfaces audited for the PRG hardening slice:
provider parsers, stream accumulators, agent-side per-turn state, streaming
journals, `/engine` delivery, logs, diagnostics, startup/shutdown, storage
retention, retry loops, and runtime services.

Machine-readable inventory: `packages/agent/docs/performance-resource-governance-inventory.tsv`

## Findings Summary

Confirmed source gaps before PRG patches and final actions:

- Shared provider SSE parser buffered bytes until newline without a line
  ceiling. PRG added `DEFAULT_MAX_SSE_LINE_BYTES`, parser errors, and canonical
  stream error propagation.
- Provider stream accumulators append text, thinking, signatures, and capability
  arguments without hard byte ceilings. Kimi and Ollama have local accumulator
  paths that did not use the shared accumulator. PRG added shared byte/item
  ceilings and local Kimi/Ollama fail-closed guards.
- Agent stream state and per-turn streaming journal recovery accumulate text,
  thinking, and capability payloads without hard ceilings. PRG added per-turn
  byte ceilings and an 8 MiB streaming journal WAL budget.
- `/engine` async push delivery awaited a full outbound queue indefinitely. PRG
  added a bounded async send timeout and overload metric.
- `tron logs --limit` accepted any positive integer while server-side log reads
  are capped at 1,000 rows. PRG added matching CLI validation.

Already bounded or retained surfaces:

- `/engine` request/poll page size is capped at 500 rows.
- Server `logs::recent` rejects limits above 1,000 rows.
- Client log ingest batches and messages are bounded.
- Structured diagnostic log data flows through blob-backed payload refs with
  verbose retention metadata.
- Startup retention, shutdown checkpointing, storage size budget enforcement,
  provider retry attempts/backoff, queue lifecycle, stream cursor pagination,
  and shutdown task tracking already have explicit governance surfaces.
- PRG static guards now keep the new bounds, docs, local/GitHub gates, and
  predecessor invariants from silently drifting.

## Inventory Columns

- `path`: audited source, script, document, or test path.
- `surface_kind`: the resource-governance surface type.
- `owner`: module or subsystem owner.
- `resource_dimension`: memory, queue, disk, log, stream, retry, task, or
  diagnostics resource being governed.
- `current_bound_proof`: source-grounded pre-patch bound or absence of one.
- `risk`: failure mode if the resource is oversized or slow.
- `proof_target`: test, static guard, or source proof used for closeout.
- `action_rationale`: patch or retain rationale.
