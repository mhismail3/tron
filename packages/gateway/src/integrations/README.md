# gateway/integrations

## Purpose

Read-only projection of retained connection account envelopes and setup operations. This owner does not hold credentials or run provider operations.

## Owns

`ConnectionOwner` reads `<tronHome>/state/integrations/connections.json`. The
[pure L1 contract](../modules/integrations/contract.ts) owns schema/public/private
values and the read-only `ConnectionAccess` consumed by the agent `connections` tool.
`connection-contract.ts` retains runtime validation of persisted state. The missing file is an empty read
projection; the owner never creates, migrates or writes storage.

## Contract

`snapshot()` returns redacted instances, setup operations and the state revision, with
`definitions` and `capabilities` always empty: production has no connection definitions
or adapters. Presentation snapshots omit the opaque credential reference. There are no
connection RPCs or mutations.

## Invariants

- Credential references never leave the owner.
- Reads leave connection-state bytes unchanged. Directories and durable state are
  owner-only; unreadable state refuses rather than silently projecting an empty store.

## Entry points

The agent `connections` tool (`workspace/tron-core-extension.ts`). Production has no
built-in connection definitions or X/Raindrop adapters and advertises no capabilities
for historical instances. Native settings expose MCP servers, not retired Connected
Services setup. `scripts/tron migrate connections-residue` (`connections-residue-migration.ts`)
is the maintainer's one-shot, backed-up removal of retired setup operations, receipts and
Raindrop collection mappings; instances and credential references stay. Dry run unless
`--apply --backup <new dir>`; `--restore --backup <dir>` puts back only bytes it published.
It and the Raindrop mapping validator are deleted once the live run is verified.

## Signals

`GatewayError` reports conflicting or unreadable state. No startup migration, polling
or background credential probe occurs.

## Verify

```bash
scripts/tron verify --module gateway/integrations
scripts/tron test gateway src/e2e/integrations/tests/connections.projection.integration.test.ts
```

The same file proves the residue migration (backup, raced and refused publications,
restore) and the retired RPCs' refusal. The projection test seeds retained historical state, reads it through the real agent
`connections` tool, and proves an empty projection without creating storage, exact
redaction of the credential reference and byte-identical state after the read.

## Not here

Provider owners retain credential resolution and provider activity. This module owns
neither a provider usage ledger nor executable package discovery. Retirement of
unsupported persisted definitions must preserve the existing admission contract rather
than introducing another store or compatibility route.
