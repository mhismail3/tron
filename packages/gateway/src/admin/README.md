# gateway/admin

## Purpose

The Gateway's administration owners: settings store/options/binding-I/O adapters
for the kernel's audited, tiered read/change engine, and
the Mac-side admin services: trust binding I/O, provider auth, packages and resources, MCP,
custom models, Gateway updates, iOS installs, Mac replacement and diagnostics.

## Owns

| Area | Files |
|---|---|
| Settings declarations and binding admission | [kernel schema](../kernel/settings/settings-schema.ts) (`createSettingsSchema`, `KEYS`, `RECORD_SUBJECTS`), [kernel scope resolution](../kernel/settings/scope-resolution.ts) (binding admission from `sessionOverridable`/`projectSettable`); value validation, formatting and vocabulary: [kernel settings](../kernel/settings/README.md) |
| SDK scope admission and operational model selection | [kernel SDK storage admission](../kernel/settings/settings-sdk-manager.ts), [kernel operational admission](../kernel/settings/settings-admission.ts) |
| Store/options adapter and presentation | `settings-model.ts` (`SettingsStoreAdapter`), `settings-presentation.ts`; [kernel resolver and diagnostics](../kernel/settings/README.md) |
| Risk-provider adapter | `settings-risk.ts`; read/change engine, transaction order and audit/approvals: [kernel settings](../kernel/settings/README.md) |
| Migration transaction, backups and publication | `settings-migration.ts`, `settings-migration-plan.ts`; shared-store value transforms: [kernel settings](../kernel/settings/README.md) |
| Appliers and outside writers | `project-settings-writer.ts`, [kernel trust owner](../kernel/resources/trust-service.ts), `settings-outside.ts` (`OutsideChanges`) |
| The agents' `settings` tool and web mark | `tron-settings-extension.ts` |
| Provider auth and model catalog | `auth-broker.ts`, `model-config-service.ts`, `global-provider-resources.ts` |
| Packages, extensions, hooks, tools | `package-service.ts`, `package-provides.ts`, `session-free-extensions.ts`, `hook-resources.ts`, `tool-catalog.ts` |
| MCP administration | `mcp-admin-service.ts` |
| Install and lifecycle projections | `gateway-update-service.ts`, `ios-device-install-service.ts`, `ios-device-install-helper.ts`, `mac-replace-service.ts`, `diagnose.ts` |
| Shared admission | `document-admission.ts` (`COMMAND_ID`) |

