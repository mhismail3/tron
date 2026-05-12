# Capability-Only Cutover Verification

This branch is capability-only. Current documentation describes the active
architecture; providers do not have a separate execution path.

## Public Surface

- `/engine` accepts canonical `namespace::function` capability ids only.
- Model providers receive exactly `search`, `inspect`, and `execute`.
- `search`, `inspect`, and `execute` are backed by the live engine catalog and
  durable capability registry/index layer in the engine ledger database.
- Semantic capability search uses the first-party fastembed ONNX/tokenizer
  bundle embedded in the Rust agent binary; it does not download models or read
  mutable runtime model files.
- Mutating or medium/high-risk invocations require an inspection handle,
  expected revision, expected schema digest, and explicit idempotency when the
  target mutates.
- Engine protocol message ids are correlation ids only.

## Server Ownership

- Canonical capability specs live in `packages/agent/src/domains/*/contract.rs`.
- Domain behavior lives in `packages/agent/src/domains/*/`.
- Generic worker transport, catalog, invocation, ledger, and stream mechanics
  live in `packages/agent/src/engine/`.
- `/engine` framing, validation, and subscription routing live in
  `packages/agent/src/transport/`.
- Queue, approval, stream, state, lease, compensation, cron, MCP-derived,
  external-worker, and sandbox paths are capability paths over the same engine
  primitives.
- External/session workers must present scoped worker tokens before visible
  functions are accepted into the catalog.

## Acceptance Gates

Verification must prove:

- providers expose only `search`, `inspect`, and `execute`;
- no production handler-shaped RPC implementation remains;
- no public dotted-method dispatch path remains;
- no engine-native write can execute without an idempotency key;
- high-risk autonomous writes produce approval-required state before execution;
- stream-first event classes do not double-broadcast;
- queue drain and approval resolution preserve original trace, authority,
  parent invocation, idempotency, leases, and compensation metadata;
- model tool schemas are projected from the live engine catalog at each model
  call boundary.
- capability search fails explicitly when the required local vector index is
  unavailable rather than silently falling back to lexical-only search.
