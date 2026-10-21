# Settings contract

How every model and harness setting is declared, stored, resolved, changed and shown. Owner:
the Gateway [`admin` module](../src/admin/README.md); iOS, Home, providers and the push relay
consume it. Edge cases follow from a [foundation](#foundations), never a new rule.

## Foundations

- **F1 Schema.** Each setting is one key declared once (`src/admin/settings-schema.ts`): type
  and validation, group, allowed layers, timing, effect point, tier floor, writers, redaction
  and display. iOS renders keys generically, so a new key needs no iOS release. "Mac only" or
  "a chat may override it" are allowed layers, never rules.
- **F2 Truth.** Each layer's store is the truth; the change record is audit and undo, never
  consulted for a value. A store that differs from the last observed value is an
  [outside change](#outside-changes), offered **Apply again**; Tron never re-applies on its own.
- **F3 Policy.** Every change takes one Gateway path and one tier:
  `tier = max(floor + web, assessment)`, capped at approve; no per-key exceptions
  ([tiers](#tiers)).
- **F4 Layers.** Top wins: **Chat > Home profile > Project > Mac > Built-in**, among the
  layers the target has and the key allows. One resolver takes the topmost applied layer with
  a value; the effective value is computed, never stored.

## Layers

| Layer | Store | Owner |
|---|---|---|
| Chat | Session JSONL: SDK `model_change`/`thinking_level_change`, `tron.context-window.v1`, active tools, `tron.settings.v1` (other Chat keys and fixed-value provenance) | The session's runtime slot lane |
| Profile | `<tronHome>/gateway/home/profile.json` (typed, ≤ 256 KiB; undeclared fields preserved, never resolved) | The settings change path |
| Project | `.pi/settings.json`, `.pi/mcp.json` at the chat's worktree root | The repository; Tron writes and stages, never commits |
| Mac | `<tronHome>/agent/settings.json`, `models.json`, `mcp.json`, `trust.json`; `<tronHome>/gateway/settings/` (`floors.json`, `gateway.json`) and `notifications.json` | The Gateway; pi CLI runs and hand edits are outside writers |
| Built-in | pi defaults and the schema's `builtin` values | The release |

A target has a layer when it has its store: an ordinary chat (a Home task worker too) has
Chat, Project, Mac, Built-in; Home's chat has Chat, Profile, Mac, Built-in. Workers get
profile-derived values only as Chat values Home writes at delegation. The Project store is
`.pi/` at the worktree root (`TrustInspection.projectDir`, pi's `projectDir`;
[project root](../src/machine/README.md#project-root)). Trust is the Mac key
`permissions.projectTrust[project]`, so a repository never trusts itself; an untrusted `.pi/`
is read but not applied (`reason: "untrusted"`) and never written; an unparseable one is
`projectUnreadable`. A fixed qualifier is part of the id; a dynamic `model` qualifier resolves
for the effective model, per-model before plain within a scope. `defaultTools` `+name`/`-name`
lists and thinking-budget maps compose over the layer below; unsupported values clamp
(**Clamped** badge).

## Keys

<!-- tron docs settings -->
49 keys, declared in `packages/gateway/src/admin/settings-schema.ts` (`KEYS`).

| Key | Qualifier | Group | Layers | Home layers | Timing | Effect | Floor |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `model.ref[role=chat]` | — | model | chat, profile, project, mac | as allowed | fixed | next-turn | quiet |
| `model.thinking[role=chat]` | model | model | chat, profile, project, mac | as allowed | fixed | next-turn | quiet |
| `model.contextWindow` | model | model | chat, project, mac | as allowed | fixed | next-turn | quiet |
| `model.thinkingBudgets` | — | advanced | project, mac | as allowed | fixed | new-chat | quiet |
| `model.offered` | — | advanced | project, mac | as allowed | live | next-turn | quiet |
| `model.thinking[role=summarizer]` | — | context | project, mac | none | live | next-compaction | quiet |
| `model.queue[role=worker]` | — | workers | chat, profile, mac | as allowed | live | delegate | notify |
| `model.queue[role=subagent]` | — | workers | chat, profile, mac | as allowed | live | next-request | notify |
| `model.queue[role=background]` | — | workers | profile, mac | as allowed | live | next-memory-pass | notify |
| `model.thinking[role=worker]` | — | workers | profile | as allowed | fixed | delegate | notify |
| `context.compaction.enabled` | — | context | chat, project, mac | none | live | next-compaction | quiet |
| `context.compaction.reserveTokens` | model | context | chat, project, mac | none | live | next-compaction | quiet |
| `context.compaction.keepRecentTokens` | model | context | chat, project, mac | none | live | next-compaction | quiet |
| `context.compaction.instructions` | — | context | chat, project, mac | none | live | next-compaction | notify |
| `context.branchSummary.reserveTokens` | — | context | project, mac | none | live | next-compaction | quiet |
| `context.images.autoResize` | — | tools | chat, project, mac | as allowed | fixed | new-chat | quiet |
| `context.images.block` | — | tools | chat, project, mac | as allowed | narrow live, widen fixed | next-request | narrow quiet, widen approve |
| `tools.active` | — | tools | chat, profile, project, mac | chat, profile | fixed | next-turn | narrow quiet, widen notify |
| `tools.codemode.mode` | — | tools | project, mac | none | fixed | new-chat | narrow quiet, widen notify |
| `tools.codemode.inlineBudget` | — | tools | project, mac | none | fixed | new-chat | quiet |
| `tools.shell.path` | — | tools | project, mac | none | fixed | new-chat | notify |
| `tools.shell.commandPrefix` | — | tools | project, mac | none | fixed | new-chat | notify |
| `permissions.projectTrust` | project | advanced | mac | as allowed | live | reload | narrow notify, widen approve |
| `permissions.macTerminalKey` | device | advanced | mac | as allowed | live | next-change | narrow notify, widen approve |
| `permissions.defaultProjectTrust` | — | advanced | mac | as allowed | live | next-change | narrow notify, widen approve |
| `permissions.floor` | key | advanced | mac | as allowed | live | next-change | narrow quiet, widen approve |
| `permissions.budget.task` | — | workers | profile | as allowed | narrow live, widen fixed | delegate | narrow quiet, widen approve |
| `run.queue.steeringMode` | — | advanced | chat, project, mac | as allowed | live | next-turn | quiet |
| `run.queue.followUpMode` | — | advanced | chat, project, mac | as allowed | live | next-turn | quiet |
| `run.retry.enabled` | — | advanced | chat, project, mac | as allowed | live | next-request | quiet |
| `run.retry.maxRetries` | — | advanced | chat, project, mac | as allowed | live | next-request | quiet |
| `run.retry.baseDelayMs` | — | advanced | chat, project, mac | as allowed | live | next-request | quiet |
| `run.retry.provider.timeoutMs` | — | advanced | chat, project, mac | as allowed | live | next-request | quiet |
| `run.retry.provider.maxRetries` | — | advanced | chat, project, mac | as allowed | live | next-request | quiet |
| `run.retry.provider.maxRetryDelayMs` | — | advanced | chat, project, mac | as allowed | live | next-request | quiet |
| `run.transport` | — | run | chat, project, mac | as allowed | live | next-request | quiet |
| `run.httpIdleTimeoutMs` | — | run | chat, project, mac | as allowed | live | next-request | quiet |
| `run.websocketConnectTimeoutMs` | — | run | chat, project, mac | as allowed | live | next-request | quiet |
| `run.httpProxy` | — | run | mac | as allowed | live | restart | notify |
| `run.cacheWarming` | — | run | mac | none | live | next-turn | narrow quiet, widen notify |
| `sources.extensions` | — | sources | project, mac | none | fixed | reload | narrow quiet, widen notify |
| `sources.skills` | — | sources | project, mac | none | fixed | reload | narrow quiet, widen notify |
| `sources.prompts` | — | sources | project, mac | none | fixed | reload | narrow quiet, widen notify |
| `sources.themes` | — | sources | project, mac | none | fixed | reload | narrow quiet, widen notify |
| `sources.packages` | — | sources | project, mac | none | fixed | reload | narrow quiet, widen notify |
| `sources.npmCommand` | — | sources | mac | none | live | next-change | notify |
| `setup.sessionDir` | — | setup | mac | as allowed | live | restart | notify |
| `setup.installTelemetry` | — | setup | mac | as allowed | live | next-request | quiet |
| `setup.terminalIdleMinutes` | — | setup | mac | as allowed | live | next-change | notify |

Record subjects (`RECORD_SUBJECTS`), changed per instance through the same path:

| Subject | Group | Qualifier | Floor |
| --- | --- | --- | --- |
| `tools.mcp.server` | tools | server | notify |
| `accounts.models.provider` | accounts | provider | notify |
<!-- /tron docs -->

Other schema fields: `subgroup`, `type`, `options` or `optionsSource` (`catalog.models`,
`catalog.thinkingLevels(model)`, `catalog.tools`, ...), `builtin`, `direction`, `writers`
(`ui`, `home`, `worker`, `agent`: the list is the grant), `redacted`, `applier`, and display
fields (`label`, `help`, `order`, `importance`, `control`/`fallback`, `unit`/`format`,
`confirm`, `entry`). MCP and Accounts keep their own RPCs; record subjects compare by digest.

## Timing

The effect point (`next-turn`, `next-request`, `new-chat`, `reload`, `restart`, ...) is shown
when a change is not immediate; timing may differ by direction.

- **Fixed** keys (model, thinking, context window, tools, resources, image resizing) are
  captured at chat start as Chat values with provenance `{ value, from, at, ref }` (`launch`,
  `override`, `legacy-session`, `inherited`; history is never mined). **Use the current
  default** writes the lower layers' value through the change path.
- **Live** keys are read at their effect point; Chat-bound Run keys resolve before each prompt
  and request onto the session's `SettingsManager` (Home too) and, for provider timeouts, at
  `ModelRuntime.streamSimple`. **Follow the default** unsets a Chat value.
- **Per direction** (`context.images.block`): narrowing applies next request; widening waits
  for a new chat unless approved or tapped. `requestPins` in `tron.settings.v1` hold directional
  values; an approved Mac/Project widening releases inherited pins, never explicit Chat values.
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

Outcomes name key, layer, status, tier and redacted `before`/`after`. A chat's own Chat layer
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
  `before`/`after`; a newer request supersedes; the push carries `settings-approval` only to a
  relay advertising it ([push relay](../../push-relay/README.md#notification-categories)); the
  requester hears each declined, expired or superseded change once (`tron.settings-outcome.v1`).
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

Typed Profile keys resolve like any layer; learned notes may explain a value but never carry
one. A maintainer save of Home's model, thinking or tools also sets the active chapter's Chat
value (refused while it runs). `permissions.budget.task` (`{ inputTokens?, outputTokens? }`) is
fixed at admission; raises need approval, lowers apply live.

| Queue role | Runs | Resolves | Empty means |
|---|---|---|---|
| `worker` | Home task workers | Profile > Mac, captured at admission | Home's model |
| `subagent` | Managed subagent children (`tron/subagent`) | Mac; task children use the captured queue | Each agent's model |
| `background` | Home memory (Profile > Mac), Knowledge (Mac) | as stated | The subagent queue |

`ModelQueueOwner` (`src/providers/model-queue.ts`) skips unregistered, virtual or
uncredentialed models, models with a usage-limit error in the last 15 minutes or ≥ 95% usage,
and moves on after a usage-limit error; captured queues are read-only. Worker thinking is
`{ "sameAs": "home" }` by default. **Learned-profile changes** (`home.profileChange`, the
`profile` tool) use `SettingsChangePath.changeProfile`: one quiet `home.profile.item` entry per
note, grouped and undone together, refused on a stale revision.

## Presentation

Words, badges and values come from the schema and resolver; iOS decides only layout.
`settings.resolve` serves sections (Model, Workers & delegation, Compaction, Tools,
Agent changes, Connection, Trusted Projects, Mac Terminal, Accounts, Sources, Storage) and badges `{ kind, label, detail?, action? }`
(Layer, Source, Scope, Authority, State; unknown kinds render neutrally; actions go through
`settings.change`). Controls: `toggle`, `choice`, `number`, `text`, `secret`, `list`,
`checklist`, `catalog`, `readOnly`; the client sends what it implements and gets the declared
control, its `fallback`, or `readOnly` with "Update Tron to edit" — never a hidden value.
`settings.options` pages options; `dryRun` returns per-key errors and the tier. Changes list
pending approvals first. Global writes Mac, Session the Chat layer, Home only `profile`;
Project is inspection only. Hand-built screens remain only for guided flows and viewers.
