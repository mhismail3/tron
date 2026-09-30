# Connection management owner

`ConnectionOwner` owns only the generic account envelope for supported
integration instances under `state/integrations/connections.json`. It does not
own provider credentials, Knowledge records/evidence, connector checkpoints,
assessment cohorts/usage, or remote-effect receipts. Credential values never
enter this state; the envelope contains only an opaque credential reference and
the presentation projection omits that reference. Pi's built-in MCP servers are
not ConnectionOwner instances; their sole configuration authority is Pi's
`mcp.json` (see [MCP servers](mcp.md)).

A provider/account is represented by an opaque instance ID. Two instances of
the same definition therefore have independent account identity, scope, policy,
enablement, and setup operation. There is no generic `enable`/`disable` RPC.
MCP server administration and OAuth sign-in use Pi's built-in MCP and the
separate `mcp.*` RPCs; they do not create connection rows.

Jev is no longer a ConnectionOwner definition or Keychain connector. Knowledge,
session search, and the first-party `jev` tool use Pi's `ModelRuntime.classify()`
with the TypeSafe `jev-latest` classifier and Pi's provider credential store.
Tron retains its qualified pre-dispatch estimate and monthly tagging ledger;
provider credential readiness is owned by Pi and configured through Provider
Settings. Existing persisted `knowledge.jev` connection state is rejected with
an instance-specific setup error rather than migrated or silently reused.

The accepted owner-typed commands are:

- `connections.setup.begin` / `connections.setup.complete` /
  `connections.setup.cancel`;
- `connections.policy.update`; and
- `connections.disconnect`.

Setup completion is bound to one operation ID and instance ID. A repeated pending
setup returns that exact operation only for the same definition and method.
Policy updates require `expectedSetupRevision` from the observed instance; the
owner checks it under its mutation lock, after receipt replay, so stale account
sheets cannot overwrite newer approvals or budgets. All native and Knowledge
callers carry this precondition; an old client missing it fails closed rather
than performing an unconditional write. No persisted-state migration is needed.
Accepted writes have bounded command receipts and replay the exact result only
for the same request hash. Disconnect disables future admission but does not
claim that a provider credential was revoked; revocation remains the credential
owner's contract. Capability status is derived per capability and per instance,
so one unavailable capability does not become a successful empty list or hide
another instance. Availability uses capability effects, not only overall account
health: write capabilities require write approval, paid capabilities require
approval and a positive budget. Knowledge credential/account observations remain
adapter-owned evidence. An unadmitted capability whose credential observation is
`unavailable` reports the Mac Keychain service that owns the missing or
provider-rejected item and directs the user to the agent for the exact account,
because the presentation projection never carries a credential reference.
Availability is not a claim that tools are loaded into every existing
conversation.

## Account envelope ownership

Knowledge connector actions carry the exact `connectionId`; configuration rejects
account/scope/credential fields and updates policy through `ConnectionOwner`.
The provider state is keyed by that instance ID, while its persisted adapter
document omits the generic envelope; `KnowledgeStore` resolves the private
envelope only at the owning adapter boundary. Missing owner admission fails
closed rather than falling back to a provider-keyed account.

Provider-specific Knowledge behavior remains with `KnowledgeStore` and its
connector adapter. Public X capture remains a credential-free source capability,
not a connection instance.
