# gateway/admin

## Purpose

The Gateway's administration owners: the settings model (one declared key per
setting, resolved over layers and changed through one audited, tiered path) and
the Mac-side admin services: trust, provider auth, packages and resources, MCP,
custom models, Gateway updates, iOS installs, Mac replacement and diagnostics.

## Owns

| Area | Files |
|---|---|
| Settings schema and vocabulary | `settings-schema.ts` (`KEYS`, `RECORD_SUBJECTS`), `settings-types.ts` |
| Resolution and presentation | `settings-resolver.ts`, `settings-model.ts` (`SettingsModel`), `settings-presentation.ts` |
| Change path and policy | `settings-model.ts` (`SettingsChangePath`), `settings-record.ts`, `settings-approvals.ts`, `settings-risk.ts` |
| Appliers and outside writers | `project-settings-writer.ts`, `trust-service.ts`, `settings-outside.ts` (`OutsideChanges`) |
| The agents' `settings` tool and web mark | `tron-settings-extension.ts` |
| Provider auth and model catalog | `auth-broker.ts`, `model-config-service.ts`, `global-provider-resources.ts` |
| Packages, extensions, hooks, tools | `package-service.ts`, `package-provides.ts`, `session-free-extensions.ts`, `hook-resources.ts`, `tool-catalog.ts` |
| MCP administration | `mcp-admin-service.ts` |
| Install and lifecycle projections | `gateway-update-service.ts`, `ios-device-install-service.ts`, `ios-device-install-helper.ts`, `mac-replace-service.ts`, `diagnose.ts` |
| Shared admission | `document-admission.ts` (`COMMAND_ID`) |

Durable stores: `<tronHome>/gateway/settings/` (`changes/`, `approvals.json`,
`observed.json`, `floors.json`, `gateway.json`), `<tronHome>/gateway/home/profile.json`
(typed Profile values) and the pi agent directory files it applies
(`<tronHome>/agent/settings.json`, `trust.json`, `mcp.json`, `models.json`).

## Contract

`settings-module.ts` owns the settings extension descriptor. Its request/result
vocabulary is the [kernel settings contract](../kernel/settings/README.md); the
session resolves its actor and settings owner at every call.

The full settings contract (foundations, layers, the generated key table,
timing, change path, tiers, outside changes, project writes, Home profile,
presentation) is [docs/settings-contract.md](../../docs/settings-contract.md).
In short:

- **One key, declared once on the Gateway** (F1). The schema holds type,
  group, allowed layers, timing, effect point, floor, writers, redaction and
  display. iOS renders keys generically; a new key needs no iOS release.
- **Uniform layers** (F4): **Chat > Home profile > Project > Mac > Built-in**,
  top wins, among the layers the target has and the key allows. Ordinary chats
  have no Profile; Home's chat has no Project. The effective value is computed,
  never stored; fixed keys are captured into the Chat layer at start with
  provenance.
- **Each store is the truth** (F2). The change record is audit and undo only.
- **One change path, three tiers** (F3): quiet, notify, approve;
  `tier = max(floor + web, assessment)`.

RPCs (shapes in the [Gateway README](../../README.md)): `settings.resolve`,
`settings.options`, `settings.change` (with `dryRun`), `settings.undo`,
`settings.applyAgain`, `settings.history`, `settings.approvals`,
`settings.decide`, plus `home.profileChange` for learned-profile notes.
Broadcasts: `settings.changed`, `trust.changed`, `mcp.changed`,
`models.customChanged`. Agents reach the same path through the `settings` tool
(a thin client of resolve and change); Home's tool may target a delegated
worker by `taskId`.

Ports in: `gateway-main.ts` wires `SettingsModel`, `SettingsChangePath`,
`OutsideChanges` and the risk evaluator; `GatewayService` dispatches the RPCs,
pushes and broadcasts; `RuntimeSlot` supplies the Chat-layer applier, fence and
running-worker `announce`; Home supplies `HomeProfileItems` for learned notes.

## Invariants

- Every write of a declared key or record subject goes through
  `SettingsChangePath`; there are no per-key setters and no second store.
