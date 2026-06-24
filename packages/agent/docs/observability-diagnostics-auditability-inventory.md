# Observability Diagnostics Auditability Inventory

Status: ODA campaign `complete`; 53 observed surfaces inventoried and
classified across Rust, Swift, scripts, docs, CI, and tests.

Machine-readable inventory:
[`observability-diagnostics-auditability-inventory.tsv`](observability-diagnostics-auditability-inventory.tsv)

## Surface Classes

- `server_trace`: Agent Trace-style records and model-facing trace read
  operations.
- `server_logs`: Durable log ingestion, recent-log queries, redaction,
  truncation, deduplication, and CLI access.
- `session_event`: typed session events and provider request audit payloads.
- `engine_ledger`: invocation ledger, idempotency, catalog changes, grants,
  streams, queues, and replay snapshots.
- `client_diagnostics`: iOS diagnostics bundle, local logs, server-log
  ingestion, hashing, redaction, and feedback preparation.
- `mac_diagnostics`: Mac logs window, feedback issue composition, and redaction.
- `cli_diagnostics`: `tron logs`, `tron status --json`, dev takeover state, and
  machine-readable diagnostics.
- `static_gate`: README, CI, scorecard, evidence, inventory, and ODA invariant
  tests.

## Coverage Policy

ODA-1 is source-audited rather than marker-generated. Rows cover each owner that
stores, exposes, redacts, or verifies trace/log/provider/engine/runtime/client
diagnostic evidence inspected during this slice. Any future ODA change to an
observed owner should update the TSV and the focused static gates in the same
commit.

## Closeout Notes

- ODA-4 closed the direct `logs::recent` filter gap by applying
  session/workspace/trace filters through the event-store owner and returning
  workspace/trace IDs in typed rows.
- ODA-5 added hashed workspace and trace IDs to iOS server-log diagnostics.
- ODA-8 hardened `tron logs` string filters and added CLI workspace/trace
  filtering.
- No restored `system::get_diagnostics`, provider-specific diagnostics API,
  analytics SDK, or automatic upload path is part of the closed inventory.
