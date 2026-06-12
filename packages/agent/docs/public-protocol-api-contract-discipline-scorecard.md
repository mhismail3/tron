# Public Protocol API Contract Discipline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/public-protocol-api-contract-discipline-current`
Baseline commit: `fccdbbd54161e82bc4c837d68b7c4d0ca62be0cf`

Evidence manifest:
[`public-protocol-api-contract-discipline-evidence-manifest.md`](public-protocol-api-contract-discipline-evidence-manifest.md)

Inventory:
[`public-protocol-api-contract-discipline-inventory.md`](public-protocol-api-contract-discipline-inventory.md)
and
[`public-protocol-api-contract-discipline-inventory.tsv`](public-protocol-api-contract-discipline-inventory.tsv)

Invariant target:
[`../tests/public_protocol_api_contract_discipline_invariants.rs`](../tests/public_protocol_api_contract_discipline_invariants.rs)

## Scope

This slice covers public `/engine` transport contracts, public method metadata,
wire request/response frames, public invocation context, delegated child result
shape, canonical failure/event payload parity, settings/auth/model/session DTO
inventory, iOS protocol decoders/encoders, transport client boundaries, README
truth, and static gate wiring. It does not add provider/model-boundary features,
performance work, release/install automation, product panels, successor
self-adapting-agent behavior, generated workers, deploy automation, or public
launch/scheduler surfaces.

## Scenario Ledger

| Row | Name | Weight | Status | Closure evidence |
| --- | --- | ---: | --- | --- |
| PPACD-0 | Harness, Base, and Scope Control | 5 | passed_after_fix | Current-lineage branch, PPACD docs, invariant target, README, local quality script, GitHub CI, and predecessor inventory rows are present. |
| PPACD-1 | Protocol Surface Inventory and Ownership Map | 8 | passed_after_fix | Inventory covers Rust `/engine`, shared protocol/server DTOs, settings/auth/model/session DTOs, iOS protocol/transport/event DTOs, docs, gates, and predecessor inventories. |
| PPACD-2 | `/engine` Message Grammar and Version Negotiation | 10 | passed_after_fix | Existing strict socket decoder tests plus PPACD source guards keep message grammar, protocol version, and public context fields narrow. |
| PPACD-3 | Public Method Catalog and Canonical Capability Routing | 10 | passed_after_fix | Static guards keep the public method set limited to `discover`, `inspect`, `watch`, `invoke`, and `promote`, with strict schemas and canonical `engine::` routing. |
| PPACD-4 | Public Context, Authority, Runtime Metadata, and Idempotency Boundary | 12 | passed_after_fix | Swift public invocation context no longer models authority/runtime metadata, public frames encode only scope fields, and Rust `invoke` schema matches the strict wire context. |
| PPACD-5 | Response, Error, and Canonical Failure Envelope Parity | 10 | passed_after_fix | Delegated child responses no longer emit worker/catalog revision metadata, strict response schema documents the public child envelope, and failure decoding tests remain covered. |
| PPACD-6 | Event Payload, Stream Frame, Cursor, and Subscription Contract Parity | 10 | passed_after_fix | Inventory and existing socket/event tests cover stream cursor, topic, ACK, poll, trace, parent invocation, and neutral server event payload parity. |
| PPACD-7 | Settings/Auth/Model/Session DTO Server-iOS Parity | 10 | passed_after_fix | DTO inventory records settings/auth/model/session public surfaces and existing settings/auth protocol tests remain part of closeout coverage. |
| PPACD-8 | iOS Transport Client Narrowness and Decoder Strictness | 8 | passed_after_fix | iOS protocol tests on the iOS 26.5 simulator execute the new frame-encoding and child-decoder guards. |
| PPACD-9 | Negative Guards Against Internal Leakage and Compatibility Drift | 8 | passed_after_fix | PPACD invariant rejects reintroduced Swift authority/runtime fields, permissive Rust `invoke` context schemas, internal child metadata, missing inventory rows, and stale wiring. |
| PPACD-10 | Evidence, Broad Verification, and Clean Commit | 9 | passed_after_fix | Focused Rust/iOS tests, prior slice invariant reruns, broad CI, personal-info guard, generated project drift, whitespace, ignored-file, and clean status checks are recorded in the evidence manifest. |

Total weight: **100**

## Source Findings

- Rust `WireContext` already denied unknown public context fields, but
  `contracts.rs` still advertised permissive `invoke` request and nested
  `context` schemas. The public contract now sets both boundaries to
  `additionalProperties: false` while leaving function payloads target-defined.
- iOS `EngineInvocationContext` still exposed `authorityScopes` and
  `runtimeMetadata`, and public invoke/subscribe/poll frames encoded that type
  directly. The public Swift context now contains only `sessionId`,
  `workspaceId`, `traceId`, and `parentInvocationId`.
- Delegated child invoke results exposed `workerId`, `functionRevision`, and
  `catalogRevision`. The Rust public child envelope and Swift decoder now keep
  only public invocation identity, target function id, trace, value, error, and
  replay identity.
- The original PPACD branch name was occupied by a stale incompatible local
  branch; this slice was implemented on the current-lineage branch above.

## Verification Summary

The evidence manifest records the exact commands and results used for closure,
including the iOS 26.5 simulator run that executes the actual protocol test
class. A filename-shaped iOS test selector was also tried and returned success
with zero executed tests; it is retained as a corrected finding, not closure
evidence.
