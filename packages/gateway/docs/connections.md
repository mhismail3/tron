# Connection management owner

`ConnectionOwner` owns only the generic account envelope for an integration
instance under `state/integrations/connections.json`. It does not own provider
credentials, Knowledge records/evidence, connector checkpoints, assessment
cohorts/usage, or remote-effect receipts. Credential values never enter this
state; the envelope contains only an opaque credential reference and the
presentation projection omits that reference.

A provider/account is represented by an opaque instance ID. Two instances of
the same definition therefore have independent account identity, scope, policy,
enablement, setup operation, and runtime admission. A configured instance is
not automatically admitted into a session or child runtime: the runtime owner
must supply an exact `RuntimeBinding` with integration, connection, capability,
session, and generation identity. There is no generic `enable`/`disable` RPC.

The accepted owner-typed commands are:

- `connections.setup.begin` / `connections.setup.complete` /
  `connections.setup.cancel`;
- `connections.policy.update`; and
- `connections.disconnect`.

Setup completion is bound to one operation ID and instance ID. Accepted writes
have bounded command receipts and replay the exact result only for the same
request hash. Disconnect disables future admission but does not claim that a
provider credential was revoked; revocation remains the credential owner's
contract. Capability status is derived per capability and per instance, so one
unavailable capability does not become a successful empty list or hide another
instance.

## Prepared state migration

`connection-migration.ts` contains an explicit, write-free plan builder for
the production Knowledge `state.json` plus catalog-control shape (including
catalog receipts). It extracts account/ref/policy into the connection owner
while preserving provider state (checkpoints, pending identities, cohorts,
usage, and `pendingRemote`) and the global receipt/request-hash map. It rejects
newer, incomplete, malformed, duplicate account/scope, and conflicting state
before a plan is accepted. Hashing sorts object keys recursively, so a nested
provider-state mutation is rejected by `verifyMigrationPlan`.

Publication is an operator-only offline action with separate owner and provider
authority destinations plus a resumable publication marker. It stages the
marker, publishes the owner, records `owner-published`, then publishes the
Knowledge control-shaped provider state and marks the publication complete.
`recoverConnectionMigration` inspects an interrupted publication; it never
runs at Gateway startup, and preparation failure leaves the old Knowledge
authority untouched.

After the owner is active, Knowledge connector actions carry the exact
`connectionId`; configuration rejects account/scope/credential fields and
updates policy through `ConnectionOwner`. The provider state is keyed by that
instance ID, while its persisted adapter document omits the generic envelope;
`KnowledgeStore` resolves the private envelope only at the owning adapter
boundary. Missing owner admission fails closed rather than falling back to a
provider-keyed account.

Provider-specific Knowledge behavior remains with `KnowledgeStore` and its
connector adapter through the explicit migration and corresponding RPC/native
consumer transition. Public X capture remains a credential-free source
capability, not a connection instance.
