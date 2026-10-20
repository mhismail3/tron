# Settings contract

How every model and harness setting is declared, stored, resolved, changed and
shown. Owner: the Gateway [`admin` module](../src/admin/README.md); iOS, Home,
providers and the push relay consume it. Edge cases follow from a
[foundation](#foundations), never a new rule.

## Foundations

- **F1 Schema.** Each setting is one key, declared once on the Gateway
  (`src/admin/settings-schema.ts`): type and validation, group, allowed layers,
  timing, effect point, tier floor, writers, redaction and display. iOS renders
  every key generically, so a new model, feature or key needs no iOS release.
  "Mac only" or "a chat may override it" are allowed layers, never rules.
- **F2 Truth.** Each layer's store is the truth. The change record is audit and
  undo, never consulted to compute a value. A store that differs from the value
  last observed is an [outside change](#outside-changes), offered **Apply
  again**; Tron never re-applies a value on its own.
- **F3 Policy.** Every change goes through one Gateway path and gets one tier:
  `tier = max(floor + web, assessment)`, capped at approve. No per-key
  exceptions: "trust, credentials and budget raises need a tap" is those keys'
  default floor ([tiers](#tiers)).
- **F4 Layers.** Precedence, top wins: **Chat > Home profile > Project > Mac >
  Built-in**, among the layers the target has and the key allows. One resolver
  takes the topmost layer that the target has, holds a value, is allowed by the
  key, and is applied. The effective value is computed, never stored.

## Layers

| Layer | Store | Owner |
|---|---|---|
| Chat | The session JSONL: SDK `model_change`/`thinking_level_change`, `tron.context-window.v1`, the active tools, and `tron.settings.v1` (other Chat keys and fixed-value provenance) | The session's runtime slot lane |
| Profile | `<tronHome>/gateway/home/profile.json`, typed, capped at 256 KiB; undeclared fields never resolve and are preserved | The settings change path (locked JSON write) |
| Project | `.pi/settings.json`, `.pi/mcp.json` at the chat's worktree root | The repository; Tron writes and stages, never commits |
| Mac | `<tronHome>/agent/settings.json`, `models.json`, `mcp.json`, `trust.json`; Gateway stores under `<tronHome>/gateway/settings/` (`floors.json`, `gateway.json`) and `notifications.json` | The Gateway; pi CLI runs and hand edits are outside writers |
| Built-in | pi defaults and the schema's `builtin` values | The release |

**A target has a layer when it has its store.** An ordinary chat (a Home task
worker too) has Chat, Project, Mac, Built-in; Home's chat has Chat, Profile, Mac,
Built-in (no project). Workers get profile-derived values only as Chat values
Home writes at delegation. A key appears where one of its layers exists.

**Project root and trust.** The Project store is `.pi/` at the worktree root
(`TrustInspection.projectDir`, passed to pi as `projectDir`;
[Gateway README](../README.md#project-root)). Trust is the Mac key
`permissions.projectTrust[project]`, so a repository never grants itself trust.
An untrusted `.pi/` is read as JSON, **present but not applied** (`reason:
"untrusted"`), never written; an unparseable one is `projectUnreadable`.

**Instances.** A fixed qualifier is part of the id; a dynamic `model` qualifier
resolves for the effective model, combining per-model and plain values within a
scope before scope precedence. `defaultTools` `+name`/`-name` lists and
thinking-budget maps compose over the layer below. An unsupported value is
clamped to the closest supported one (**Clamped** badge).

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

Other schema fields: `subgroup`, `type`, `options` or an `optionsSource`
(`catalog.models`, `catalog.thinkingLevels(model)`, `catalog.tools`, ...),
`builtin`, `direction`, `writers` (`ui`, `home`, `worker`, `agent`: the list is
the grant), `redacted`, `applier`, and display fields (`label`, `help`, `order`,
`importance`, `control`/`fallback`, `unit`/`format`, `confirm`, `entry`). MCP and
Accounts keep their own RPCs; record subjects are compared by digest only.

## Timing

Timing may differ by direction; the effect point (`next-turn`, `next-request`,
`new-chat`, `reload`, `restart`, ...) is shown when a change is not immediate.

- **Fixed** keys (model, thinking, context window, tools, resources, image
  resizing) are captured at chat start as Chat-layer values with provenance
  `{ value, from, at, ref }`. Origins: `launch` (canonical snapshot), `override`
  (explicit choice), `legacy-session` (no attributable provenance), `inherited`.
  History is never mined to invent provenance. **Use the current default**
  resolves the lower layers once and writes that value through the change path.
- **Live** keys are read at their effect point. Chat-bound Run keys resolve
  before each prompt and provider request onto the session's `SettingsManager`
  (Home included) and, for optional provider timeouts, at
  `ModelRuntime.streamSimple`. **Follow the default** unsets a Chat value.
- **Per direction**, e.g. `context.images.block`: narrowing applies from the next
  request, widening waits for a new chat unless approved or tapped. Directional
  values keep `requestPins` in `tron.settings.v1`; an approved Mac/Project
  widening releases inherited pins in open chats at that scope, never an explicit
  Chat value or a Project-shadowed pin.
- Fork, cold resume and Home rollover carry `tron.settings.v1`, never the
  record. Changing a model or thinking never persists a default.

## Change path

`settings.change { commandId, target, changes[], reason, dryRun? }`; each change
is `{ key, qualifiers, layer, op: set | unset, value, expected }`. `reason` is
required for every non-UI actor; `expected` refuses stale writes; a Chat-layer
change carries `fence: { runtimeGeneration, model?, revision? }`. Actors: the
maintainer's tap (`ui`); Home, workers and agents through the `settings` tool
(Home may name a `taskId`); `outside` (observed, never admitted).

1. Validate type, options, allowed layer and writer.
2. Compute the tier; an `approve` request from a non-UI actor is held pending.
3. Apply through the key's applier under its store lock; atomic within a store,
   ordered with rollback across stores. A request's changes share one target;
   requests serialize per target.
4. Append to the record and broadcast `settings.changed`.

Each outcome names key, layer, status, tier and `before`/`after` (redacted:
`redacted: true` only). A chat's own Chat layer changes only while it is idle;
`setup.sessionDir` has no writer; Home Chat compaction values are refused.

**Record.** `<tronHome>/gateway/settings/changes/`: append-only segments of 500
entries named in `index.json`, kept forever, read in pages by
`settings.history` (a page may be empty and still carry `nextCursor`). Entries
hold actor, target, key, `before`/`after` (never credentials), reason, tier
basis, status (`applied`, `pending`, `approved`, `declined`, `expired`,
`superseded`, `failed`, `outside`), git result and `undoOf`/`applyAgainOf`;
later facts are new entries referencing `changeId`.

**Undo and Apply again** are ordinary changes. `settings.undo` writes `before`
back and is refused with `conflict` (current and applied values) when the store
moved; undoing a narrowing widens. Redacted entries are **Not undoable**.
`settings.applyAgain` restores Tron's value after an outside change, expecting
the outside value.

## Tiers

- **quiet** applies and records; **notify** also pushes with Undo; **approve**
  waits for the maintainer's tap and expires after 24 hours.
- **Floor**: per key and direction, overridable through `permissions.floor[key]`
  (lowering one is a widening, approve by default). Every entry names the floor
  and whether it was overridden. Record-subject floors are not overridable.
- **Web mark**: one step up for the rest of a run once any tool that does not
  declare `annotations.openWorldHint: false` is called (nested codemode calls
  included). pi's `read`, `edit`, `write`, `grep`, `find`, `ls`, `bash`,
  `codemode` and `tool_search` are declared closed-world. The mark never travels
  with content another turn reads later.
- **Assessment**: for non-UI, non-dry-run requests an optional Jev classifier
  (`settings-risk.ts`) may raise, never lower, within a 1.5 s request deadline;
  failure or timeout keeps the deterministic tier. It sees only key, layer,
  actor kind, floor, web mark, a redacted reason and a lossy diff.
- **The maintainer's tap** applies at any tier (after any `confirm` text). A
  request takes its highest change's tier and is held or applied whole.
- **Approvals** (`settings.approvals`, `settings.decide`) bind to a digest of
  target and `before`/`after`; a newer request for the same instance supersedes;
  expiry is evaluated on use. The waiting push carries the `settings-approval`
  category only to a relay advertising it
  ([push relay](../../push-relay/README.md#notification-categories)). The
  requester's next run hears each declined, expired or superseded change once
  (`tron.settings-outcome.v1`).
- **A running Home task worker** can be changed by Home (`taskId`) or the
  maintainer. Model, thinking and Chat Run keys apply from its next provider
  request and send one fenced `Settings changed` steer (`signal`: `queued`,
  `not-running` or `failed`); context window and tools are refused `busy` until
  the task settles. `resolve` adds a `worker` block (`selected`,
  `lastResponse`).

## Outside changes

`OutsideChanges` (`settings-outside.ts`) compares each store with the values Tron
last observed (`<tronHome>/gateway/settings/observed.json`) on every settings
read and on debounced directory events: the Mac `settings.json`, `trust.json`,
`mcp.json`, `models.json`, and each known project's `.pi/settings.json` and
`.pi/mcp.json` (at most 64 projects). A store's first sight is its baseline.

- Each differing key instance is one `outside` entry (file, `HEAD` and branch
  for repository files; redacted keys by digest). MCP servers and custom model
  providers are record subjects: name and added/changed/removed only, then
  `mcp.changed` or `models.customChanged`.
- Tron's own writes bracket the store (`begin`/`end`, `adopt`), so they are
  never outside changes. An entry that replaced Tron's value refers to it and
  offers Apply again.
- The tier is the key's floor for the direction and decides only the push.
  A revert, stash, reset or branch switch that drops Tron's value is just an
  outside change.

## Project writes

Tron edits a repository's `.pi/` under the project's store lock, keeping other
keys and layout, and stages it with `git add`. It never commits, pushes or opens
a pull request. When git cannot stage (no repository, ignored `.pi/`, locked
index) the write stands and the entry says why; other staged work is staged
anyway with a warning. The value applies from the working tree whether staged or
not. Row badges: matches `HEAD` → Project; else **Staged** or **Uncommitted**;
**Local only** outside a repository or when ignored. A commit holding Tron's blob
appends `committed` to the change.

## Home profile

Typed Profile keys resolve like any layer; learned notes may explain a value
but never carry one. A maintainer save of Home's chat model, thinking or tools
also sets the active chapter's Chat value in one bundle (refused whole while the
chapter runs). `permissions.budget.task` (`{ inputTokens?, outputTokens? }`) is
fixed at task admission; a raise waits for approval, a lower applies live.

**Model queues** (`model.queue[role]`, ordered `provider/id`, built-in `[]`):

| Role | Runs | Resolves | Empty means |
|---|---|---|---|
| `worker` | Home task workers | Profile > Mac, captured at task admission | Home's own model |
| `subagent` | Managed subagent children (`tron/subagent`) | Mac; Home task children use the captured queue | Each agent's own model |
| `background` | Home memory (Profile > Mac) and Knowledge (Mac) | as stated | The subagent queue |

`ModelQueueOwner` (`src/providers/model-queue.ts`) skips unregistered, virtual
or uncredentialed models, a usage-limit error in the last 15 minutes or ≥ 95%
provider usage, and moves on after a usage-limit error. Captured launch queues
are read-only and outrank later Mac defaults. Worker thinking is built in as
`{ "sameAs": "home" }`; an explicit `delegate` choice wins field by field.

**Learned-profile changes** (`home.profileChange`, Home's `profile` tool) go
through `SettingsChangePath.changeProfile`: one quiet entry per note (key
`home.profile.item`, qualifier `note`), grouped per change, undone as a group,
refused on a stale revision.

## Presentation

Words, badges and displayed values come from the schema and resolver; iOS
decides only layout and style.

- **Sections** are served by `settings.resolve`: Model, Workers & delegation,
  Compaction, Tools, Connection, Advanced, then Accounts, Sources, Storage.
- **Badges** are `{ kind, label, detail?, action? }` of kind Layer, Source,
  Scope, Authority or State; an unknown kind renders neutrally. Actions (Apply
  again, Use the current default, Follow the default, Review trust) go back
  through `settings.change`.
- **Controls**: `toggle`, `choice`, `number`, `text`, `secret`, `list`,
  `checklist`, `catalog`, `readOnly`. The client sends the controls and renderer
  version it implements; the Gateway serves the declared control, else its
  `fallback`, else `readOnly` with "Update Tron to edit". Never crash, never hide
  a value: every instance carries its `display`.
- **Options and validation** are served: `settings.options` pages a key's
  options (re-requested when a dependency changes); `dryRun` returns per-key
  errors and the tier. There is no client copy of a key's rules.
- **Changes** (`settings.history` + `presentation`): pending approvals first;
  Undo, Apply again, Approve, Decline.
- **Surfaces**: Global writes Mac, Session the Chat layer, Home only `profile`;
  Project is inspection only. Reset removes the owned override. Hand-built
  screens remain only for guided flows and content viewers.
