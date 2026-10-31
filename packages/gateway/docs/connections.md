# Connection management owner

`ConnectionOwner` owns generic account envelopes under
`state/integrations/connections.json`. It does not own provider credentials or
execute provider operations. Credential values never enter this state: an envelope
holds only an opaque reference, omitted from presentation snapshots.

Production defines no built-in connection adapters. X/Raindrop definitions,
capabilities and native Connected Services setup are absent. Historical instances
and credential references remain on disk without being advertised as available;
retirement does not migrate them or delete credentials. Unsupported setup refuses.
The agent `connections` tool is read-only.

Pi's built-in MCP servers are not connection instances. Their configuration
authority is Pi's `mcp.json`; MCP administration and OAuth use the separate `mcp.*`
RPCs ([MCP servers](mcp.md)). Model-provider credentials and sign-in likewise stay
with their existing provider owners and Provider Settings.

Jev uses Pi's `ModelRuntime.classify()` and provider credential store, not a
ConnectionOwner definition. Existing legacy `knowledge.jev` rows stay hidden and
refuse instance-specific setup. The owner's existing accepted-write retirement
removes those rows and setup operations in the same revision; reads and rejected
writes remove nothing. No Keychain item is read or deleted by that retirement.

## Generic envelope contract

An opaque instance ID separates each account's scope, policy, enablement and setup
operation. There is no generic `enable`/`disable` RPC. Owner commands are:

- `connections.setup.begin` / `connections.setup.complete` /
  `connections.setup.cancel`;
- `connections.policy.update`; and
- `connections.disconnect`.

Setup completion binds one operation and instance. A repeated pending setup returns
that operation only for the same definition and method. Policy updates require the
observed `expectedSetupRevision`, checked under the mutation lock after receipt
replay; a missing or stale precondition refuses. Accepted writes retain bounded
command receipts and replay only the identical request hash. Disconnect disables
admission but never claims to revoke credentials.

Snapshots retain redacted instances and setup operations, with capability
availability derived only from supported definitions and admitted effects. Unknown
historical definitions cannot manufacture available capabilities. Credential
readiness and provider activity remain adapter-owned observations, not consequences
of setup intent or a claim that a tool is loaded into every conversation.

The real loopback lifecycle regression explicitly injects historical test-only
definitions. Its separate production-default case proves absent advertisements,
refused vendor operations and unchanged stored credential references. See the
[integrations owner](../src/integrations/README.md) for verification.
