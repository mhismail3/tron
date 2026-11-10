# Connection management owner

`ConnectionOwner` is a read-only projection of the retained generic account
envelopes under `gateway/integrations/connections.json`. It does not own provider
credentials or execute provider operations, and it never initializes, migrates or
writes that file. Credential values never enter this state: an envelope holds only
an opaque reference, omitted from presentation snapshots.

Production defines no built-in connection adapters and no connection RPCs. X/Raindrop
definitions, capabilities, setup and native Connected Services are absent. Historical
instances, setup operations and credential references remain on disk and are projected
without being advertised as available. The maintainer's one-shot
`scripts/tron migrate connections-residue` removes the retired setup operations,
receipts and Raindrop collection mappings, keeping instances and credential references.
The agent `connections` tool is the owner's only consumer and is read-only.

Pi's built-in MCP servers are not connection instances. Their configuration
authority is Pi's `mcp.json`; MCP administration and OAuth use the separate `mcp.*`
RPCs ([MCP servers](mcp.md)). Model-provider credentials and sign-in likewise stay
with their existing provider owners and Provider Settings.

Jev uses Pi's `ModelRuntime.classify()` and provider credential store, not a
ConnectionOwner definition.

## Snapshot contract

Snapshots carry redacted instances, setup operations and the state revision;
`definitions` and `capabilities` are always empty, so historical instances never
advertise an available capability. Unreadable or
invalid state refuses rather than projecting an empty store. See the
[integrations owner](../src/integrations/README.md) for verification.
