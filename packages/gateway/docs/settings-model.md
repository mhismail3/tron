# Settings model

**Status: proposed design.** Nothing here is implemented yet unless a section
says "today". Epic #758 tracks the work; the slices in
[Slices](#9-slices) are filed under it as Proposed. As each slice lands, the
section it implements becomes the current contract and the matching parts of
[Migration](#8-migration-from-today) and [Slices](#9-slices) are deleted. Those
two sections go away when the epic closes. See [open question Q1](#10-open-questions).

This document covers every setting that configures the model or the agent
harness: how each one is modelled, stored, resolved, changed and shown in Tron.
It is written from first principles. The groups follow the shape of an agent
harness, not today's screens, so that a new model capability or harness feature
gets a home without reorganizing anything.

## Contents

1. [Principles](#1-principles)
2. [Primitives](#2-primitives) and [stress tests](#25-stress-tests)
3. [Layers, precedence and timing](#3-layers-precedence-and-timing)
4. [The settings registry](#4-the-settings-registry)
5. [The change path and risk gate](#5-the-change-path-and-risk-gate)
6. [The Home profile layer](#6-the-home-profile-layer)
7. [Surfaces](#7-surfaces)
8. [Migration from today](#8-migration-from-today)
9. [Slices](#9-slices)
10. [Open questions](#10-open-questions)

## 1. Principles

1. **One key, one place per layer.** Each setting is one key. Each layer that
   may set it stores it in exactly one store. No surface keeps its own copy.
2. **The effective value is computed, never stored.** The Gateway resolves the
   value from the layers on every read. The only stored copies are the values
   fixed when a chat starts. Those are explicit chat-layer values that record
   where they came from ([3.4](#34-timing-fixed-at-start-or-follows-live)).
3. **The Gateway is the single resolver and the single change path.** Every
   actor uses one Gateway change path: the iPhone, Home, task workers, and agents
   with the `settings` tool. It records who asked, why, the diff and an undo, and
   it applies a risk tier. Files that Tron does not exclusively own (the repo's
   `.pi/`, the Mac `settings.json`) can still be edited from outside. The
   Gateway detects those edits and shows them. It never treats them as its own
   writes.
4. **Groups are harness primitives.** A key belongs to the primitive whose input
   to the model call it changes. Scope, source, authority and timing are
   metadata shown as badges on rows. They are never groups.
5. **The UI follows capabilities.** Controls come from the registry and the
   model catalog's declared capabilities, such as the thinking levels a model
   supports or its context limits. A new model needs no UI change. A new key
   needs a registry entry, not a new screen.
6. **Change a value where it lives.** Every row shows the effective value, the
   layer it came from, and an edit at a layer the surface owns. Changing a
   chat's model changes only that chat. Defaults change only in their own
   layer's editor. Tron does not keep a sticky "last used" default.

## 2. Primitives

A model call is roughly `f(model, context, tools)`, made under **permissions**
and driven by a **run** loop. Those are the five harness primitives. Four
non-harness sections supply things to them or sit outside them.

### 2.1 Harness primitives

| Primitive | Question it answers | Holds |
|---|---|---|
| **Model** | Which model runs, and how is each request made? | Model per role, thinking level, thinking budgets, context window, output limits, sampling, cache retention, offered models (`enabledModels`), and any future per-request model parameter. |
| **Context** | What does the model see, and how is that managed? | Instructions and system prompt, skills, prompt templates, memory, resources, attachments and image input, **compaction** and branch summaries. Resources follow one chain: sources, then loaded, then delivered. |
| **Tools** | What can the model do? | Active tools, built-in tools, MCP servers as tool providers, tools contributed by extensions, code mode, shell configuration of the shell tool, subagents and delegation. |
| **Permissions** | What is it allowed to do? | Project trust and the default trust policy, approvals and grants, Home task scopes, sandboxing, spend budgets, write permission on connections, per-tool approval. Each key's risk floor applies here. |
| **Run** | How do turns execute? | Steering and follow-up delivery, retry, timeouts, transport, proxy, cache warming, and hooks (event handlers) listed by event. |

**The assignment rule.** Put a key in the primitive whose input to the call it
changes:

- It is a parameter of one model request, or selects the model: **Model**.
- It decides what enters the request's messages or system prompt, or how that
  content is kept within budget: **Context**.
- It adds, removes or configures a callable tool: **Tools**.
- It widens or narrows what an action may do, or how much it may spend:
  **Permissions**.
- It governs what happens between and around requests (queueing, retrying,
  connecting): **Run**.

Two refinements came out of the code and the stress tests:

- **Model roles.** Tron makes model calls for more than the chat: compaction
  summaries, Home memory, Knowledge, and task workers. Model keys take a `role`
  qualifier (`chat`, `worker`, `summarizer`, `memory`, `knowledge`, and later
  `subagent` or `router`). A new auxiliary call adds a role, not a group. This
  also fixes D2: the three "Thinking" controls become thinking for the chat
  model, for workers, and for summaries.
- **Qualifiers are not layers.** Some keys are keyed by model, provider, tool or
  project: `modelContextWindows` and pi's `modelThinkingLevels` and
  `compaction.modelOverrides` are keyed by model, and trust is keyed by project
  path. A qualifier picks which instance of the key a value applies to. It is
  resolved within a layer. It does not add a layer.

**Context window lives in Model.** The window a chat uses is constrained by the
catalog's limits for that model, and for some providers it is a request option.
Context management (compaction thresholds, reserve and keep-recent tokens) stays
in Context and reads the window as an input.

**Retry and transport stay in Run.** Moving them under an Accounts provider entry
was considered and rejected. Accounts supplies credentials and catalogs and
should not configure behaviour. Retry and transport are operational policy that
follows live. When a per-provider value is needed, `provider` becomes a
qualifier on the Run key (pi's `retry.provider.*` is already provider-level), and
the Accounts row for that provider links to it.

### 2.2 Supply and non-harness sections

These provide things to the primitives, or have nothing to do with the harness.
They are kept apart so that the five primitives hold only behaviour.

| Section | Holds | Relation to the primitives |
|---|---|---|
| **Accounts** | Provider credentials and sign-in, the custom model catalog (`models.json`), connected services, MCP credentials. | Setup and status. Model and Tools draw on it. Model rows render from the catalog Accounts supplies. |
| **Sources** | Packages, extension, skill and prompt search paths, and `npmCommand`. | A package is a delivery format, not a primitive. Sources shows where each thing came from. Each contribution is shown in its primitive: tools in Tools, skills and prompts in Context, hooks in Run. |
| **Setup** | Pairing, Gateway lifecycle and updates, the Mac wizard, `sessionDir`, install telemetry, push notification policy, logs, import and export. | No effect on what the model is, sees or does. |
| **This iPhone** | Appearance, density, dashboard and subagent activity display. Stored on the device. | Never changes harness behaviour, and the section says so. |

The push notification policy is stored on the Gateway
(`<tronHome>/gateway/notifications.json`), not on the device, so it belongs to
Setup rather than This iPhone ([Q10](#10-open-questions)).

### 2.3 Today's keys by primitive

Keys exposed by `SettingsService` today (`packages/gateway/src/admin/settings-service.ts:121-195`),
plus the Tron stores outside `settings.json`:

| Key (storage) | Primitive | Allowed layers | Timing |
|---|---|---|---|
| `defaultProvider` + `defaultModel` → `model.ref[role=chat]` | Model | Chat, Profile, Project, Mac | Fixed |
| `defaultThinkingLevel`, pi `modelThinkingLevels` → `model.thinking[role=chat]` | Model | Chat, Profile, Project, Mac | Fixed |
| `thinkingBudgets` | Model | Project, Mac | Fixed |
| `modelContextWindows` → `model.contextWindow[model]` | Model | Chat (session entry), Profile, Project, Mac | Fixed |
| `enabledModels` → `model.offered` | Model | Project, Mac | Live (picker filter only) |
| `compaction.thinkingLevel` → `model.thinking[role=summarizer]` | Model | Project, Mac | Live |
| `compaction.enabled`, `reserveTokens`, `keepRecentTokens`, `instructions` | Context | Chat, Project, Mac | Live |
| `branchSummary.reserveTokens` | Context | Project, Mac | Live |
| `images.autoResize`, `images.blockImages` | Context | Chat, Project, Mac | Fixed |
| `extensions`, `skills`, `prompts`, `packages` | Sources (contributions shown in Context, Tools and Run) | Project, Mac | Fixed (explicit Reload) |
| `defaultTools` → `tools.active` | Tools | Chat, Profile, Project, Mac | Fixed |
| `codemode.mode`, `codemode.inlineBudget` | Tools | Project, Mac | Fixed |
| `shellPath`, `shellCommandPrefix` | Tools | Project, Mac | Fixed (new chat) |
| MCP servers (`mcp.json`, global and project) | Tools (credentials in Accounts) | Project, Mac | Fixed (Reload) |
| Project trust (`<tronHome>/agent/trust.json`, per path) | Permissions | Mac, qualified by project | Live (tightening); see [3.5](#35-the-trust-exception) |
| `defaultProjectTrust` | Permissions | Mac only (pi enforces this) | Live |
| Connection write permission (`connections.policy.update`) | Permissions | Mac | Live |
| Home task scopes and grants (Home task store) | Permissions | Profile | Live |
| `steeringMode`, `followUpMode` | Run | Chat, Project, Mac | Live |
| `retry.*`, `retry.provider.*` | Run | Project, Mac | Live |
| `transport`, `httpIdleTimeoutMs`, `websocketConnectTimeoutMs` | Run | Project, Mac | Live |
| `httpProxy` | Run | Mac only (pi enforces this) | Restart |
| pi `cacheWarming` (not exposed today) | Run | Mac only (pi enforces this) | Live |
| Home memory model (`home.json` `memory.model`) → `model.ref[role=memory]` | Model | Profile | Live (next memory pass) |
| `npmCommand` | Sources | Mac | Live |
| `sessionDir` | Setup | Mac | Restart |
| `enableInstallTelemetry` | Setup | Mac | Live |
| Push policy (`notifications.json`) | Setup | Mac | Live |
| Terminal-only pi keys (`theme`, `tuiMode`, ...) | Not shown | | |

### 2.4 Features decompose into primitives

A feature is not a primitive. It is a set of keys, and each key lands in its own
primitive. Delegation is an example: the worker model is Model (`role=worker`),
the ability to delegate is Tools, the grants and budgets are Permissions, and
the delegated brief is Context. The worker's own chat then resolves like any
other chat. The primitives stay fixed while features come and go.

### 2.5 Stress tests

Each case shows where a plausible future change lands. Where it did not fit
cleanly, the model was adjusted, and the adjustment is recorded.

| # | Future case | Lands in | Fit |
|---|---|---|---|
| 1 | A new reasoning or verbosity parameter (for example a `verbosity` enum) | Model: `model.verbosity[role,model]`. Its row appears only when the catalog declares support, with only the declared values. Fixed at start. | Clean. |
| 2 | Prompt caching controls | Cache retention or TTL is a request parameter, so Model: `model.cacheRetention`. Keep-alive warming between runs is loop behaviour, so Run: `run.cacheWarming` (Mac only, as pi already enforces). | Splits by the assignment rule. Recorded as the rule's worked example. |
| 3 | A computer-use tool | Enabling the tool is Tools (`tools.active`). Which apps it may drive, and whether it may use foreground input, are Permissions (floor: wait for tap to widen). The macOS Screen Recording status is Setup. | Clean. The feature spans three primitives by design. |
| 4 | Sandboxing the shell | Permissions: `permissions.sandbox.mode`. | **Adjusted.** Permissions needs asymmetric timing: tightening applies live, and widening applies at the next chat start or after approval. The registry's `timing` field gained `live-tighten`. |
| 5 | A new memory type (project memory, vector recall) | Context: `context.memory.<kind>`, with its own sources, loaded and delivered chain. Its model is Model `role=memory`. If a package ships it, Sources shows the package. | Clean. |
| 6 | Per-tool approval ("ask before `bash`") | Permissions: `permissions.toolApproval[tool]`, qualified by tool name. Loosening waits for a tap. Tightening is quiet. | Clean once qualifiers exist. |
| 7 | Multi-model routing, or a subagent model | Model roles: `model.ref[role=subagent]`, and a router is a model ref (virtual models already exist). | **Adjusted.** Without roles this would need a new group. Roles were added to Model for this case. |
| 8 | Cost caps (per chat, per task, per day) | Permissions: `permissions.budget.*`. Raising waits for a tap. Lowering is quiet and applies live. | Clean, with direction-aware floors ([4.1](#41-fields)). |
| 9 | A new provider auth flow (device code, workload identity) | Accounts only. The catalog grows, and Model rows render from it. | Clean. No harness key changes. |
| 10 | An output-token limit or sampling control | Model: `model.maxOutputTokens`, `model.temperature`, shown only when the catalog declares them. | Clean. |
| 11 | An extension hook that blocks tool calls (a guard) | Hooks are code. Sources lists the extension. Run lists the hook under its event. | **Imperfect.** A hook's effect can belong to any primitive. Hooks stay listed in Run by event, with a badge for effects that matter elsewhere ("can block tools"). Hook behaviour is not a setting key, so this does not move any key. |
| 12 | A voice or realtime model | Model `role=voice`. Its transport options are Run qualified by provider. | Clean. |

## 3. Layers, precedence and timing

### 3.1 Precedence

Top wins:

1. **Chat**: this chat's own values.
2. **Profile (Home)**: the Home profile's typed values, for chats in that profile.
3. **Project**: the repo's `.pi/` directory, shared through git.
4. **Mac**: the Gateway-global layer.
5. **Built-in**: pi defaults plus Tron's built-in policy.

Per-message choices (steer or follow-up on a queued message, and the model and
thinking a `delegate` call names) are **turn-level inputs**. They are not a
stored layer. A turn-level input either applies to that one message, or writes
a chat-layer value of a chat being created (a delegated worker).

Each key's `layers` field says which layers may set it. A value at a disallowed
layer is ignored and shown as a diagnostic. For example, pi already ignores
`defaultProjectTrust` and `httpProxy` in project settings.

### 3.2 Where each layer is stored

| Layer | Store | Owner |
|---|---|---|
| Chat | The session JSONL. pi's `model_change` and `thinking_level_change` entries, Tron's `tron.context-window.v1` custom entry (`packages/gateway/src/providers/context-window-policy.ts:7`), active tools, and a new `tron.settings.v1` entry for the other chat-layer keys and the provenance of fixed values. | The session's runtime slot lane. |
| Profile (Home) | A typed profile store beside `home.json`: `<tronHome>/gateway/home/profile.json`. Not Knowledge note text ([6](#6-the-home-profile-layer)). | `HomeOwner`. |
| Project | `<cwd>/.pi/settings.json`, `<cwd>/.pi/mcp.json` and the rest of the repo `.pi/`. | The repo (git). The Gateway is Tron's only writer, but not the file's only writer. |
| Mac | `<tronHome>/agent/settings.json`, `models.json`, `mcp.json`, `trust.json`, plus the Gateway stores (`connections`, `notifications.json`). | The Gateway. pi CLI runs and hand edits are external writers. |
| Built-in | Code: pi defaults and Tron's built-in policy table in the registry. | The release. |

Today's audit put the Mac layer at `~/.pi/agent/settings.json`. In the current
code the agent directory is `<tronHome>/agent` (`packages/gateway/src/config.ts:434`),
so the Mac layer is `<tronHome>/agent/settings.json`.

### 3.3 Who gets which layers

- An **ordinary chat in a project** resolves Chat > Project > Mac > Built-in. It
  has no profile layer unless Home started it ([Q2](#10-open-questions)).
- **Home's own chat** has no Project layer. Home runs in a neutral workspace with
  no project discovery (`packages/gateway/src/sessions/runtime-slot.ts:1919-1924`).
  It resolves Chat > Profile (Home) > Mac > Built-in.
- A **Home task worker** is an ordinary chat in its target project. At start, it
  receives copies of the Home profile values for the worker role in its chat
  layer ([6.3](#63-worker-model-same-as-home)). After that it resolves like any
  chat, and its fixed values do not follow later profile edits.

### 3.4 Timing: fixed at start or follows live

Timing is a property of each key, chosen by what the key affects.

- **Fixed at start**: anything that changes what the model is or sees. That
  covers the model, thinking, context window, tools, instructions, skills,
  resources and image input. When a chat starts, the resolver computes these and
  writes them into the chat layer, each with provenance:
  `{ value, from: "mac" | "project" | "profile" | "builtin", at, ref }`. They
  are then explicit chat values. The row shows **"From default at start: X"**
  and offers **"Use the current default"**, which re-resolves the key and writes
  the new value through the change path. Resources already behave this way: they
  reload only on an explicit Reload, and "Use the current default" for
  resources is Reload.
- **Follows live**: operational policy: retry, transport, timeouts, compaction
  thresholds, queue delivery, budgets when tightened. Nothing is copied. The
  chat reads the resolved value at its effect point (next turn, next request, or
  next compaction). A live key may still allow a chat-layer override, for
  example the queue delivery mode.
- **Live-tighten** (Permissions only): narrowing applies live, while widening
  waits for the next start or an approval ([2.5](#25-stress-tests) case 4).

Effect points are separate from timing: `next-turn`, `next-request`,
`new-chat`, `reload` or `restart`. The row shows them when a change does not
take effect immediately ("Applies after restart").

**Today.** Fixed-at-start already holds for the model, thinking and context
window, through session entries, and for resources, through Reload. No
provenance is recorded, so a row cannot say where the value came from. Only
compaction policy follows live: `settings.update` refreshes it for open chats
(`packages/gateway/src/transport/gateway-service.ts:1974-1976`). Each runtime
builds its own `SettingsManager` when it starts (`runtime-slot.ts:1924`), so,
as far as the code reads, retry, transport and queue modes reach an open chat
only when its runtime is rebuilt. That is inferred, and slice 7 verifies and
fixes it.

**No sticky defaults (verified).** pi 1.0.4's `AgentSession.setModel(model, options)`
and `setThinkingLevel(level, options)` write `defaultModel` and
`defaultThinkingLevel` only when `options.persist` is true. Tron calls both
without options (`runtime-slot.ts:9284`, `runtime-slot.ts:9323`), so changing a
chat's model never changes a default. Two related writes exist:

- pi's own terminal model selector and its post-login model choice can persist a
  default. That is a terminal-only path Tron does not use. If someone runs the
  pi CLI against the same agent directory, the result is an external edit
  ([5.6](#56-external-edits)).
- A Home chat's model change is written to `home.json` so that a later chapter
  or re-enable restores it (`runtime-slot.ts:9285-9289`). That is Home's own
  chat-layer continuity across chapters, not a default for other chats. It stays.

### 3.5 The trust exception

Project trust is the only per-project key that is never stored in the repo. A
repo must never be able to grant itself trust. Trust is stored in
`<tronHome>/agent/trust.json`, keyed by canonical project path, through pi's
`ProjectTrustStore` (`packages/gateway/src/admin/trust-service.ts:30`). In the
registry it is a Mac-layer key with a `project` qualifier. Its allowed layers
exclude Project, so a `.pi/` value for any Permissions key is ignored and shown
as a diagnostic. Trusting a project always waits for the maintainer's tap
([5.4](#54-tiers-floors-and-escalation)). The default policy
(`defaultProjectTrust`: ask, always or never) is Mac only, as pi enforces.

### 3.6 An untrusted project's layer

An untrusted project's `.pi/` layer is **present but not applied**.

- The Gateway reads `.pi/settings.json` as data. That executes nothing, and
  executable resources stay gated by trust as today. `settings.resolve` returns
  the Project layer value with `applied: false, reason: "untrusted"`. The
  effective value comes from the next layer down.
- Rows show the repo's value struck through, with the badge **"Project · not
  applied (untrusted)"** and a **Review trust** action that opens the Project
  card. Today `settings.get` returns `project: null` when untrusted
  (`settings-service.ts:138`), which hides what trusting would change.
- Values from an untrusted repo are untrusted content. When Home or an agent
  reads them through `settings.resolve`, that turn is marked as having read
  untrusted content ([5.4](#54-tiers-floors-and-escalation)).
- Tron never writes the Project layer of an untrusted project. That matches
  today's `trust_required` refusal (`settings-service.ts:202-204`).

## 4. The settings registry

One typed registry in the Gateway describes every key. It drives:

- resolution (`settings.resolve`),
- validation and application (`settings.change`),
- the risk gate,
- the iOS sections and rows.

iOS renders rows from the registry projection. Native views stay hand-built for
quality, but the registry decides each row's section, order, control type,
allowed values, badges and editability, and a test fails if a registry key has
no row or a row has no key. A new key then lands in the right primitive with no
UI reorganization.

### 4.1 Fields

| Field | Meaning |
|---|---|
| `id` | A stable dotted id, independent of storage: `model.thinking`. |
| `primitive` | `model`, `context`, `tools`, `permissions` or `run`, or a supply section: `accounts`, `sources`, `setup` or `iphone`. |
| `group` | An optional sub-heading within the primitive (for example `Compaction`). |
| `qualifiers` | Any of `role`, `model`, `provider`, `tool`, `project`. |
| `type` | The value type and its static constraints. |
| `capability` | An optional catalog-derived constraint, for example "thinking levels the selected model supports" or "context limits for this model". The UI shows only valid values. |
| `layers` | The allowed layers, each with its storage binding (file and path, or session entry type). |
| `builtin` | The built-in value, or `pi-default`. |
| `timing` | `fixed`, `live` or `live-tighten`. |
| `effect` | `next-turn`, `next-request`, `new-chat`, `reload` or `restart`. |
| `risk` | The minimum tier per direction: `{ widen, narrow }` or a single tier. Tiers are `quiet`, `notify` and `approve`. |
| `writers` | Which actors may request a change: `ui`, `home`, `worker` or `agent`. `external` is observed, never admitted. |
| `sensitivity` | `redact`: show "set" or "changed", never the value (for example `httpProxy`). |
| `applier` | The owner that performs the write: the pi settings file, a session entry through the slot lane, the profile store, the trust store, the MCP config, or a connections policy. |

Provenance is not a field. It is part of every resolved value:
`{ value, layer, applied, reason?, fixedAt? }`.

### 4.2 Example entries (real keys)

| id | primitive | qualifiers | layers → storage | timing / effect | risk (widen / narrow) | writers |
|---|---|---|---|---|---|---|
| `model.ref` | model | `role` | chat → `model_change`; profile → `profile.json`; project/mac → `defaultProvider`+`defaultModel` | fixed / next-turn | quiet / quiet (role=worker from Home: notify) | ui, home, agent |
| `model.thinking` | model | `role`, `model` | chat → `thinking_level_change`; profile; project/mac → `defaultThinkingLevel`, `modelThinkingLevels`; summarizer → `compaction.thinkingLevel` | fixed (summarizer: live) / next-turn | quiet | ui, home, agent |
| `model.contextWindow` | model | `model` | chat → `tron.context-window.v1`; project/mac → `modelContextWindows` | fixed / next-turn | quiet | ui, home, agent |
| `model.ref[role=memory]` | model | `role` | profile → `profile.json` (today `home.json` `memory.model`) | live / next memory pass | notify (spends) | ui, home |
| `context.compaction.reserveTokens` | context | `model` | chat; project/mac → `compaction.reserveTokens`, pi `compaction.modelOverrides` | live / next compaction | quiet | ui, home, agent |
| `context.compaction.instructions` | context | | project/mac → `compaction.instructions` | live / next compaction | notify | ui, home |
| `context.images.block` | context | | chat; project/mac → `images.blockImages` | fixed / next-turn | quiet | ui, home, agent |
| `tools.active` | tools | | chat → active tool set; profile; project/mac → `defaultTools` | fixed / next-turn | notify (adding) / quiet (removing) | ui, home, agent |
| `tools.codemode.mode` | tools | | project/mac → `codemode.mode` | fixed / new-chat | quiet | ui, home |
| `permissions.projectTrust` | permissions | `project` | mac → `trust.json` | live-tighten | approve / notify | ui (Home may request) |
| `permissions.defaultProjectTrust` | permissions | | mac → `defaultProjectTrust` | live | approve / notify | ui |
| `permissions.connectionWrite` | permissions | `connection` | mac → connections policy | live-tighten | approve / quiet | ui |
| `permissions.budget.task` | permissions | | profile | live-tighten | approve / quiet | ui, home |
| `run.queue.steeringMode` | run | | chat; project/mac → `steeringMode` | live / next-turn | quiet | ui, home, agent |
| `run.retry.maxRetries` | run | `provider` | project/mac → `retry.maxRetries`, `retry.provider.maxRetries` | live / next-request | quiet | ui, home, agent |
| `run.transport` | run | `provider` | project/mac → `transport` | live / next-request | quiet | ui, home, agent |
| `run.httpProxy` | run | | mac → `httpProxy` | restart | notify, redact | ui |

### 4.3 How far today's code is from this

- `SettingsService` (`packages/gateway/src/admin/settings-service.ts`) already has:
  - hand-written validators per key (`applyPatch`, `:267-356`);
  - a computed effective value through pi's `SettingsManager` merge (`get`, `:121-195`);
  - two layers (global and project) with trust gating (`:202-204`).

  That is the validation half of a registry. It has no metadata (primitive,
  timing, layers, risk, writers), no chat or profile layer, no provenance per
  key, no ledger and no undo. The validators move into registry entries. They
  are not duplicated.
- pi exposes a TypeScript `Settings` interface but no runtime schema. Its docs
  already state allowed layers for a few keys (`defaultProjectTrust`,
  `httpProxy` and `cacheWarming` are agent-directory only). The registry
  encodes those rules once and checks them in a test against the pinned pi
  version, so a pi upgrade that adds or moves a key fails loudly.
- Chat-layer setters are separate RPCs with their own guards:
  `session.setModel`, `setThinking`, `setContextWindow` and `setTools`
  (`runtime-slot.ts:9271-9344`). They keep their slot-lane appliers and become
  appliers behind `settings.change`.
- Trust (`trust.set`), MCP (`mcp.*`), connections policy, Home memory
  (`home.configureMemory`) and Home task grants each have their own RPC. Those
  that hold harness keys become registry appliers. Accounts flows (`auth.*`,
  `connections.setup.*`, `models.custom.*`) stay their own guided flows. They
  record into the same ledger, and credential values are never recorded.

## 5. The change path and risk gate

### 5.1 One path for every actor

| Actor | How it asks | Identity recorded |
|---|---|---|
| The maintainer on iPhone | `settings.change` from a row | Paired device id. The tap is the approval. |
| Home | The `settings` tool in Home's toolset | Home session and chapter, plus the triggering message id. |
| A task worker | The `settings` tool, if its grant includes it | The worker session and the task id. |
| An agent in an ordinary chat | The `settings` tool | The session id and the tool call id. |
| Outside Tron (hand edit, `git pull`, pi CLI) | Not admitted. Detected by the watcher. | `external`, plus the file and git `HEAD` when it is a repo ([5.6](#56-external-edits)). |

The `settings` tool is a Tron module tool, a thin client of `settings.change`
and `settings.resolve`. Agent instructions tell agents to use it instead of
editing `settings.json`. Direct edits are still detected and shown.

### 5.2 The request and the record

`settings.change` takes a `commandId` and a list of changes:
`{ key, qualifiers, layer, target (session, profile, project path or Mac), op: set | unset, value, expected }`,
plus a required `reason` for every non-UI actor. `expected` is the value or
revision the actor read, so a stale change is refused instead of overwriting.

The steps are:

1. Validate against the registry: type, capability, allowed layer and writer.
2. Compute the tier ([5.4](#54-tiers-floors-and-escalation)).
3. If the tier is `approve`, create a pending change, notify the maintainer and
   return `pending`.
4. Apply through the key's applier, under that store's own lock.
5. Append to the ledger.
6. Broadcast `settings.changed { changeId, keys, layer, target }`.

A multi-key change applies atomically within one store. Across stores it applies
in a fixed order and rolls back the stores it already changed, the way
`TrustService.setAndApply` does today (`trust-service.ts:118-157`).

**The ledger** is `<tronHome>/gateway/settings/changes.jsonl`. It is append-only
and bounded ([Q12](#10-open-questions)). Each entry holds:

- `changeId`, the time, and the actor with its identity;
- the layer and target;
- the key, with `before` and `after` (redacted for sensitive keys; credentials
  never appear);
- the reason;
- the tier and why: the floor, untrusted-content escalation, or a risk-model
  raise;
- the status: `applied`, `pending`, `approved`, `declined`, `expired`, `failed`
  or `external`;
- `undoOf` when the entry is an undo.

### 5.3 Undo

`settings.undo { changeId }` writes `before` back through the same path, as a
new change with `undoOf`. It is refused with a conflict if the current value is
no longer `after`, and the row shows what changed since. Undo is gated like any
other change. Undoing a narrowing widens, so undoing "remove trust" waits for a
tap.

### 5.4 Tiers, floors and escalation

The three tiers:

- **quiet**: apply and record.
- **notify**: apply, record, and tell the maintainer, with an undo in the
  notification.
- **approve**: hold until the maintainer taps approve. A pending change expires
  ([Q8](#10-open-questions)).

How the tier is computed:

1. **The floor**, fixed per key and direction in the registry policy.
   Trusting a project, adding credentials and raising budgets are always
   `approve`. So is widening any Permissions key.
2. **Untrusted-content escalation.** If the requesting turn read untrusted
   content, the tier rises ([Q6](#10-open-questions)). Untrusted content means
   web fetch or search results, X posts, external Knowledge sources, MCP tool
   output, and untrusted project files or values. The proposal: raise
   `quiet` to `notify`, and `notify` to `approve`.
3. **The risk model.** A decision model in front of the action can only raise
   the tier, never lower it. If it fails or times out, the computed tier stands.
4. **The actor.** A change the maintainer makes from a row applies at once, since
   the tap is the approval. Always-approve keys still show a confirmation in the
   UI. Home and agent changes use the computed tier.

The floors live in code (the registry). Whether the maintainer may raise a floor
is [Q7](#10-open-questions). Nobody can lower one.

### 5.5 Where approvals appear

Pending changes use the same pattern as Home task grants
(`home.decideTaskGrant`):

- a push notification with Approve and Decline;
- a "Waiting for you" row in Manage Home, and in Manage Session when a chat's own
  agent asked;
- a decision RPC.

The ledger gives each key's history ("Changed by Home 2h ago: reason · Undo").

### 5.6 External edits

The Gateway watches the files it resolves from, but does not own:

- the Mac `settings.json`, `models.json`, `mcp.json` and `trust.json`;
- each known project's `.pi/settings.json` and `.pi/mcp.json`, for every project
  with an open chat or a dashboard entry.

Today nothing watches these (the only signal is the post-write
`settings.changed` broadcast at `gateway-service.ts:1977`).

When a file changes:

1. Diff it per key against the last snapshot.
2. If the diff equals the post-image of the latest ledger entry for that store,
   it was Tron's own write.
3. Otherwise record an `external` ledger entry with the file, the per-key diff,
   and the git `HEAD` and branch for repo files. Broadcast it.
4. Rows show **"Changed outside Tron"** with the diff. The Project card lists
   what the repo changed after a pull.
5. External changes to Permissions keys, or to anything that adds
   trust-requiring resources, notify the maintainer. Trust itself still gates
   loading.
6. If an agent's tool call wrote that exact path just before, the entry names
   the session ("likely by chat X"). That attribution is a hint, not identity.

Fixed-at-start keys in open chats are unaffected, since they are chat values.
Live keys take the new value at their next effect point.

## 6. The Home profile layer

### 6.1 What it is

Profiles are Home-only for now. They are designed as named layers so that they
could become general later. The Home profile has two parts.

- **Typed values.** These are registry keys whose allowed layers include
  `profile`. Examples are the worker model and thinking, the memory model, and
  task budgets and scopes. They resolve like any layer value. They show a
  **"Profile: Home"** badge and go through the change path, so they can be
  undone and risk-gated.
- **Instructions and learned notes.** These are the Knowledge-backed learned
  profile owned by #734 (`packages/gateway/src/home/home-profile.ts`). Notes may
  explain *why* a value is set ("cheap model for lookups because ..."). They
  never carry the value itself. A `delegation-default` note that names a model
  is advice to Home. It is not resolved, and the typed key wins.

The typed values live in `<tronHome>/gateway/home/profile.json`, owned by
`HomeOwner` and written only by the change path. The memory model moves there
from `home.json` `memory.model` (`packages/gateway/src/home/home-owner.ts:77`).
Its RPC `home.configureMemory` (`:978`) becomes a registry applier. The Home
chat's own model in `home.json` (`home-owner.ts:72`) stays where it is: it is
Home's chat layer, carried across chapters, not a profile default.

### 6.2 Who it applies to

The profile layer applies to Home's own chat and is copied into chats Home
starts. It does not apply to ordinary chats the maintainer starts
([Q2](#10-open-questions)). A key's `layers` field decides whether a profile may
set it. Home-only keys (`model.ref[role=worker]`, `model.ref[role=memory]` and
`permissions.budget.task`) have the profile as their highest default layer.

### 6.3 Worker model: "same as Home"

The new delegation default: workers start with the same model as the active
Home session. It is modelled as a profile key:

```
model.ref[role=worker]       profile value: { "sameAs": "home" }   (built-in: unset)
model.thinking[role=worker]  profile value: { "sameAs": "home" }   (Q4)
```

A worker's model resolves once, when the worker starts
(`packages/gateway/src/home/home-task-dispatcher.ts:190-193`), in this order:

1. **The `delegate` call's `model` and `thinking`**: a turn-level input
   (`home-task-worker-choice.ts`, `tron-home-extension.ts:29,77`). An explicit
   choice for this task wins ([Q5](#10-open-questions)).
2. **The profile value.** `sameAs: home` reads the Home chat's effective model at
   that moment: its chat layer, which is the current Home session's model. An
   explicit model ref is used as is.
3. **Otherwise** the worker's own chat resolution: Project, then Mac, then
   Built-in.

The result is admitted by the existing rules (registered, physical, has
credentials, supported thinking level). It is then written into the worker's
chat layer with provenance, for example
`{ from: "profile", via: "sameAs:home", value: anthropic/<model>, at }`. Manage
Session for the worker shows **"From Home profile at start: same as Home
(<model>)"**. If the Home model cannot be used for a worker (for example its
credentials were removed), resolution falls through to step 3, and the task
record and the row say why.

Changing Home's model later does not change running workers: the worker model
is fixed at start. Changing the profile key from `sameAs: home` to an explicit
model is a profile-layer change through the change path. Its floor is `notify`
for Home and `quiet` for the maintainer's tap.

## 7. Surfaces

Every surface shows the same five primitive sections in the same order: Model,
Context, Tools, Permissions, Run. Each row shows:

- the effective value;
- a **source badge**: Chat, Profile: Home, Project, Mac or Built-in, plus "not
  applied (untrusted)" or "Changed outside Tron" when they apply;
- a **timing badge** when it helps: "From default at start" or "Follows
  default";
- an edit at the layer that surface owns. A key the surface cannot edit at its
  layer shows **"Edit at Project"** or **"Edit at Mac"**, which opens that
  layer's editor.

Scope, source, authority and timing are badges, never groups. The retired
top-level groups (agent-tunable, manual bootstrap, UX-only) are gone. Setup and
This iPhone remain as non-harness sections in Settings.

### 7.1 Manage Session (an ordinary chat)

- **Edits the Chat layer.** The five sections show this chat's values, with
  fixed values showing "From default at start: X · Use the current default".
- **The Project card** comes first: the project name, trust state and any
  external changes. It opens the project layer editor ([7.3](#73-project-card)).
- **Settings** is a row inside it. This is the one door per chat: the
  ordinary-chat gear opens Manage Session, not Settings
  (`ChatView.swift:2864-2876`, `ChatRoutes.swift:89-101`).
- The existing non-setting rows (history, fork, export, archive) stay in a
  Session section after the primitives.

### 7.2 Manage Home

- The same five sections for Home's chat. Rows edit the Chat layer, or the
  Profile layer for profile keys: worker model, worker thinking, memory model,
  task budgets and scopes, each with a "Profile: Home" badge.
- The Home-specific rows (memory browser, chapters, tasks and permissions,
  pending approvals) stay. #734's "About you" (learned notes) sits beside the
  typed profile values and explains them.
- #743's next-prompt preview and delivered-context viewing are the **delivered**
  stage of Home's Context section. They land there.
- Home's gear and context ring keep their current routing (#748).

### 7.3 Project card

- **Edits the Project layer** (the repo `.pi/`) for keys whose `layers` include
  Project, in the same five sections.
- Its Permissions section holds **trust**, stored outside the repo, with review
  and revoke.
- It shows **"Changed outside Tron"**: what the repo's `.pi/` changed, by
  commit, after a pull.
- For an untrusted project it shows the repo's values as not applied, with
  Review trust.
- Writes change the working tree only. Committing is the maintainer's git
  workflow ([Q14](#10-open-questions)).
- **Opened from** Manage Session (the primary route) and from the dashboard
  project list, as the same component. No chat is needed.

Why the dashboard entry matters: today the only way to edit project settings
without a chat is the Global/Project scope picker in chat-opened Settings
(`SettingsScopeRow.swift`, `AgentDefaultsSettingsView.swift`). Once the Project
card replaces those pickers, opening it from the dashboard project row keeps
three things possible: setting a project's model and tools before its first
chat, reviewing or revoking trust, and seeing what the repo's `.pi/` changed
after a pull. It costs little: the same component and no new Gateway surface. It
is a late, small slice after the Project card.

### 7.4 Settings

- **Edits the Mac layer only.** The Global/Project scope pickers are removed,
  and project editing moves to the Project card.
- Sections in order: Model, Context, Tools, Permissions, Run, then Accounts,
  Sources, Setup and This iPhone.
- Data and diagnostics (logs, import) move under Setup.
- A **Changes** row lists the ledger with filters by actor and layer.

### 7.5 New Session

- After the project is picked, the sheet shows the resolved values for that
  project with source badges, mainly Model (model, thinking), and the trust
  decision when one is needed.
- Overriding a value sets the new chat's Chat layer at creation. It never
  changes a default.
- `NewSessionSheet.swift:94-96` already says "Use the current agent default". It
  gains the badge that says which default.

### 7.6 Each duplicate resolved to one editor

| Audit | Today | One key, one editor per layer |
|---|---|---|
| D1. Model and thinking in six places, with three meanings | Manage Session, Agent Defaults (global or project), New Session, Manage Home chat model, Home memory model, `delegate` arguments | `model.ref` and `model.thinking`, by role. The Chat layer is edited in Manage Session and Manage Home (and New Session at creation). Project in the Project card. Mac in Settings › Model. The worker and memory roles in Manage Home (Profile). `delegate` arguments are turn-level inputs. |
| D2. Three controls called "Thinking" | Chat thinking, default thinking, compaction "Summary Thinking" (`CompactionSettingsView.swift:102`) | One key, `model.thinking`, with roles: "Thinking" (chat), "Worker thinking" and "Summary thinking", all in Model, each badged with its layer. |
| D3. "Project Trust" with three meanings | Settings › Project Trust as the default policy (dashboard) or as this project's decision (chat) (`SettingsView.swift:99-107`), and the New Session trust prompt | `permissions.projectTrust[project]`, edited in the Project card and prompted by New Session. `permissions.defaultProjectTrust` is in Settings › Permissions (Mac). |
| D4. Resources with four truths (installed, search paths, loaded, delivered) | Extensions, Locations and Overrides, Project Resources, Agent Instructions | Sources: installed and search paths, with where each came from. Context, Tools and Run show each contribution's chain: source, then loaded in this chat, then delivered in the last or next prompt. Each item links its stages. |
| D5. Context window | Manage Session slider (session entry) and Agent Defaults (`modelContextWindows`) | `model.contextWindow[model]`: Chat in Manage Session, Project in the card, Mac in Settings. One slider component with a badge. |
| D6. Compaction shown read-only in a second place | Settings › Compaction edits, and its live policy is repeated read-only (`CompactionSettingsView.swift:244-257`) | Context › Compaction: effective value and badge in Manage Session (with a chat override where allowed), edited at its layer. |
| D7. Queue delivery | Long-press per message versus the `steeringMode` and `followUpMode` defaults | The long-press is a turn-level input and shows "Default: X (Mac)". The defaults are `run.queue.*` in Run. |
| Untracked agent edits | Agents edit `settings.json` directly, and nothing records it | The `settings` tool through the change path. Direct edits are detected as external ([5.6](#56-external-edits)). |

## 8. Migration from today

Re-verified against `main` at `b76f6ca80`.

**Gateway**

| Today | Becomes |
|---|---|
| `admin/settings-service.ts:121-195` `get`: two documents plus an effective object | `settings.resolve`, from the registry: every key with its value, layer, applied flag and badges, for a target (Mac, project, session or profile). `settings.get` is removed when its last client moves (no alias). |
| `admin/settings-service.ts:197-356` `update` and `applyPatch`: hand validators | Registry entries own validation. `SettingsService` becomes the pi-settings-file applier. |
| `transport/gateway-service.ts:1948-1978` `settings.get` and `settings.update` | `settings.resolve` and `settings.change`, plus `settings.undo` and `settings.history`. |
| `transport/gateway-service.ts:1671-1690` `session.setModel` and `setContextWindow`; `runtime-slot.ts:9271-9344` setters | Appliers behind `settings.change` for the Chat layer. The lane guards (`assertConfigurationIdle`, expectations) stay. |
| `transport/gateway-service.ts:1980-1996` `trust.set`; `admin/trust-service.ts:107-157` | The `permissions.projectTrust` applier. `setAndApply`'s rollback pattern becomes the cross-store rule. |
| `home/home-owner.ts:77,978` memory model in `home.json`, `home.configureMemory` | `model.ref[role=memory]` in `profile.json`, applied by `HomeOwner`. |
| `home/home-task-dispatcher.ts:190-193`, `home-task-worker-choice.ts`, `tron-home-extension.ts:29,77` | Worker resolution per [6.3](#63-worker-model-same-as-home): `delegate` arguments, then the profile `sameAs: home`, then the chat default. |
| `home/home-profile.ts:21-23` `delegation-default` notes | Kept as the *why*. Values move to typed keys. |
| `runtime-slot.ts:1924` one `SettingsManager` per runtime build; compaction-only live refresh (`runtime-registry.ts:3656`) | Live keys read the resolver at their effect point, and fixed keys are copied with provenance at chat start. |
| `context-window-policy.ts:7` `tron.context-window.v1` | Kept as the Chat-layer store for `model.contextWindow`, with provenance added through `tron.settings.v1`. |
| No settings file watcher | External-edit watcher ([5.6](#56-external-edits)). |
| `notifications/grant-store.ts:223` push policy | Unchanged storage, shown under Setup. |

**iOS**

| Today | Becomes |
|---|---|
| `UI/Chat/ChatView.swift:2864-2876` gear opens Settings for ordinary chats | Opens Manage Session. Home is unchanged. |
| `UI/Chat/ChatRoutes.swift:89-101` `SettingsView(scope: .project)` sheet | Reached as a row inside Manage Session. |
| `UI/Chat/ChatComposerView.swift:259` context ring | Unchanged: it already opens Manage Session (#748). |
| `UI/Chat/SessionContextSheet.swift:530-590` model card, thinking and context window; `:649-690` session section | The five primitive sections plus the Project card and the Settings row. |
| `UI/Chat/HomeSheets.swift:233-291,351` chat model and context window values, memory model | The five sections plus Profile rows. |
| `UI/Settings/SettingsView.swift:39-122` groups This iPhone, Agent, Tools & Extensions, Data & Diagnostics, with scope-dependent trust | Model, Context, Tools, Permissions, Run, Accounts, Sources, Setup, This iPhone. Mac layer only. |
| `UI/Settings/SettingsScopeRow.swift`, `AgentDefaultsSettingsView.swift`, `ResourceSettingsView.swift:188`, `HooksSettingsView.swift:262` scope pickers | Removed. Project editing moves to the Project card. |
| `UI/Settings/AgentConfigurationControls.swift:6,22,115` model, context window and thinking rows | Shared row controls, fed by registry capability and badges. |
| `UI/Settings/CompactionSettingsView.swift:102,244-257` | Context › Compaction, plus Model › Summary thinking. |
| `UI/Chat/NewSessionSheet.swift:94-96,339-343`, `NewSessionConfigurationOwner.swift` | Resolved defaults with badges for the chosen project, setting the Chat layer at creation. |
| The dashboard project list (`UI/Chat/SessionShellView.swift`, inferred owner) | Gains "Project settings", which opens the Project card. |

**Mac menu bar** (`packages/mac-app/Sources/MenuBar/MenuBarController.swift`):
it holds Gateway lifecycle and pairing only (Setup). It has no harness keys, and
none are planned for it.

## 9. Slices

The slices are ordered. The cheap iOS wins come first, then the registry and the
change path, and the Project card's dashboard route comes last. Size is S, M or
L. Each slice is a Proposed issue under epic #758. The maintainer moves a slice
to Ready.

| # | Slice | Size | Area | Depends on | Issue |
|---|---|---|---|---|---|
| 1 | One door per chat: the ordinary-chat gear opens Manage Session, and Settings is a row inside it | S | iOS | | #759 |
| 2 | Clear names and a shared source badge on today's rows (the three "Thinking" controls, the three "Project Trust" meanings) | S | iOS | | #760 |
| 3 | The settings registry and `settings.resolve` (layers, provenance, an untrusted project shown as not applied) | L | Gateway | | #761 |
| 4 | One change path: `settings.change`, the ledger, undo and history; today's setters migrate | L | Gateway, iOS | 3 | #762 |
| 5 | Risk gate: floors, untrusted-content escalation, approval by tap, and the `settings` tool for Home and agents | L | Gateway, iOS | 4 | #763 |
| 6 | External edits are detected and shown as "Changed outside Tron" | M | Gateway, iOS | 4 | #764 |
| 7 | Fixed-at-start values carry provenance, with "Use the current default"; live keys reach open chats | M | Gateway, iOS | 3, 4 | #765 |
| 8 | Manage Session and Manage Home show the five primitive sections from the registry (D1, D2, D5, D6, D7) | L | iOS | 2, 3, 4, 7 | #766 |
| 9 | The Home profile becomes a typed layer: worker model "same as Home", worker thinking, memory model, task budgets | M | Gateway, iOS | 4 | #767 |
| 10 | The Project card in Manage Session: the project layer, trust, and external changes | M | iOS | 6, 8 | #768 |
| 11 | Settings becomes the Mac layer by primitive, and the scope pickers are removed (D3, D4) | M | iOS | 8, 10 | #769 |
| 12 | The Project card opens from the dashboard project list | S | iOS | 10 | #770 |
| 13 | A risk model can raise a change's tier | M | Gateway | 5 | #771 |

How #743 and #734 fit:

- **#743** (Home next-prompt preview and delivered context) is the delivered
  stage of Home's Context section. It does not depend on this epic. When slice
  8 lands, its rows move into Context › Delivered without rework.
- **#734** (Home acts on your behalf) owns the learned notes and "About you".
  Slice 9 adds the typed profile values beside them and implements the new
  "workers use the same model as Home" default as a typed key. #734's
  note-based `delegation-default` stays as the explanation.

## 10. Open questions

These need the maintainer's decision. Each slice that depends on an answer says
so in its issue.

1. **Doc lifetime.** AGENTS.md says there are no plan documents. This doc is
   written as the target contract in the Gateway docs, and it sheds its
   Migration and Slices sections as the epic lands. Is that acceptable, or
   should the design live only in the epic body?
2. **Profile reach.** Does the Home profile layer apply only to Home's chat and
   the chats Home starts (proposed), or also to ordinary chats the maintainer
   starts?
3. **Profile above Project for workers.** With Chat > Profile > Project, Home's
   worker model overrides a repo's `.pi/` default model for Home's workers in
   that repo. Is that intended, or should a repo's own model win for work in
   that repo?
4. **Worker thinking.** Should worker thinking also default to "same as Home",
   or to the worker model's own default?
5. **Explicit delegate choice.** Does a model named in a `delegate` call (#732)
   still override "same as Home" (proposed: yes, as a turn-level input)?
6. **Untrusted-content escalation.** Raise by one tier (proposed), or go
   straight to "wait for tap"? Which sources count as untrusted: web, fetch, X,
   external Knowledge sources, MCP output, untrusted repo files?
7. **Floors.** May the maintainer raise a key's floor in a policy editor
   (never lower it), or are floors code-only?
8. **Pending approvals.** How long does a pending change wait before it expires,
   and does Home get told when one is declined or expires?
9. **Chat overrides for Run keys.** Which live operational keys may a chat
   override? Proposed: only queue delivery and compaction; retry and transport
   are Project or Mac only.
10. **Push policy placement.** It is stored on the Gateway, so this doc puts it
    under Setup, not This iPhone. Agree?
11. **Retry and transport.** Under Run with a provider qualifier (proposed), or
    under each provider in Accounts?
12. **Ledger.** Retention bound, and should Settings show a full Changes list or
    only per-key history?
13. **External project changes.** Notify on every `.pi/` change after a pull,
    or only on Permissions-affecting ones (proposed)?
14. **Project writes.** Tron writes the repo `.pi/` working tree only
    (proposed). Should it ever stage or commit?
15. **Image blocking timing.** `images.blockImages` is fixed at start by the
    "what the model sees" rule. Should a privacy-motivated block apply live
    instead (a Permissions-style tighten)?
16. **Landing.** Should the slices land straight to `main` one by one, or be
    held on an integration branch until the set is verified?
