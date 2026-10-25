# Settings contract

How every model and harness setting is declared, stored, resolved, changed and shown. Owner:
the Gateway [settings kernel](../src/kernel/settings/README.md), with
[admin store adapters](../src/admin/README.md); iOS, Home, providers and the push relay
consume it. Edge cases follow from a [foundation](#foundations), never a new rule.

## Foundations

- **F1 Schema.** Each setting is one key declared once (`src/kernel/settings/settings-schema.ts`): type
  and validation, group, scope grants, store bindings, timing, effect point, tier floor,
  writers, redaction and display. `sessionOverridable` and `projectSettable` govern admission;
  store bindings describe owned persistence. iOS renders the served metadata generically.
- **F2 Truth.** Each layer's store is the truth; the change record is audit and undo, never
  consulted for a value. A store that differs from the last observed value is an
  [outside change](#outside-changes), offered **Apply again**; Tron never re-applies on its own.
- **F3 Policy.** Every change takes one Gateway path and one tier:
  `tier = max(floor + web, assessment)`, capped at approve; no per-key exceptions
  ([tiers](#tiers)).
- **F4 Scopes.** Top wins: **Project > Session/Home override > Global**, among the scopes
  the target has and the key's grants allow. One resolver takes the topmost applied scope with
  a value; the effective value is computed, never stored.

## Layers

| Scope | Store | Owner |
|---|---|---|
| Project | Admitted `.pi/settings.json` and `.pi/mcp.json` fields at the worktree root | Repository-owned, read-only; verified historical Undo alone retains its applier |
| Session/Home override | Session JSONL for ordinary chats and workers; `<tronHome>/gateway/home/profile.json` for Home's bounded durable recipe | Settings change path; the runtime lane owns SDK effects |
| Global | Agent and Gateway defaults, trust, floors, notifications and SDK/schema defaults | Gateway and the underlying SDK stores; hand edits are outside writers |

Precedence is Project > Session/Home override > Global, admitted by
`projectSettable` and `sessionOverridable`. Home has no Project and no separate chapter
override. Project masks a stored Session choice without deleting it; removing Project
reactivates that choice. Workers inherit only the bounded queue/model, thinking,
subagent-queue and task-budget recipe. The Project store is
`.pi/` at the worktree root (`TrustInspection.projectDir`, pi's `projectDir`;
[project root](../src/machine/README.md#project-root)). Trust is the Global key
`permissions.projectTrust[project]`, so a repository never trusts itself. Untrusted or
unreadable Project data is not applied. Ignored fields produce bounded file/key/reason-only
diagnostics, never values. Project tools, thinking budgets and image permissions cannot
widen Global policy. A fixed qualifier is part of the id; a dynamic `model` qualifier
resolves for the effective model, per-model before plain within a scope. Private
`chat/profile/mac/builtin` bindings describe persistence, not more scopes. The generated
key table's Layers/Home layers columns list those private bindings; grants own admission.

## Keys

<!-- tron docs settings -->
48 keys, declared in `packages/gateway/src/kernel/settings/settings-schema.ts` (`KEYS`).

| Key | Qualifier | Group | Layers | Home layers | Timing | Effect | Floor |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `model.ref[role=chat]` | — | model | project, session, global, home | as allowed | fixed | next-turn | quiet |
| `model.thinking[role=chat]` | model | model | project, session, global, home | as allowed | fixed | next-turn | quiet |
| `model.contextWindow` | model | model | project, session, global | as allowed | fixed | next-turn | quiet |
| `model.thinkingBudgets` | — | workers | project, global | as allowed | fixed | new-chat | quiet |
| `model.thinking[role=summarizer]` | — | context | project, global | none | live | next-compaction | quiet |
| `model.queue[role=worker]` | — | workers | session, global, home | as allowed | live | delegate | notify |
| `model.queue[role=subagent]` | — | workers | session, global, home | as allowed | live | next-request | notify |
| `model.queue[role=background]` | — | workers | global, home | as allowed | live | next-memory-pass | notify |
| `model.thinking[role=worker]` | — | workers | global, home | as allowed | fixed | delegate | notify |
| `context.compaction.enabled` | — | context | project, session, global | none | live | next-compaction | quiet |
| `context.compaction.reserveTokens` | model | context | project, session, global | none | live | next-compaction | quiet |
| `context.compaction.keepRecentTokens` | model | context | project, session, global | none | live | next-compaction | quiet |
| `context.compaction.instructions` | — | context | project, session, global | none | live | next-compaction | notify |
| `context.branchSummary.reserveTokens` | — | context | project, global | none | live | next-compaction | quiet |
| `context.images.autoResize` | — | tools | project, session, global | as allowed | fixed | new-chat | quiet |
| `context.images.block` | — | tools | project, session, global | as allowed | narrow live, widen fixed | next-request | narrow quiet, widen approve |
| `tools.active` | — | tools | project, session, global, home | session, home | fixed | next-turn | narrow quiet, widen notify |
| `tools.codemode.mode` | — | tools | project, global | none | fixed | new-chat | narrow quiet, widen notify |
| `tools.codemode.inlineBudget` | — | tools | project, global | none | fixed | new-chat | quiet |
| `tools.shell.path` | — | tools | project, global | none | fixed | new-chat | notify |
| `tools.shell.commandPrefix` | — | tools | project, global | none | fixed | new-chat | notify |
| `permissions.projectTrust` | project | trust | global | as allowed | live | reload | narrow notify, widen approve |
| `permissions.macTerminalKey` | device | connections | global | as allowed | live | next-change | narrow notify, widen approve |
| `permissions.defaultProjectTrust` | — | trust | global | as allowed | live | next-change | narrow notify, widen approve |
| `permissions.floor` | key | approvals | global | as allowed | live | next-change | narrow quiet, widen approve |
| `permissions.budget.task` | — | workers | global, home | as allowed | narrow live, widen fixed | delegate | narrow quiet, widen approve |
| `run.queue.steeringMode` | — | run | project, session, global | as allowed | live | next-turn | quiet |
| `run.queue.followUpMode` | — | run | project, session, global | as allowed | live | next-turn | quiet |
| `run.retry.enabled` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.retry.maxRetries` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.retry.baseDelayMs` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.retry.provider.timeoutMs` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.retry.provider.maxRetries` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.retry.provider.maxRetryDelayMs` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.transport` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.httpIdleTimeoutMs` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.websocketConnectTimeoutMs` | — | run | project, session, global | as allowed | live | next-request | quiet |
| `run.httpProxy` | — | run | global | as allowed | live | restart | notify |
| `run.cacheWarming` | — | run | global | none | fixed | new-chat | narrow quiet, widen notify |
| `sources.extensions` | — | sources | project, global | none | fixed | reload | narrow quiet, widen notify |
| `sources.skills` | — | sources | project, global | none | fixed | reload | narrow quiet, widen notify |
| `sources.prompts` | — | sources | project, global | none | fixed | reload | narrow quiet, widen notify |
| `sources.themes` | — | sources | project, global | none | fixed | reload | narrow quiet, widen notify |
| `sources.packages` | — | sources | project, global | none | fixed | reload | narrow quiet, widen notify |
| `sources.npmCommand` | — | sources | global | none | live | next-change | notify |
| `setup.sessionDir` | — | setup | global | as allowed | live | restart | notify |
| `setup.installTelemetry` | — | setup | global | as allowed | live | next-request | quiet |
| `setup.terminalIdleMinutes` | — | setup | global | as allowed | live | next-change | notify |

Record subjects (`RECORD_SUBJECTS`), changed per instance through the same path:

| Subject | Group | Qualifier | Floor |
| --- | --- | --- | --- |
| `tools.mcp.server` | tools | server | notify |
| `accounts.models.provider` | accounts | provider | notify |
<!-- /tron docs -->

Other schema fields: `subgroup`, `type`, `options` or `optionsSource` (`catalog.models`,
`catalog.thinkingLevels(model)`, `catalog.tools`, ...), `defaultValue`, `direction`, `writers`
(`ui`, `home`, `worker`, `agent`: the list is the grant), `redacted`, `applier`, and display
fields (`label`, `help`, `order`, `importance`, `control`/`fallback`, `unit`/`format`,
`confirm`, `entry`). MCP and Accounts keep their own RPCs; record subjects compare by digest.

## Timing

The effect point (`next-turn`, `next-request`, `new-chat`, `reload`, `restart`, ...) is shown
when a change is not immediate; timing may differ by direction.

- **Fixed** keys (model, thinking, context window, tools, resources, image resizing) are
  captured at chat start as Session values with provenance `{ value, from, at, ref }` (`launch`,
  `override`, `legacy-session`, `inherited`; history is never mined). **Use the current
  default** writes the lower layers' value through the change path.
- **Live** keys are read at their effect point; Chat-bound Run keys resolve before each prompt
  and request onto the session's `SettingsManager` (Home too) and, for provider timeouts, at
  `ModelRuntime.streamSimple`. **Follow the default** unsets a Session value.
- **Per direction** (`context.images.block`): narrowing applies next request; widening waits
  for a new chat unless approved or tapped. `requestPins` in `tron.settings.v1` hold directional
  values; an approved Mac/Project widening releases inherited pins, never explicit Session values.
- Fork, cold resume and Home rollover carry `tron.settings.v1`, never the record. Changing a
  model or thinking never persists a default.

## Change path

`settings.change { commandId, target, changes[], reason, dryRun? }`; a change is `{ key, qualifiers, layer, op: set | unset, value, expected }`. `reason` is required for non-UI actors;
`expected` refuses stale writes; Chat changes carry `fence: { runtimeGeneration, model?, revision? }`. Actors: `ui` (the maintainer's tap); Home, workers and agents via the `settings`
tool (Home may name a `taskId`); `outside` (observed only).

1. Validate type, options, layer and writer. 2. Compute the tier; a non-UI `approve` is held
pending. 3. Apply through the key's applier under its store lock (atomic within a store,
ordered with rollback across stores; one target per request, serialized per target).
4. Append to the record and broadcast `settings.changed`.

Outcomes name key, layer, status, tier and redacted `before`/`after`. A chat's own Session scope
changes only while idle; `setup.sessionDir` has no writer; Home Chat compaction values are
refused. **Record:** `<tronHome>/gateway/settings/changes/`, append-only 500-entry segments
listed in `index.json`, kept forever, paged by `settings.history` (a page may be empty with a
`nextCursor`); entries hold actor, target, key, `before`/`after` (never credentials), reason,
tier basis, status (`applied`, `pending`, `approved`, `declined`, `expired`, `superseded`,
`failed`, `outside`), git result and `undoOf`/`applyAgainOf`. **Undo** (`settings.undo`) writes
`before` back, refused with `conflict` when the store moved; redacted entries are **Not
undoable**. **Apply again** (`settings.applyAgain`) restores Tron's value over an outside one.

## Tiers

- **quiet** applies and records; **notify** also pushes with Undo; **approve** waits for the
  maintainer's tap and expires after 24 hours. A request takes its highest change's tier.
- **Floor** per key and direction, overridable through `permissions.floor[key]` (lowering one
  is a widening); record-subject floors are not.
- **Web mark:** one step up for the rest of a run once a tool not declaring
  `annotations.openWorldHint: false` is called (nested codemode calls too); pi's `read`,
  `edit`, `write`, `grep`, `find`, `ls`, `bash`, `codemode` and `tool_search` are closed-world.
- **Assessment:** for non-UI requests an optional Jev classifier (`settings-risk.ts`) may raise,
  never lower, within 1.5 s, seeing only key, layer, actor kind, floor, web mark, a redacted
  reason and a lossy diff.
- **Approvals** (`settings.approvals`, `settings.decide`) bind a digest of target and
  `before`/`after` (the decision's whole fence: no client fence); a newer request supersedes;
  only the maintainer's client decides; the push carries `settings-approval` only to a relay
  advertising it ([push relay](../../push-relay/README.md#notification-categories)). A
  context `request` holds a change at any tier (`tierBasis.requested`). A timer expires a
  request at its 24-hour deadline. The requester hears every outcome once (approved and
  applied, declined, failed, superseded, expired) as one `tron.settings-outcome.v1` message
  whose `details.requests[]` carry status, requester, reason, failure and display
  `before`/`after`; the approvals store's `told` flag is the only outbox. Selection
  is non-destructive; request IDs observed in canonical chat entries acknowledge delivery,
  so refused admission or a crash before append leaves outcomes available.
- **Approval actions** (`registerAction`, `requestAction`): an owner's maintainer-gated
  operation that is not a stored value shares the store, digest, expiry, decision, record
  (`action: true`, key = subject, never undoable) and outcomes; `plan` binds an exact preview,
  re-checked at decide (a moved state supersedes). A durable execution claim precedes
  `apply`; an interrupted execution is reported failed with possibly completed effects,
  never replayed. Action failures instruct inspection before retry rather than promising
  that no effects occurred. Expiry and decision admission share the target stripe.
- **One key id rule:** resolve, dry run and change take the declared id
  (`model.thinking[role=chat]`); a plain id with fixed instances is refused naming them, and a
  qualifier contradicting a fixed one is refused.
- **A running Home task worker** can be changed by Home (`taskId`) or the maintainer: model,
  thinking and Run keys apply from its next request with one fenced `Settings changed` steer
  (`signal`: `queued`, `not-running`, `failed`); context window and tools are `busy` until it
  settles; `resolve` adds a `worker` block (`selected`, `lastResponse`).

## Outside changes

`OutsideChanges` (`settings-outside.ts`) compares stores with the values last observed
(`<tronHome>/gateway/settings/observed.json`) on every read and on debounced directory events:
the Mac `settings.json`, `trust.json`, `mcp.json`, `models.json` and each known project's `.pi/`
files (≤ 64 projects); first sight is the baseline. Each differing instance is one `outside`
entry (with `HEAD` and branch for repository files; redacted keys by digest); MCP servers and
custom providers report only added/changed/removed, then `mcp.changed` or
`models.customChanged`. Tron's own writes are bracketed (`begin`/`end`, `adopt`). The floor
decides only the push.

## Project writes

Tron edits `.pi/` under the project's store lock, keeps other keys and layout, and stages with
`git add`; it never commits, pushes or opens a pull request. If git cannot stage the write
stands and the entry says why. Badges: matches `HEAD` → Project; else **Staged** or
**Uncommitted**; **Local only** outside a repository or when ignored. A commit holding Tron's
blob appends `committed`.

## Home profile

Home's typed durable recipe is its Session override; learned notes may explain a value but
never carry one. A save of Home's model, thinking or tools acquires the runtime's existing
lane before publishing any recipe value and retains it through SDK adoption. A busy or
stale runtime refuses before publication, leaving both the persisted choice and SDK
unchanged. SDK effects share the recipe's audit identity, not a second chapter edit.
`permissions.budget.task` (`{ inputTokens?, outputTokens? }`) is fixed at admission; raises
need approval, lowers apply live.

| Queue role | Runs | Resolves | Empty means |
|---|---|---|---|
| `worker` | Home task workers | Home recipe > Global, captured at admission | Home's model |
| `subagent` | Managed subagent children (`tron/subagent`) | Global; task children use the captured queue | Each agent's model |
| `background` | Home memory (Home recipe > Global), Knowledge (Global) | as stated | The subagent queue |

`ModelQueueOwner` (`src/providers/model-queue.ts`) skips unregistered, virtual or
uncredentialed models, models with a usage-limit error in the last 15 minutes or ≥ 95% usage,
and moves on after a usage-limit error; captured queues are read-only. Worker thinking is
`{ "sameAs": "home" }` by default. **Learned-profile changes** (`home.profileChange`, the
`profile` tool) use Home `HomeProfileItems.change` through the kernel
`SettingsChangePath.auditSubject` stripe/audit coordinator: one quiet `home.profile.item` entry per
note, grouped and undone together, refused on a stale revision.

## Presentation

Words and values come from the schema and resolver; iOS decides only layout.
`settings.resolve` serves sections (Model, Workers & delegation, Compaction, Tools,
Agent changes, Connection, Trusted Projects, Mac Terminal, Accounts, Sources, Storage) and badges `{ kind, label, detail?, action? }`
(Layer, Source, Scope, Authority, State; unknown kinds render neutrally; actions go through
`settings.change`). Controls: `toggle`, `choice`, `number`, `text`, `secret`, `list`,
`checklist`, `catalog`, `readOnly`; the client sends what it implements and gets the declared
control, its `fallback`, or `readOnly` with "Update Tron to edit". Stopped-runtime settings with
no writer are not Settings rows. `sessionOverridable`/`projectSettable` grant scopes; `editable`
is the target's binding/writer capability, not a second client-side permission list. Override
presence is explicit even for equal/false/zero values. Applied Project values serve their exact
file/key; ignored fields serve bounded value-free diagnostics. Untrusted/unreadable Project notices
name their file and never make a Session editor look Project-owned.
`settings.options` pages options; `dryRun` returns per-key errors and the tier. Changes list
pending approvals first. Global writes Global, Session the Session scope, Home its saved settings;
Project is inspection only. Session/Home reuse Global's renderer and editors; Project-owned rows
have a read-only value and separate Project info pill, explicit overrides have Overridden/Revert,
and Global alone has a Changes entry. Hand-built screens remain only for guided flows and viewers.