- A value at a layer the key does not allow is ignored and reported, never
  applied. A repository never grants itself trust; an untrusted `.pi/` is
  present but not applied and never written.
- `expected` (or the Chat fence) refuses stale writes; a request applies
  atomically within one store and rolls back across stores; requests
  serialize per target.
- The record is append-only and kept forever; credentials and redacted values
  never appear in it. It is never read to compute a value.
- Tiers only rise: the web mark is per run, the assessment can raise but never
  lower, and only the maintainer's tap approves. Pending changes expire after
  24 hours, evaluated on use.
- Tron's own writes are bracketed (`begin`/`end`, `adopt`) and never reported as
  outside changes; Tron never re-applies a value on its own.
- Tron stages Project writes and never commits, pushes or opens a pull request.
- Changing a model or thinking never persists a default.

## Entry points

- Add or change a key: `settings-schema.ts` `KEYS`, then
  `scripts/tron docs update` refreshes the key table in the contract doc.
- Resolve a target: `SettingsModel.resolve` / `options`.
- Change or decide: `SettingsChangePath.change`, `undo`, `applyAgain`, `decide`,
  `changeProfile`.
- Outside detection: `OutsideChanges` (`reconcile`, `adopt`, `dispose`).
- Agent tool and web mark: `tron-settings-extension.ts`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `settings.risk.failed` | warning | Risk classification failed or hit its 1.5 s deadline; the deterministic tier stands |
| `settings.notification.failed` | warning | A notify or pending-approval push could not be queued; the change is already recorded |
| `settings.outside.failed` | warning | An outside-change comparison failed |
| `settings-run-applied` code on `session.diagnostic` | session diagnostic | The operational settings resolved and applied at request admission |
| `gateway.shutdown-step` `step=outside-settings-dispose` | info | Time spent retiring outside-change watches and observers at shutdown |
| `runtime.diagnostic` | error for a resource reload or extension load failure; warning for a per-provider refresh failure | Global provider or extension resources (`global-provider-resources.ts`) failed to load or refresh; the failure text in the message |
| `mcp.startup.problem` | warning | An explicit `mcp.list` found a CLI, configuration or server problem: bounded `reason`, `scope`; no URL, stderr or credentials |
| `mcp.auth-url.routed` | info | A provider-authored MCP authorization URL reached its active session operation; fixed message, no URL or callback data |
| `mcp.callback-relay.succeeded` | info | Pi's captured MCP callback was relayed to its loopback listener |
| `mcp.callback-relay.failed` | warning | The captured callback could not reach its loopback listener; no host, port, query, code or token |
| `auth.login.started` | info | A provider login was admitted; provider and auth type in the message |
| `auth.login.recovered` | info | An existing login was reattached to a new client |
| `auth.login.succeeded` | info | The login retired with a stored credential, or SDK-confirmed commitment was projected after it ended; a later success corrects an earlier retirement |
| `auth.login.ended` | warning | The login retired before SDK completion or failed (reason, elapsed seconds); retirement alone does not prove no credential committed |

## Verify

```bash
scripts/tron verify --module gateway/admin
scripts/tron test gateway src/admin/settings-model.integration.test.ts \
  src/admin/settings-change.integration.test.ts src/admin/settings-gate.e2e.test.ts
scripts/tron docs check
```

Behavior locks: `admin.lock.integration.test.ts`,
`admin.store.lock.integration.test.ts` and
`settings-approvals.lock.integration.test.ts` against `locks/*.golden.json`.
`settings-change.integration.test.ts` covers every key at every allowed layer,
the record, undo, outside changes and project git states;
`settings-gate.e2e.test.ts` covers tiers, approvals, the risk gate, live Run
settings, running-worker changes and Home profile adoption.

## Not here

- Home's learned profile store and task authorization: `src/home/`.
- Model fallback queue availability and routing: `src/providers/model-queue.ts`.
- The iOS renderer: `packages/ios-app` (`SettingsRendererView`).
- RPC dispatch: `src/transport/gateway-service.ts`.
