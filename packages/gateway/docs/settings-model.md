# Settings model

**Status: design doc.** Nothing here is implemented yet unless a section says
"today". Epic #758 tracks the work; the slices in [Slices](#9-slices) are filed
under it as Proposed. This stays a design doc ([decision 1](#101-decisions)).
As each slice lands, the matching parts of [Migration](#8-migration-from-today)
and [Slices](#9-slices) are deleted, and those two sections go away when the
epic closes. The principles, primitives, layers and registry stay as the
reference.

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
10. [Decisions and open questions](#10-decisions-and-open-questions)

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

**Retry and transport stay in Run** ([decision 11](#101-decisions)). Moving them
under an Accounts provider entry was considered and rejected. Accounts supplies credentials and catalogs and
should not configure behaviour. Retry and transport are operational policy that
follows live. When a per-provider value is needed, `provider` becomes a
qualifier on the Run key (pi's `retry.provider.*` is already provider-level), and
the Accounts row for that provider links to it. Like every Run key, a single chat
may override them ([decision 9](#101-decisions), [3.4](#34-timing-fixed-at-start-or-follows-live)).

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
Setup rather than This iPhone ([decision 10](#101-decisions)).

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
| `images.autoResize` | Context | Chat, Project, Mac | Fixed |
| `images.blockImages` → `context.images.block` | Context | Chat, Project, Mac | Live-tighten ([decision 15](#101-decisions)) |
| `extensions`, `skills`, `prompts`, `packages` | Sources (contributions shown in Context, Tools and Run) | Project, Mac | Fixed (explicit Reload) |
| `defaultTools` → `tools.active` | Tools | Chat, Profile, Project, Mac | Fixed |
| `codemode.mode`, `codemode.inlineBudget` | Tools | Project, Mac | Fixed |
| `shellPath`, `shellCommandPrefix` | Tools | Project, Mac | Fixed (new chat) |
| MCP servers (`mcp.json`, global and project) | Tools (credentials in Accounts) | Project, Mac | Fixed (Reload) |
| Project trust (`<tronHome>/agent/trust.json`, per path) | Permissions | Mac, qualified by project | Live (tightening); see [3.5](#35-the-trust-exception) |
| `defaultProjectTrust` | Permissions | Mac only (pi enforces this) | Live |
| Connection write permission (`connections.policy.update`) | Permissions | Mac | Live |
| Home task scopes and grants (Home task store) | Permissions | Profile | Live |
| Floor overrides (new) → `permissions.floor[key]` | Permissions | Mac | Live ([5.4](#54-tiers-floors-and-escalation)) |
| `steeringMode`, `followUpMode` | Run | Chat, Project, Mac | Live |
| `retry.*`, `retry.provider.*` | Run | Chat, Project, Mac | Live |
| `transport`, `httpIdleTimeoutMs`, `websocketConnectTimeoutMs` | Run | Chat, Project, Mac | Live |
| `httpProxy` | Run | Mac only (pi enforces this) | Restart |
| pi `cacheWarming` (not exposed today) | Run | Mac only (pi enforces this) | Live |
| Home memory model (`home.json` `memory.model`) → `model.ref[role=memory]` | Model | Profile | Live (next memory pass) |
| Worker model and thinking (new) → `model.ref[role=worker]`, `model.thinking[role=worker]` | Model | Profile | Read when Home delegates ([6.3](#63-worker-model-same-as-home)) |
| `npmCommand` | Sources | Mac | Live |
| `sessionDir` | Setup | Mac | Restart |
| `enableInstallTelemetry` | Setup | Mac | Live |
| Push policy (`notifications.json`) | Setup | Mac | Live |
| Terminal-only pi keys (`theme`, `tuiMode`, ...) | Not shown | | |

The Profile layer applies only to the Home chat ([decision 2](#101-decisions)),
and the Home chat has no Project layer ([3.3](#33-who-gets-which-layers)). A
"Profile" entry in this table is therefore a value for Home's own chat, or a
Home-only key such as the worker role, never a value an ordinary chat reads.

Every chat-applicable Run key allows a Chat layer ([decision 9](#101-decisions)).
`httpProxy` and `cacheWarming` are the exception: pi reads them only from the
agent directory, and `httpProxy` takes effect only on restart, so neither has a
per-chat effect point today. Whether "any Run setting" was meant to include them is
[Q17](#102-open-questions).

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
| 4 | Sandboxing the shell | Permissions: `permissions.sandbox.mode`. | **Adjusted.** Permissions needs asymmetric timing: tightening applies live, and widening applies at the next chat start or after approval. The registry's `timing` field gained `live-tighten`. Decision 15 reuses it outside Permissions for `context.images.block`, so `live-tighten` is a timing any privacy-tightening key may declare. |
| 5 | A new memory type (project memory, vector recall) | Context: `context.memory.<kind>`, with its own sources, loaded and delivered chain. Its model is Model `role=memory`. If a package ships it, Sources shows the package. | Clean. |
| 6 | Per-tool approval ("ask before `bash`") | Permissions: `permissions.toolApproval[tool]`, qualified by tool name. Loosening waits for a tap. Tightening is quiet. | Clean once qualifiers exist. |
| 7 | Multi-model routing, or a subagent model | Model roles: `model.ref[role=subagent]`, and a router is a model ref (virtual models already exist). | **Adjusted.** Without roles this would need a new group. Roles were added to Model for this case. |
| 8 | Cost caps (per chat, per task, per day) | Permissions: `permissions.budget.*`. Raising waits for a tap. Lowering is quiet and applies live. | Clean, with direction-aware floors ([4.1](#41-fields)). |
| 9 | A new provider auth flow (device code, workload identity) | Accounts only. The catalog grows, and Model rows render from it. | Clean. No harness key changes. |
| 10 | An output-token limit or sampling control | Model: `model.maxOutputTokens`, `model.temperature`, shown only when the catalog declares them. | Clean. |
| 11 | An extension hook that blocks tool calls (a guard) | Hooks are code. Sources lists the extension. Run lists the hook under its event. | **Imperfect.** A hook's effect can belong to any primitive. Hooks stay listed in Run by event, with a badge for effects that matter elsewhere ("can block tools"). Hook behaviour is not a setting key, so this does not move any key. |
| 12 | A voice or realtime model | Model `role=voice`. Its transport options are Run qualified by provider. | Clean. |
| 13 | One chat needs more retries for a flaky provider | Run: `run.retry.maxRetries[provider]` at the Chat layer of that chat. Other chats keep following the default live. | Clean after decision 9. Chat-layer Run values are explicit overrides: they do not follow later default edits until the row's "Follow the default" unsets them. |
| 14 | A worker should run a cheaper model than Home for one task | The `delegate` call names the model: a turn-level input that beats "same as Home" and is recorded in the brief with its reason (decision 5). | Clean. No profile value reaches the worker except through the call. |

## 3. Layers, precedence and timing

### 3.1 Precedence

Top wins:

1. **Chat**: this chat's own values.
2. **Profile (Home)**: the Home profile's typed values. They apply **only to the
   Home chat** ([decision 2](#101-decisions)). No other chat reads this layer:
   not the chats the maintainer starts, and not the workers Home starts.
3. **Project**: the repo's `.pi/` directory, shared through git.
4. **Mac**: the Gateway-global layer.
5. **Built-in**: pi defaults plus Tron's built-in policy.

So a Home chat resolves Chat > Profile > Mac > Built-in (it has no Project
layer), and every other chat resolves Chat > Project > Mac > Built-in.

Per-message choices (steer or follow-up on a queued message, and the model and
thinking a `delegate` call carries) are **turn-level inputs**. They are not a
stored layer. A turn-level input either applies to that one message, or writes
a chat-layer value of a chat being created (a delegated worker).

**How workers get profile values.** A worker Home starts gets the worker model
and worker thinking because Home resolves them from its own profile and passes
them explicitly in the `delegate` call ([6.3](#63-worker-model-same-as-home)).
In the worker they are a turn-level input written into its Chat layer, so they
sit above the repo's `.pi/` default for that worker
([decision 3](#101-decisions)). The repo's default still applies to the chats
the maintainer starts in that repo.

Each key's `layers` field says which layers may set it. A value at a disallowed
layer is ignored and shown as a diagnostic. For example, pi already ignores
`defaultProjectTrust` and `httpProxy` in project settings.

### 3.2 Where each layer is stored

| Layer | Store | Owner |
|---|---|---|
| Chat | The session JSONL. pi's `model_change` and `thinking_level_change` entries, Tron's `tron.context-window.v1` custom entry (`packages/gateway/src/providers/context-window-policy.ts:7`), active tools, and a new `tron.settings.v1` entry for the other chat-layer keys and the provenance of fixed values. | The session's runtime slot lane. |
| Profile (Home) | A typed profile store beside `home.json`: `<tronHome>/gateway/home/profile.json`. Not Knowledge note text ([6](#6-the-home-profile-layer)). | `HomeOwner`. |
| Project | `<cwd>/.pi/settings.json`, `<cwd>/.pi/mcp.json` and the rest of the repo `.pi/`. | The repo (git). The Gateway is Tron's only writer, but not the file's only writer. Tron edits and stages; it never commits ([5.7](#57-project-writes-are-staged-never-committed)). |
| Mac | `<tronHome>/agent/settings.json`, `models.json`, `mcp.json`, `trust.json`, plus the Gateway stores (`connections`, `notifications.json`). | The Gateway. pi CLI runs and hand edits are external writers. |
| Built-in | Code: pi defaults and Tron's built-in policy table in the registry. | The release. |

Today's audit put the Mac layer at `~/.pi/agent/settings.json`. In the current
code the agent directory is `<tronHome>/agent` (`packages/gateway/src/config.ts:434`),
so the Mac layer is `<tronHome>/agent/settings.json`.

### 3.3 Who gets which layers

- An **ordinary chat in a project** resolves Chat > Project > Mac > Built-in. It
  never has a profile layer ([decision 2](#101-decisions)).
- **Home's own chat** has no Project layer. Home runs in a neutral workspace with
  no project discovery (`packages/gateway/src/sessions/runtime-slot.ts:1919-1924`).
  It resolves Chat > Profile (Home) > Mac > Built-in.
- A **Home task worker** is an ordinary chat in its target project, with no
  profile layer. Its model and thinking arrive as `delegate` arguments that Home
  filled from its profile ([6.3](#63-worker-model-same-as-home)) and are written
  into its Chat layer at start. Everything else resolves as in any chat, and its
  fixed values do not follow later profile edits.

### 3.4 Timing: fixed at start or follows live

Timing is a property of each key, chosen by what the key affects.

- **Fixed at start**: anything that changes what the model is or sees. That
  covers the model, thinking, context window, tools, instructions, skills,
  resources and image resizing. Image blocking is live-tighten instead (below). When a chat starts, the resolver computes these and
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
  next compaction). A single chat may override **any** chat-applicable Run key
  (retry, timeouts, transport, queue delivery) and compaction
  ([decision 9](#101-decisions)). The override is an explicit Chat-layer value
  that holds until the row's **"Follow the default"** unsets it. Its row shows
  the Chat badge and the default it overrides. Whether an agent setting its own
  chat's retry or timeouts needs a floor above `quiet` is
  [Q18](#102-open-questions).
- **Live-tighten**: narrowing applies live, while widening waits for the next
  start or an approval ([2.5](#25-stress-tests) case 4). Permissions keys use
  it, and so does `context.images.block` ([decision 15](#101-decisions)):
  turning the block on applies from the next request, and turning it off waits
  for the next chat start or an approval. pi already re-reads the setting on
  every request and replaces image content in all messages with a text
  placeholder (`pi-coding-agent` `dist/core/sdk.js`, `convertToLlmWithBlockImages`),
  so "on" needs no new pi hook. The maintainer's own tap in a row is the
  approval, so his "off" applies at once.

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
fixes it. pi's `SettingsManager.applyOverrides` is the inspected candidate for
per-chat Run overrides. For Home, Tron passes no `SettingsManager`
(`runtime-slot.ts:1924,1952`) and pi's session services create their own
(`pi-coding-agent` `dist/core/sdk.js:76`), so the override path must reach that
one too.

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
| `risk` | The code floor per direction: `{ widen, narrow }` or a single tier. Tiers are `quiet`, `notify` and `approve`. The maintainer may override it with `permissions.floor[key]` ([5.4](#54-tiers-floors-and-escalation)). |
| `writers` | Which actors may request a change: `ui`, `home`, `worker` or `agent`. `external` is observed, never admitted. |
| `sensitivity` | `redact`: show "set" or "changed", never the value (for example `httpProxy`). |
| `applier` | The owner that performs the write: the pi settings file, a session entry through the slot lane, the profile store, the trust store, the MCP config, or a connections policy. |

Provenance is not a field. It is part of every resolved value:
`{ value, layer, applied, reason?, fixedAt? }`.

### 4.2 Example entries (real keys)

| id | primitive | qualifiers | layers → storage | timing / effect | risk (widen / narrow) | writers |
|---|---|---|---|---|---|---|
| `model.ref` | model | `role` | chat → `model_change`; profile → `profile.json` (read by the Home chat only); project/mac → `defaultProvider`+`defaultModel` | fixed / next-turn | quiet / quiet | ui, home, agent |
| `model.ref[role=worker]` | model | `role` | profile → `profile.json`; built-in `{ sameAs: "home" }` | read when Home delegates | notify (from Home) / quiet (maintainer tap) | ui, home |
| `model.thinking` | model | `role`, `model` | chat → `thinking_level_change`; profile (Home chat, and `role=worker`, built-in `{ sameAs: "home" }`); project/mac → `defaultThinkingLevel`, `modelThinkingLevels`; summarizer → `compaction.thinkingLevel` | fixed (summarizer: live) / next-turn | quiet | ui, home, agent |
| `model.contextWindow` | model | `model` | chat → `tron.context-window.v1`; project/mac → `modelContextWindows` | fixed / next-turn | quiet | ui, home, agent |
| `model.ref[role=memory]` | model | `role` | profile → `profile.json` (today `home.json` `memory.model`) | live / next memory pass | notify (spends) | ui, home |
| `context.compaction.reserveTokens` | context | `model` | chat; project/mac → `compaction.reserveTokens`, pi `compaction.modelOverrides` | live / next compaction | quiet | ui, home, agent |
| `context.compaction.instructions` | context | | project/mac → `compaction.instructions` | live / next compaction | notify | ui, home |
| `context.images.block` | context | | chat; project/mac → `images.blockImages` | live-tighten / next-request | quiet (on) / approve (off, from a non-UI actor) | ui, home, agent |
| `tools.active` | tools | | chat → active tool set; profile; project/mac → `defaultTools` | fixed / next-turn | notify (adding) / quiet (removing) | ui, home, agent |
| `tools.codemode.mode` | tools | | project/mac → `codemode.mode` | fixed / new-chat | quiet | ui, home |
| `permissions.projectTrust` | permissions | `project` | mac → `trust.json` | live-tighten | approve / notify | ui (Home may request) |
| `permissions.defaultProjectTrust` | permissions | | mac → `defaultProjectTrust` | live | approve / notify | ui |
| `permissions.connectionWrite` | permissions | `connection` | mac → connections policy | live-tighten | approve / quiet | ui |
| `permissions.budget.task` | permissions | | profile | live-tighten | approve / quiet | ui, home |
| `permissions.floor` | permissions | `key` | mac → `<tronHome>/gateway/settings/floors.json` | live / next change | lower: approve (tap only) / raise: quiet | ui |
| `run.queue.steeringMode` | run | | chat; project/mac → `steeringMode` | live / next-turn | quiet | ui, home, agent |
| `run.retry.maxRetries` | run | `provider` | chat → `tron.settings.v1`; project/mac → `retry.maxRetries`, `retry.provider.maxRetries` | live / next-request | quiet | ui, home, agent |
| `run.transport` | run | `provider` | chat → `tron.settings.v1`; project/mac → `transport` | live / next-request | quiet | ui, home, agent |
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
4. Apply through the key's applier, under that store's own lock. A Project-layer
   applier also stages the file ([5.7](#57-project-writes-are-staged-never-committed)).
   A failed write or stage leaves the store unchanged and is recorded as
   `failed`.
5. Append to the ledger.
6. Broadcast `settings.changed { changeId, keys, layer, target }`.

A multi-key change applies atomically within one store. Across stores it applies
in a fixed order and rolls back the stores it already changed, the way
`TrustService.setAndApply` does today (`trust-service.ts:118-157`).

**The ledger** is `<tronHome>/gateway/settings/changes.jsonl`. It is append-only
and **kept forever** ([decision 12](#101-decisions)): no entry is ever pruned.
So that reads stay cheap as it grows, it is split into closed segments (for
example one file per month) with an index, and `settings.history` reads it in
pages. Its growth is reported in observability like other Gateway stores. Each
entry holds:

- `changeId`, the time, and the actor with its identity;
- the layer and target;
- the key, with `before` and `after` (redacted for sensitive keys; credentials
  never appear);
- the reason;
- the tier and why: the floor, untrusted-content escalation, or a risk-model
  raise;
- the status: `applied`, `pending`, `approved`, `declined`, `expired`, `failed`
  or `external`, with the failure reason when `failed`;
- for a Project-layer write, the git state: `staged`, `committed: false`, the
  repo root, the path and the staged blob id
  ([5.7](#57-project-writes-are-staged-never-committed));
- `undoOf` when the entry is an undo.

Later facts about an entry (approved, expired, committed by the maintainer,
unstaged, reverted) are appended as new entries that reference its `changeId`.
No entry is rewritten.

### 5.3 Undo

`settings.undo { changeId }` writes `before` back through the same path, as a
new change with `undoOf`. It is refused with a conflict if the current value is
no longer `after`, and the row shows what changed since. Undo is gated like any
other change. Undoing a narrowing widens, so undoing "remove trust" waits for a
tap. Undo is offered from each key's history and from the full Changes list in
Settings ([7.4](#74-settings)), for any entry however old, under the same
conflict check. A redacted key's ledger entry does not hold its old value, so
whether it can be undone is [Q19](#102-open-questions).

### 5.4 Tiers, floors and escalation

The three tiers:

- **quiet**: apply and record.
- **notify**: apply, record, and tell the maintainer, with an undo in the
  notification.
- **approve**: hold until the maintainer taps approve. A pending change expires
  after 24 hours ([5.5](#55-where-approvals-appear)).

How the tier is computed:

1. **The floor.** Each key's floor per direction is defined in code (the
   registry). The maintainer may raise **or lower** a key's floor in
   Settings › Permissions ([decision 7](#101-decisions)). The override is the
   Mac-layer key `permissions.floor[key]`. Only the UI writes it. Raising a
   floor applies quietly. Lowering one needs his tap and a confirmation, and
   like every change it is in the ledger. Without an override the code floor
   applies. Widening any Permissions key has an `approve` code floor.
2. **Always-tap changes.** Trusting a project, adding credentials and raising a
   budget always need the maintainer's tap, whatever the floor and the content
   ([decision 6](#101-decisions)). This design treats those three as pinned:
   `permissions.floor` cannot lower them. Whether decision 7's "any key" was
   meant to reach them is [Q20](#102-open-questions).
3. **Untrusted-content escalation.** If the requesting turn read untrusted
   content, the tier rises **one** step: `quiet` to `notify`, and `notify` to
   `approve` ([decision 6](#101-decisions)). It never jumps straight to
   `approve`. Untrusted content is:
   - `web_search` and `web_fetch` results;
   - other chats' snippets (`session_search`);
   - Knowledge records;
   - files read from untrusted projects, and an untrusted project's `.pi/`
     values read through `settings.resolve` ([3.6](#36-an-untrusted-projects-layer));
   - task reports that quote any of these.

   The Gateway sets the mark per turn from the tool calls it executed, never
   from the model's own account. A task report carries its worker's mark: if
   the worker read untrusted content, the report that reaches Home is
   untrusted. This list matches what Home's instructions already call untrusted
   (`tron-home-extension.ts:27`). Which tools in ordinary chats and workers
   (MCP output, browser, shell network calls, X) also count is
   [Q21](#102-open-questions).
4. **The risk model.** A decision model in front of the action can only raise
   the tier, never lower it. If it fails or times out, the computed tier stands.
5. **The actor.** A change the maintainer makes from a row applies at once, since
   the tap is the approval. Always-approve keys still show a confirmation in the
   UI. Home and agent changes use the computed tier.

The floor and any override are recorded in each ledger entry's tier reason, so
a lowered floor is visible on every change it let through.

### 5.5 Where approvals appear

Pending changes use the same pattern as Home task grants
(`home.decideTaskGrant`):

- a push notification with Approve and Decline;
- a "Waiting for you" row in Manage Home, and in Manage Session when a chat's own
  agent asked;
- a decision RPC bound to the exact pending diff.

A pending change **expires after 24 hours** ([decision 8](#101-decisions)). An
expired or declined change is never applied, and is recorded as `expired` or
`declined`. **Home is told** on the next maintainer message to Home: that turn's
context carries one line per change Home asked for that was declined or expired
since its last turn, the way task results that miss a wake arrive on the next
maintainer message today. Whether a worker or an ordinary chat's agent that
asked is told the same way is [Q22](#102-open-questions).

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
   it was Tron's own write. For a repo file, the watcher also reads the file's
   git state, so that a staged Tron edit the maintainer later commits, unstages
   or reverts is appended to that entry's history
   ([5.7](#57-project-writes-are-staged-never-committed)).
3. Otherwise record an `external` ledger entry with the file, the per-key diff,
   and the git `HEAD` and branch for repo files. Broadcast it.
4. Rows show **"Changed outside Tron"** with the diff. The Project card lists
   what the repo changed after a pull.
5. **Only permission-related changes notify** ([decision 13](#101-decisions)).
   For a repo's `.pi/` after a pull, that means a change to a Permissions key
   (which the Project layer ignores, but which still signals an attempt), to
   Tools (`defaultTools`, `.pi/mcp.json`, code mode, shell), to hooks, or to
   Sources (packages, extension, skill and prompt paths). Those send a push.
   Every other change is recorded and shown as "Changed outside Tron" with no
   push. The same rule applies to the Mac files. Trust itself still gates
   loading.
6. If an agent's tool call wrote that exact path just before, the entry names
   the session ("likely by chat X"). That attribution is a hint, not identity.

Fixed-at-start keys in open chats are unaffected, since they are chat values.
Live keys take the new value at their next effect point.

### 5.7 Project writes are staged, never committed

When Tron changes a repo's `.pi/` files, it edits them in the project's working
tree and **stages them with `git add`**. It never commits, never pushes and
never opens a pull request for them. The maintainer reviews and commits them
himself ([decision 14](#101-decisions)).

The Project applier, in order, under the project's store lock:

1. Find the git repository that contains `<cwd>/.pi/`. No repository is a
   failure.
2. Check the file: its working tree must match its index entry (no unstaged
   changes), and it must have no unresolved merge conflict. A dirty or
   conflicting file is a failure, because staging it would also stage someone
   else's edit.
3. Check `expected` against the working-tree value.
4. Write the file, then `git add` exactly that path. If `git add` fails (for
   example the index is locked, or the path is ignored), restore the previous
   file content.
5. Record the ledger entry with `staged: true, committed: false`, the repo
   root, the path and the staged blob id.

A failure at any step leaves the working tree and the index as they were. It is
recorded as a `failed` change with its reason (`no-repository`,
`dirty-file`, `conflicted-file`, `index-locked`, `ignored-path`,
`stale-expected`), and it appears in the Changes list and in the key's history.
A non-UI actor's request receives the same reason.

**The live value applies from the working tree.** pi reads the Project layer
from the working-tree file, so a staged edit takes effect under the key's usual
timing: a fixed key at the next chat start (or "Use the current default"), a
live key at its next effect point. Staging is not a pending state: the value is
applied, and only the commit is outstanding.

**What the UI shows.** The key's source badge reads **"Project · Staged, not
committed"** while that key's working-tree value differs from its value at
`HEAD` and the file still matches the blob Tron staged. The Project card lists every such key. The Changes
list shows the entry as staged and uncommitted.

**What the watcher records afterwards** ([5.6](#56-external-edits)), each as a
new entry that references the original `changeId`:

- the maintainer commits it: `committed` with the commit id, and the badge
  drops to "Project";
- the maintainer edits the file further or reverts it: an `external` change
  with the diff, and the live value follows the working tree;
- the maintainer unstages it but keeps the edit: the value still applies, and
  how that is recorded and shown is [Q24](#102-open-questions).

Tron never re-stages or re-applies a value someone else removed. Several cases
here need the maintainer's call: [Q24](#102-open-questions) to
[Q27](#102-open-questions).

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

The profile layer applies **only to the Home chat** ([decision 2](#101-decisions)).
It is not resolved for any other chat: not the chats the maintainer starts, and
not the workers Home starts. Workers get profile-derived values only because
Home resolves them and passes them explicitly in its `delegate` call
([6.3](#63-worker-model-same-as-home)). A key's `layers` field decides whether a
profile may set it. Home-only keys (`model.ref[role=worker]`,
`model.thinking[role=worker]`, `model.ref[role=memory]` and
`permissions.budget.task`) have the profile as their highest default layer.

### 6.3 Worker model: "same as Home"

The delegation default: workers start with the same model **and thinking
level** as the active Home session ([decision 4](#101-decisions)). Both are
profile keys, and both are built in as "same as Home":

```
model.ref[role=worker]       built-in and default profile value: { "sameAs": "home" }
model.thinking[role=worker]  built-in and default profile value: { "sameAs": "home" }
```

**Home resolves; the worker receives.** The profile is resolved in Home, at the
moment Home delegates, not in the worker. The `delegate` handler (Home's side of
the Gateway, before task admission) fills each of `model` and `thinking` that
the call left out:

1. **The `delegate` call's own `model` or `thinking`** wins, field by field
   ([decision 5](#101-decisions)). An explicit choice for this task beats "same
   as Home". The call must then give a short reason, and the brief records the
   choice and the reason ("Worker model: X, chosen by Home: lookup only").
2. **Otherwise the profile value.** `sameAs: home` reads the Home chat's
   effective model or thinking at that moment: its chat layer, which is the
   current Home session's value. An explicit model ref in the profile is used
   as is. The brief records it as "Worker model: X, same as Home (Home
   profile)".

The filled call then goes through the existing admission rules (registered,
physical, has credentials, supported thinking level;
`home-task-worker-choice.ts`) and, at worker start
(`packages/gateway/src/home/home-task-dispatcher.ts:190-193`), is written into
the worker's Chat layer with provenance, for example
`{ from: "delegate", via: "home-profile:sameAs:home", value: anthropic/<model>, at }`.
Because it is a Chat-layer value, it beats the repo's `.pi/` default model for
this worker ([decision 3](#101-decisions)). Manage Session for the worker shows
**"From Home at start: same as Home (<model>)"** or **"From Home at start:
chosen for this task (<model>)"**.

If the profile-derived model cannot be used (for example its credentials were
removed), Home's handler leaves the field unset, the worker resolves its own
Chat > Project > Mac > Built-in default, and the task record and the row say
why. If an explicit model does not support Home's thinking level, the outcome
is [Q23](#102-open-questions).

Today the `delegate` tool tells Home to "omit both for the Gateway default"
(`tron-home-extension.ts:29,77`), and an omitted model keeps the worker
session's default (`home-task-dispatcher.ts:190-191`). Slice 9 replaces that
guidance and behaviour atomically.

Changing Home's model later does not change running workers: the worker model
is fixed at start. Changing the profile key from `sameAs: home` to an explicit
model is a profile-layer change through the change path. Its floor is `notify`
for Home and `quiet` for the maintainer's tap.

## 7. Surfaces

Every surface shows the same five primitive sections in the same order: Model,
Context, Tools, Permissions, Run. Each row shows:

- the effective value;
- a **source badge**: Chat, Profile: Home (Home chat only), Project, Mac or
  Built-in, plus "not applied (untrusted)", "Staged, not committed" or
  "Changed outside Tron" when they apply;
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
  Every Run row (retry, timeouts, transport, queue delivery) and the compaction
  rows can be overridden for this chat alone, with "Follow the default" to
  clear the override ([decision 9](#101-decisions)).
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
- Writes edit the working tree and stage the file; Tron never commits or
  pushes ([5.7](#57-project-writes-are-staged-never-committed)). Each staged key
  carries "Staged, not committed" until the maintainer commits it, and a
  failed stage shows as a failed change with its reason.
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
- A **Changes** row opens the full ledger, kept forever
  ([decision 12](#101-decisions)): newest first, paged, filterable by actor,
  layer, key and status, including `failed`, `external` and staged project
  edits. Each applied entry offers Undo under the conflict check
  ([5.3](#53-undo)).
- Permissions holds the **floor overrides** (`permissions.floor`): each key's
  code floor, any override, and raise or lower actions. Lowering needs a
  confirmation tap ([5.4](#54-tiers-floors-and-escalation)).

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
| `home/home-task-dispatcher.ts:190-193`, `home-task-worker-choice.ts`, `tron-home-extension.ts:29,77` ("omit both for the Gateway default") | Home's `delegate` handler fills omitted `model` and `thinking` from the profile (`sameAs: home` by default) before admission; an explicit choice wins and carries its reason into the brief ([6.3](#63-worker-model-same-as-home)). |
| `admin/settings-service.ts` project writes: working tree only | The Project applier also stages the file and records the git state; it never commits ([5.7](#57-project-writes-are-staged-never-committed)). |
| No per-chat Run values; `images.blockImages` read per request by pi but only from settings files | Chat-layer values for every chat-applicable Run key and for `context.images.block` in `tron.settings.v1`, applied to the chat's own settings ([3.4](#34-timing-fixed-at-start-or-follows-live)). |
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
to Ready. Slices land on `main` one at a time, in their blocked-by order, with
no integration branch ([decision 16](#101-decisions)).

| # | Slice | Size | Area | Depends on | Issue |
|---|---|---|---|---|---|
| 1 | One door per chat: the ordinary-chat gear opens Manage Session, and Settings is a row inside it | S | iOS | | #759 |
| 2 | Clear names and a shared source badge on today's rows (the three "Thinking" controls, the three "Project Trust" meanings) | S | iOS | | #760 |
| 3 | The settings registry and `settings.resolve` (layers, provenance, an untrusted project shown as not applied) | L | Gateway | | #761 |
| 4 | One change path: `settings.change`, the ledger (kept forever), undo and history; today's setters migrate; Project writes are staged, never committed | L | Gateway, iOS | 3 | #762 |
| 5 | Risk gate: code floors with maintainer overrides, one-tier untrusted-content escalation, approval by tap with 24-hour expiry, and the `settings` tool for Home and agents | L | Gateway, iOS | 4 | #763 |
| 6 | External edits are detected and shown as "Changed outside Tron" (push only for permission-related changes); staged project edits are tracked to commit, unstage or revert | M | Gateway, iOS | 4 | #764 |
| 7 | Fixed-at-start values carry provenance, with "Use the current default"; live keys reach open chats; a chat may override any Run key; image blocking is live-tighten | M | Gateway, iOS | 3, 4 | #765 |
| 8 | Manage Session and Manage Home show the five primitive sections from the registry (D1, D2, D5, D6, D7) | L | iOS | 2, 3, 4, 7 | #766 |
| 9 | The Home profile becomes a typed layer for the Home chat: worker model and thinking "same as Home" filled into `delegate` by Home, memory model, task budgets | M | Gateway, iOS | 4 | #767 |
| 10 | The Project card in Manage Session: the project layer with "Staged, not committed", trust, and external changes | M | iOS | 6, 8 | #768 |
| 11 | Settings becomes the Mac layer by primitive, and the scope pickers are removed (D3, D4); the full Changes list with undo | M | iOS | 8, 10 | #769 |
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

## 10. Decisions and open questions

### 10.1 Decisions

The maintainer's answers to the sixteen questions this design first asked,
numbered as they were asked. Each was decided by Mohsin on 2026-10-10. The
sections above already reflect them.

| # | Topic | Decision |
|---|---|---|
| 1 | Doc lifetime | It stays a design doc. Migration and Slices are removed as slices land. The principles, registry and layers stay as reference. |
| 2 | Home profile reach | Home only. The profile layer applies only to the Home chat. Workers Home starts get profile-derived values (worker model, worker thinking) because Home resolves them and passes them explicitly in the `delegate` call, not because the profile applies to worker chats. Chats the maintainer starts never see the profile ([3.1](#31-precedence), [6.2](#62-who-it-applies-to)). |
| 3 | Profile versus a repo's default for workers | Home's worker model beats a repo's `.pi/` default model for workers Home starts in that repo. The repo default still applies to chats the maintainer starts ([6.3](#63-worker-model-same-as-home)). |
| 4 | Worker thinking | Defaults to "same as Home" ([6.3](#63-worker-model-same-as-home)). |
| 5 | Explicit `delegate` choice | An explicit model or thinking level in a `delegate` call beats "same as Home". The brief records the choice and the reason ([6.3](#63-worker-model-same-as-home)). |
| 6 | Untrusted-content escalation | Raises a change one tier, not straight to approval. Untrusted sources: `web_search` and `web_fetch` results, other chats' snippets, Knowledge records, files from untrusted projects, and task reports that quote these. Trust, credential and budget raises still always need a tap ([5.4](#54-tiers-floors-and-escalation)). |
| 7 | Floors | Floors are defined in code, and the maintainer may raise or lower a key's floor in Settings. Lowering needs his tap and is itself a logged change. The risk model can still only raise ([5.4](#54-tiers-floors-and-escalation)). |
| 8 | Pending approvals | Expire after 24 hours. Home is told on decline or expiry on the next maintainer message ([5.5](#55-where-approvals-appear)). |
| 9 | Chat overrides for Run keys | A single chat may override any Run setting (retry, timeouts, transport, queue delivery) and compaction ([3.4](#34-timing-fixed-at-start-or-follows-live)). |
| 10 | Push policy placement | Under Setup ([2.2](#22-supply-and-non-harness-sections)). |
| 11 | Retry and transport | Under Run, with a per-provider override ([2.1](#21-harness-primitives)). |
| 12 | Ledger | Kept forever, with a full Changes list in Settings that supports undo ([5.2](#52-the-request-and-the-record), [7.4](#74-settings)). |
| 13 | External project changes | After a pull, notify only on permission-related `.pi/` changes (Permissions, Tools, hooks, Sources). Other changes show as "Changed outside Tron" with no push ([5.6](#56-external-edits)). |
| 14 | Project writes | Tron edits a repo's `.pi/` files and stages them with `git add`. It never commits, pushes or opens a pull request for them; the maintainer reviews and commits. The live value applies from the working tree under the usual timing, the Changes record notes the edit as staged and uncommitted, the source badge says "Staged, not committed", and a failure to stage is a failed change ([5.7](#57-project-writes-are-staged-never-committed)). This replaces an earlier answer that routed project writes through a pull request. |
| 15 | Image blocking timing | "Block images" is live and tighten-only: turning it on applies at once, turning it off waits for the next chat start or an approval, like Permissions ([3.4](#34-timing-fixed-at-start-or-follows-live)). |
| 16 | Landing | Slices land on `main` one at a time, in their blocked-by order ([9](#9-slices)). |

### 10.2 Open questions

These follow from the decisions and need the maintainer's call. They are
numbered after the first sixteen. Each slice they affect names them in its
issue.

17. **Process-wide Run keys (from decision 9).** pi reads `httpProxy` and
    `cacheWarming` only from the agent directory, and `httpProxy` takes effect
    only on restart. This design keeps both Mac only. Was "any Run setting"
    meant to include them? A per-chat value would need a change in pi or a
    per-chat transport.
18. **Agent-set Run overrides (from decision 9).** A chat's own agent can raise
    its chat's retry count and timeouts, which spends more and can hold a run
    open longer. Should those overrides from a non-UI actor have a `notify`
    floor instead of `quiet`?
19. **Undo of redacted keys (from decision 12).** A redacted key (for example
    `httpProxy`) records only "changed", so the ledger cannot write the old
    value back. Should those entries be shown as not undoable, or should the
    old value be kept in a private store outside the ledger?
20. **Always-tap changes versus lowering floors (decisions 6 and 7).** This
    design pins trusting a project, adding credentials and raising budgets at
    `approve`, so `permissions.floor` cannot lower them. Is that what "any key"
    meant, or may the maintainer lower those too?
21. **Untrusted sources outside Home (from decision 6).** The list matches
    Home's research tools. Ordinary chats and workers also read MCP tool output,
    browser pages, shell network calls and X posts. Do those mark a turn
    untrusted too?
22. **Who else is told on decline or expiry (from decision 8).** Home is told
    on the next maintainer message. Should a worker or an ordinary chat's agent
    that asked be told on its next user message the same way, or only through
    the Changes list?
23. **Explicit model with "same as Home" thinking (from decisions 4 and 5).** If
    a `delegate` call names a model but no thinking level, and that model does
    not support Home's level, should the handler use the model's nearest
    supported level, the model's own default, or refuse the call? Today a
    thinking level without a model is refused, and an unsupported level is
    refused.
24. **The maintainer unstages but keeps the edit (from decision 14).** The value
    still applies from the working tree. Should the badge change to
    "Not staged" with no push, or should the change be treated as an
    `external` edit?
25. **The edit is reverted or dropped (from decision 14).** A `git checkout --`,
    `git restore --staged --worktree`, stash, reset or branch switch can remove
    the staged edit. The design records it as `external`, the live value
    follows the working tree, and Tron never re-applies it. Should that send a
    push even when the key is not permission-related, and should Undo of the
    original entry then be refused as a conflict or offered as "Apply again"?
    A branch switch that carries the staged edit along keeps it staged; should
    the Changes list note the new branch?
26. **Other staged work in the index (from decision 14).** If the maintainer
    already has his own staged edit to the same `.pi/` file, staging on top
    merges Tron's edit into his. Other staged files in the same repo may be
    committed together with Tron's edit. Should Tron refuse to stage when the
    file, or the index, already holds staged changes it did not make?
27. **Which checkout, and ignored `.pi/` (from decision 14).** A project path
    can be a linked worktree or a subdirectory of a repository, and other
    checkouts of the same repository do not see a staged edit. A repo may also
    ignore `.pi/` in `.gitignore`, so `git add` refuses it. Should an ignored
    path be a failed change (this design), be force-added, or be written
    without staging?
