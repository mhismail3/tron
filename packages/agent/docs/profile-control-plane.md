# Profile Runtime Control Plane

Profiles are Tron runtime control-plane documents. They shape a session or child
process, but they are not a capability catalog. Live capability truth lives in
the engine catalog, durable capability registry, vector index, plugin manifests,
bindings, and audit ledger.

## Schema v3

Profile schema v3 separates provider primitives from executable worker
capabilities:

- `primitiveSurfacePolicies.*` controls only the provider-facing primitives:
  `search`, `inspect`, and `execute`.
- `capabilityExecutionPolicies.*` controls real capability execution by
  contract, implementation, plugin, risk, effect, trust tier, and the search and
  primer policies used by the capability primitives.
- `capabilitySearchPolicies.*` controls capability search behavior such as
  lexical/vector mode, result limits, and explicit degraded behavior.
- `capabilityContextPrimerPolicies.*` controls generated first-party capability
  recipe context.

This split prevents the old ambiguity where one allowlist could mean either
model-visible primitives or concrete actions such as `filesystem::read_file`.

## Managed Defaults

The managed `default` profile is regenerated from the bundled repository copy
when its source-owned files change. Managed child profiles (`normal`, `chat`,
and `local`) inherit the default profile and override only their runtime control
decisions. The mutable `user` profile remains sparse and is reserved for
`[settings]` overrides.

Startup rejects pre-v3 runtime policy fields rather than translating them.
Existing sparse user settings are preserved; old v2 runtime policy overrides are
not interpreted.

## Entrypoints And Processes

Every entrypoint and process references both policy layers:

- `primitiveSurfacePolicy` selects the model primitive surface.
- `capabilityExecutionPolicy` selects concrete execution constraints.

Context policies may override both ids when local-model or transform contexts
need a narrower runtime shape. Model-backed child processes use the same split
as main sessions, so subagents, hooks, automations, summarizers, and capability
workers cannot accidentally receive concrete capability restrictions through a
provider primitive policy.

## Settings

Profiles still embed `[settings]` so a profile snapshot explains both model
runtime behavior and server/iOS defaults. `settings.update` writes sparse user
overrides to `profiles/user/profile.toml`; managed defaults remain source-owned.
Every new server setting still requires iOS settings parity.

## Custom Profile Shape

Custom profiles should inherit the managed default and override the smallest
surface necessary:

```toml
version = "3"
name = "my-profile"
managed = false
profileClass = "custom"
inherits = ["default"]
authProfile = "default"

[entrypoints.main]
prompt = "prompts/core.md"
primitiveSurfacePolicy = "default"
capabilityExecutionPolicy = "default"
```

Use `primitiveSurfacePolicies` only for `search`, `inspect`, and `execute`.
Use `capabilityExecutionPolicies` for contracts, implementations, and plugins:

```toml
[primitiveSurfacePolicies.localModel]
allowedPrimitives = ["search", "inspect"]

[capabilityExecutionPolicies.readOnlyWorkspace]
searchPolicy = "hybridLocal"
contextPrimerPolicy = "coreFirstParty"
allowedContracts = ["filesystem::read_file", "filesystem::list_dir"]
maxRisk = "low"
```

Arrays replace parent arrays during inheritance; include the complete desired
list when overriding an array.

## Invariants

- Provider-facing tools remain exactly `search`, `inspect`, and `execute`.
- Profile policy never enumerates first-party capabilities as provider tools.
- Concrete execution restrictions are contract, implementation, or plugin
  scoped.
- Live capability recipes and availability are generated from the registry, not
  hand-maintained profile comments.
- No v2 compatibility reader or alias is accepted.