Durable stores: `<tronHome>/gateway/settings/` (`changes/`, `approvals.json`,
`observed.json`, `floors.json`, `gateway.json`), `<tronHome>/gateway/home/profile.json`
(Home's durable Session recipe) and the pi agent directory files it applies
(`<tronHome>/agent/settings.json`, `trust.json`, `mcp.json`, `models.json`).

## Contract

`settings-module.ts` owns the settings extension descriptor. Its request/result
vocabulary is the [kernel settings contract](../kernel/settings/README.md); the
session resolves its actor and settings owner at every call. Approve-tier tool calls
(including explicit `request`) await the existing semantic form host instead of returning
pending. Scope/layer/reason/diff and Approve/Deny are shown in that form; the same tool
turn receives the terminal outcome. Dry runs do not open forms. Stop cancels only its
own pending diff. `settings-approval-blocking.e2e.test.ts` proves the live Home continuation,
approve/deny/expiry and Stop at the real runtime boundary.
`settings-presentation.ts` owns the profile audit-value formatter. History need
not load Home's profile implementation; Home calls the same formatter for its
stale-edit answer. Profile admission, records and mutation policy stay Home-owned.

Project diagnostics: file/key/reason only; ≤32 entries, ≤1,024 visited fields, ≤256-character paths (ellipsis when shortened); unknown objects are not traversed.
The full settings contract (foundations, layers, the generated key table,
timing, change path, tiers, outside changes, project writes, Home profile,
presentation) is [docs/settings-contract.md](../../docs/settings-contract.md).
The [three-layer settings design](../../docs/settings-three-layer-design.md)
defines scoped permissions and runtime admission.
In short:

- **One key, declared once on the Gateway** (F1). The schema holds type,
  group, allowed layers, timing, effect point, floor, writers, redaction and
  display. iOS renders keys generically; a new key needs no iOS release.
- **Three scopes** (F4): **Project > Session/Home override > Global**, gated by
  registry grants. Home has no Project or separate chapter override. Private store
  bindings are not scopes. Effective values are computed; canonical fixed evidence
  retains explicit/delegated choices while Project masks them. Home SDK adoption
  holds the runtime lane before recipe publication and records one logical edit.
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

Ports in: `gateway-main.ts` wires kernel `SettingsModel`/`SettingsChangePath`,
admin `SettingsStoreAdapter`,
`OutsideChanges` and the risk evaluator; `GatewayService` dispatches the RPCs,
pushes and broadcasts; `RuntimeSlot` supplies the Session-scope applier, fence and
running-worker `announce`; Home owns learned-note operations/undo and typed
post-observer projection through `HomeProfileItems` and the kernel audited-subject seam.
`main/settings-schema.ts` constructs one immutable schema from Home tool names,
the run compaction limit and security key validation. Registry/Slot, the read/change
owners and store adapters receive that same schema before optional settings services
are installed; schema access never evaluates their late-bound service getter.

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
- Any agent-directory event prompts the existing coalesced four-store digest scan:
  native filenames may omit the changed settings file. Unchanged digests skip their
  canonical readers and emit no audit or push; accepted scans and observers are
  joined by `dispose`.
- Tron stages Project writes and never commits, pushes or opens a pull request.
- Changing a model or thinking never persists a default. A masked Chat write
  refuses without replacing the stored choice. Operational Project selections
  preserve that inactive choice through cold resume and Project removal.
- Kernel settings SDK construction filters Project bindings at the public storage seam before
  tools/resources are admitted; writes preserve ignored fields in the same
  locked canonical document. Compaction consumes this registry's resolver.

## Entry points

- Add or change a key: [kernel schema](../kernel/settings/settings-schema.ts) `KEYS`, then
  `scripts/tron docs update` refreshes the key table in the contract doc.
- Resolve a target: `SettingsModel.resolve` / `options`.
- Change or decide: kernel `SettingsChangePath.change`, `undo`, `applyAgain`, `decide`.
- Learned profile: Home `HomeProfileItems.change` / `undo` under `SettingsChangePath.auditSubject`.
- Outside detection: `OutsideChanges` (`reconcile`, `adopt`, `dispose`).
- Agent tool and web mark: `tron-settings-extension.ts`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `settings.risk.failed` | warning | Risk classification failed or hit its 1.5 s deadline; the deterministic tier stands |
| `settings.notification.failed` | warning | A notify or pending-approval push could not be queued; the change is already recorded |
| `settings.outside.failed` | warning | An outside-change comparison failed |
| `settings-change.json` → `coalesced global directory hint` (test only) | test artifact | Native hints, push and errors for missed MCP drift; run the focused `#1900` reproduction below to distinguish filename-filter loss from audit/push ordering |
| `settings.migration` | info | The three-layer migration of the shared settings stores ran after the listener bound: `counts.inputs`, `counts.replaced`, or "already complete" |
| `settings.migration-failed` | error | That migration refused; every shared store is unchanged, startup continued, and it retries next start. `error` names the file and reason |
| `session_configuration_*` on a `busy` settings refusal | retryable error | Home's runtime boundary refused before recipe publication; its stored and SDK selections remain unchanged |
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
scripts/tron test gateway src/admin/settings-change.integration.test.ts -t 'reconciles missed global MCP drift'
```

Behavior locks: `admin.lock.integration.test.ts`,
`admin.store.lock.integration.test.ts` and
`settings-approvals.lock.integration.test.ts` against `locks/*.golden.json`.
`settings-change.integration.test.ts` covers every key at every allowed layer,
the record, undo, outside changes and project git states;
`settings-gate.e2e.test.ts` covers tiers, approvals, the risk gate, live Run
settings, running-worker changes and Home profile adoption.

## Not here

- Home's learned profile store and task authorization: `src/modules/home/`.
- Model fallback queue availability and routing: `src/providers/model-queue.ts`.
- The iOS renderer: `packages/ios-app` (`SettingsRendererView`).
- RPC dispatch: `src/transport/gateway-service.ts`.
