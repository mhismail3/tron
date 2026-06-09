# Failure Semantics Evidence Manifest

Status: **active**

Current score: **6/100**

Branch: `codex/primitive-engine-teardown`

This manifest records row checkpoints, commands, findings, and open loops for
the Failure Semantics Campaign.

## Row Evidence

| Row | Status | Change | Verification | Open loops | Commit |
|---|---|---|---|---|---|
| FSC-0 | passed_after_fix | Added the campaign scorecard, inventory, TSV, evidence manifest, invariant target, and README living-doc links. | `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | FSC-1 through FSC-10 remain open implementation rows. | `e9b180fa1` |
| FSC-1 | pending | Not started. | pending | Complete and verify the failure inventory while implementing the source mappings. | pending |
| FSC-2 | pending | Not started. | pending | Add canonical server failure envelope and builders. | pending |
| FSC-3 | pending | Not started. | pending | Add exhaustive mapping tests. | pending |
| FSC-4 | pending | Not started. | pending | Replace direct production event construction. | pending |
| FSC-5 | pending | Not started. | pending | Preserve structured capability and engine result failures. | pending |
| FSC-6 | pending | Not started. | pending | Extend transport error frames. | pending |
| FSC-7 | pending | Not started. | pending | Preserve provider retry semantics. | pending |
| FSC-8 | pending | Not started. | pending | Update iOS decode/projection parity. | pending |
| FSC-9 | pending | Not started. | pending | Preserve failures in durable replay/observability outputs. | pending |
| FSC-10 | pending | Not started. | pending | Add final static guards and full verification evidence. | pending |

## FSC-0 Findings

- Active runtime paths directly construct `TronEvent::TurnFailed` in
  `domains/agent/loop/turn_runner/mod.rs`.
- `TronEvent::TurnFailed` and durable `TurnFailedPayload` still allow optional
  code/category.
- The model responder boundary drops provider status, provider code,
  retry-after, provider identity, model identity, and canonical public code.
- Capability invocation engine errors can become plain text `error_result`
  values with no structured failure details.
- `/engine` WebSocket error frames currently preserve code/details/trace id and
  sanitize messages, but lack canonical category, retryability,
  recoverability, and origin.

## Verification Log

FSC-0 expected command after this checkpoint:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture
```

## Residual Risk

The initial inventory is intentionally conservative. It is enough to start the
campaign but not enough to close FSC-1; the implementation rows must keep
updating the inventory as source-level proof replaces the initial scan notes.
