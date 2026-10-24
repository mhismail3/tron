# gateway/integrations

## Purpose

Connection definitions, setup intent, policy and bounded provider admission
observations. This owner does not hold credentials or run provider operations.

## Owns

`ConnectionOwner` serializes mutations and publishes
`<tronHome>/state/integrations/connections.json`. `connection-contract.ts` owns
its schema, validation and public/private values. The missing file is an empty
read projection, not permission to initialize storage during startup or reads.

## Contract

`connections.list` returns definitions, redacted instances, setup operations,
capability availability and the state revision. Explicit mutations are
`connections.setup.begin`, `.complete`, `.cancel`, `connections.policy.update`
and `connections.disconnect`; `GatewayService` routes them to the owner.

Setup carries an opaque credential reference, not credential bytes. The private
instance is available to adapter owners; presentation snapshots omit the
reference. Credential availability and provider identity are observations,
not inferred from setup intent. A disabled, disconnected or unadmitted instance
cannot advertise an available capability.

## Invariants

- Pending setup is completed or cancelled only for its named instance. A late
  completion after cancellation refuses without publication.
- Policy updates compare the observed setup revision under the publication
  mutex. A stale sheet cannot restore an earlier policy.
- Transport command receipts return the original device/method/command result.
  The owner's persisted command receipt additionally fences operation and
  request hash across transport identities and restarts. A rejected command
  leaves connection-state bytes unchanged.
- Disconnect disables the instance without deleting its retained history.
  Directories and durable state are owner-only; unreadable state refuses rather
  than silently rebuilding an empty store.

## Entry points

`GatewayService` serves connection RPCs. Knowledge adapters consume admitted
instances and submit revision-fenced observations. The agent `connections` tool
is read-only; it does not authorize setup, policy or credential changes.

## Signals

`GatewayError` reports invalid input, unsupported adapters and conflicting or
unreadable state. A stale setup revision requires re-reading the authoritative
snapshot. No startup migration, polling or background credential probe occurs.

## Verify

```bash
scripts/tron verify --module gateway/integrations
scripts/tron test gateway src/integrations/tests/connections.lifecycle.lock.integration.test.ts
```

The lifecycle lock crosses a paired loopback WebSocket, real Gateway service,
transport receipts and durable `ConnectionOwner`: read-without-create, setup,
exact replay, stale policy, cancellation/late completion, disconnect, restart,
redaction and an owner request-hash conflict from a newly paired identity.
It leaves a normalized exchange trace at
`packages/gateway/test-results/connections-lifecycle/trace.json` (from repo root).
The fixture uses only a synthetic credential reference and an offline faux
model; it never reads the user's credential store or contacts a provider.

## Not here

Knowledge/provider adapters own credential resolution and provider activity;
transport owns sockets and device-scoped command receipts. This module owns
neither a provider usage ledger nor executable package discovery. Retirement
of unsupported persisted definitions must preserve the existing admission
contract rather than introducing another store or compatibility route.
