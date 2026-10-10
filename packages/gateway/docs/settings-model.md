# Settings model

**Status: design doc.** Nothing here is implemented yet unless a section says
"today". Epic #758 tracks the work; the slices in [Slices](#9-slices) are filed
under it as Proposed. This stays a design doc ([decision 1](#101-decisions)).
As each slice lands, the matching parts of [Migration](#8-migration-from-today)
and [Slices](#9-slices) are deleted, and those two sections go away when the
epic closes. The foundations, primitives, layers, schema and rendering contract
stay as the reference.

This document covers every setting that configures the model or the agent
harness: how each one is declared, stored, resolved, changed and shown in Tron.
It is built on four [foundations](#1-foundations). Every later section follows
from them. An edge case is answered by applying a foundation, not by adding a
rule; a rule in this doc that cannot be traced to a foundation is a defect in
the doc.

## Contents

1. [Foundations](#1-foundations)
2. [Primitives: the groups](#2-primitives-the-groups) and [stress tests](#25-stress-tests)
3. [Layers and resolution](#3-layers-and-resolution)
4. [The schema](#4-the-schema)
5. [Changes, the record and policy](#5-changes-the-record-and-policy)
6. [The Home profile layer](#6-the-home-profile-layer)
7. [Presentation and the rendering contract](#7-presentation-and-the-rendering-contract)
8. [Migration from today](#8-migration-from-today)
9. [Slices](#9-slices)
10. [Decisions and open questions](#10-decisions-and-open-questions)

## 1. Foundations

Decided by Mohsin on 2026-10-10 ([10.1](#101-decisions)).

### F1. Schema

Each setting is **one key, declared once on the Gateway**. The declaration
holds everything about the key: its type and validation, its group, which
layers may set it, whether it is fixed at chat start or live, its tier floor,
whether it is redacted, and its display metadata ([4](#4-the-schema)). The
Gateway validates and resolves every key. iOS renders every key generically
from the schema with a small, fixed set of controls
([7.5](#75-the-rendering-contract)). Hand-built screens exist only where a
generic row really cannot work ([7.6](#76-hand-built-screens)).

The goal: a new model, feature or key needs **no iOS release**.

So "Mac only", "never stored in the repo" and "a chat may override it" are not
rules. They are a key's allowed layers. A model's thinking levels or context
limits are not iOS code. They are option sources the Gateway serves.

### F2. Truth

**Each layer's store is the truth**: the Mac files, the chat's session record,
the Home profile file, and the repo's `.pi/` files on disk. The change log is
audit and undo, never a second truth.

When a store differs from the value last logged for it, for any reason (a hand
edit, a pull, a git revert, stash, reset or branch switch, a pi CLI run), the
difference is an **outside change**. It is recorded and shown, and the row
offers **Apply again**, which writes the logged value back through the change
path. Tron never re-applies a value on its own. There are no per-git-case
rules ([5.6](#56-outside-changes)).

### F3. Policy

Every change goes through one Gateway path and gets one of three tiers:
**quiet** (apply and log), **notify** (apply, log, and tell the maintainer with an
undo), or **approve** (wait for his tap). The tier is

```
tier = max(floor + web, riskModel)        capped at approve
```

- `floor` is the key's floor for the change's direction (widen or narrow),
  from the schema, or the maintainer's override of it.
- `web` is one step when the requesting turn read web or browser content, and
  zero otherwise.
- `riskModel` is what an optional decision model returns. It can only raise.

There are **no per-key exceptions**. "Trusting a project, adding credentials
and raising a budget need a tap" is those keys' default floor (`approve`),
nothing more. The maintainer can raise or lower any floor; lowering one needs his tap
and is logged. His own tap from a row is the approval
([5.4](#54-tiers)).

### F4. Layers

Layers are uniform, and the top one wins:

**Chat > Home profile > Project (`.pi/`) > Mac > Built-in**

One resolver gives a key's value for a target: it takes the topmost layer that
the target has, that holds a value for the key, that the key's schema allows to
set it, and that is applied. Which layers a target has follows from which
stores it has ([3.3](#33-which-layers-a-target-has)). A layer can be present
but not applied, with a reason; today the only reason is an untrusted project
([3.5](#35-trust-and-an-untrusted-projects-layer)).

### 1.5 What follows

These used to be separate principles. They are consequences of F1 to F4:

- **The effective value is computed, never stored** (F4). The only copies are
  values fixed at chat start, and those are explicit Chat-layer values that
  record where they came from ([3.4](#34-timing)).
- **An edit goes to one layer** (F4). Changing a chat's model changes that
  chat's Chat layer only. Defaults change only in their own layer's editor.
  There is no sticky "last used" default.
- **Groups are harness primitives** (F1 `group`). Scope, source, authority,
  timing and state are badges computed by the resolver, never groups
  ([7.3](#73-badges)).
- **One path for every actor** (F3). The iPhone, Home, task workers and agents
  all use `settings.change`. Files Tron does not exclusively own can still be
  edited from outside, and F2 says what happens then.

## 2. Primitives: the groups

The schema's `group` field (F1). A model call is roughly
`f(model, context, tools)`, made under **permissions** and driven by a **run**
loop. Those are the five harness primitives. Four non-harness sections supply
things to them or sit outside them. Groups are schema data, so adding one is a
schema change that iOS renders without a release
([7.8](#78-stress-tests-for-rendering)); the five primitives are chosen so that
this should rarely be needed.

### 2.1 Harness primitives

| Primitive | Question it answers | Holds |
|---|---|---|
| **Model** | Which model runs, and how is each request made? | Model per role, thinking level, thinking budgets, context window, output limits, sampling, cache retention, offered models (`enabledModels`), and any future per-request model parameter. |
| **Context** | What does the model see, and how is that managed? | Instructions and system prompt, skills, prompt templates, memory, resources, attachments and image input, **compaction** and branch summaries. Resources follow one chain: sources, then loaded, then delivered. |
| **Tools** | What can the model do? | Active tools, built-in tools, MCP servers as tool providers, tools contributed by extensions, code mode, the shell tool's configuration, subagents and delegation. |
| **Permissions** | What is it allowed to do? | Project trust and the default trust policy, approvals and grants, Home task scopes, sandboxing, spend budgets, write permission on connections, per-tool approval, and the floor overrides. |
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
  project: `modelContextWindows`, pi's `modelThinkingLevels` and
  `compaction.modelOverrides` by model, trust by project path. A qualifier picks
  which instance of the key a value applies to. It is resolved within a layer
  and never adds one.

**Context window lives in Model.** The window is constrained by the catalog's
limits for that model, and for some providers it is a request option. Context
management (compaction thresholds, reserve and keep-recent tokens) stays in
Context and reads the window as an input.

**Retry and transport stay in Run** ([decision 11](#101-decisions)). Accounts
supplies credentials and catalogs and does not configure behaviour. When a
per-provider value is needed, `provider` is a qualifier on the Run key (pi's
`retry.provider.*` already is), and the Accounts row for that provider links to
it.

### 2.2 Supply and non-harness sections

| Section | Holds | Relation to the primitives |
|---|---|---|
| **Accounts** | Provider credentials and sign-in, the custom model catalog (`models.json`), connected services, MCP credentials. | Setup and status. Model and Tools draw on it; the model option source is built from the catalog Accounts supplies. |
| **Sources** | Packages, extension, skill and prompt search paths, and `npmCommand`. | A package is a delivery format, not a primitive. Sources shows where each thing came from. Each contribution is shown in its primitive: tools in Tools, skills and prompts in Context, hooks in Run. |
| **Setup** | Pairing, Gateway lifecycle and updates, the Mac wizard, `sessionDir`, install telemetry, push notification policy, logs, import and export. | No effect on what the model is, sees or does. |
| **This iPhone** | Appearance, density, dashboard and subagent activity display, the Changes "last looked" marker. Stored on the device. | Never changes harness behaviour, and the section says so. |

The push notification policy is stored on the Gateway
(`<tronHome>/gateway/notifications.json`), so it belongs to Setup, not This
iPhone ([decision 10](#101-decisions)).

### 2.3 Today's keys by primitive

Keys exposed by `SettingsService` today (`packages/gateway/src/admin/settings-service.ts:121-195`),
plus the Tron stores outside `settings.json`. The allowed layers and timing are
schema data (F1); no row here is an exception to a rule.

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
| `images.blockImages` → `context.images.block` | Context | Chat, Project, Mac | Narrow live, widen fixed ([decision 15](#101-decisions)) |
| `extensions`, `skills`, `prompts`, `packages` | Sources (contributions shown in Context, Tools and Run) | Project, Mac | Fixed (explicit Reload) |
| `defaultTools` → `tools.active` | Tools | Chat, Profile, Project, Mac | Fixed |
| `codemode.mode`, `codemode.inlineBudget` | Tools | Project, Mac | Fixed |
| `shellPath`, `shellCommandPrefix` | Tools | Project, Mac | Fixed (new chat) |
| MCP servers (`mcp.json`, global and project) | Tools (credentials in Accounts) | Project, Mac | Fixed (Reload) |
| Project trust (`<tronHome>/agent/trust.json`, per path) | Permissions | Mac, qualified by project | Narrow live, widen live after approval |
| `defaultProjectTrust` | Permissions | Mac (pi reads it only there) | Live |
| Connection write permission (`connections.policy.update`) | Permissions | Mac | Live |
| Home task scopes and grants (Home task store) | Permissions | Profile | Live |
| Floor overrides (new) → `permissions.floor[key]` | Permissions | Mac | Live ([5.4](#54-tiers)) |
| `steeringMode`, `followUpMode` | Run | Chat, Project, Mac | Live |
| `retry.*`, `retry.provider.*` | Run | Chat, Project, Mac | Live |
| `transport`, `httpIdleTimeoutMs`, `websocketConnectTimeoutMs` | Run | Chat, Project, Mac | Live |
| `httpProxy` | Run | Mac (pi reads it only there) | Restart |
| pi `cacheWarming` (not exposed today) | Run | Mac (pi reads it only there) | Live |
| Home memory model (`home.json` `memory.model`) → `model.ref[role=memory]` | Model | Profile | Live (next memory pass) |
| Worker model and thinking (new) → `model.ref[role=worker]`, `model.thinking[role=worker]` | Model | Profile | Read when Home delegates ([6.3](#63-worker-model-same-as-home)) |
| `npmCommand` | Sources | Mac | Live |
| `sessionDir` | Setup | Mac | Restart |
| `enableInstallTelemetry` | Setup | Mac | Live |
| Push policy (`notifications.json`) | Setup | Mac | Live |
| Terminal-only pi keys (`theme`, `tuiMode`, ...) | Not declared | | |

Two consequences worth naming:

- A chat may override every Run key whose allowed layers include Chat
  ([decision 9](#101-decisions)). `httpProxy` and `cacheWarming` do not include
  Chat, because pi reads them only from the agent directory, so a chat cannot
  override them ([Q17](#101-decisions)). That is their schema entry, not an
  exception to decision 9.
- A "Profile" entry is a value for Home's own chat, or a Home-only key such as
  the worker role. No ordinary chat has a Profile layer
  ([3.3](#33-which-layers-a-target-has)).

### 2.4 Features decompose into primitives

A feature is not a primitive. It is a set of keys, and each key lands in its own
primitive. Delegation is an example: the worker model is Model (`role=worker`),
the ability to delegate is Tools, the grants and budgets are Permissions, and
the delegated brief is Context. The worker's own chat then resolves like any
other chat. The primitives stay fixed while features come and go.

### 2.5 Stress tests

Each case shows where a plausible future change lands. Where it did not fit
cleanly, the model was adjusted, and the adjustment is recorded. The rendering
side of these cases is in [7.8](#78-stress-tests-for-rendering).

| # | Future case | Lands in | Fit |
|---|---|---|---|
| 1 | A new reasoning or verbosity parameter (for example a `verbosity` enum) | Model: `model.verbosity[role,model]`, with an option source that offers only the values the catalog declares for the model. Fixed at start. | Clean. |
| 2 | Prompt caching controls | Cache retention or TTL is a request parameter, so Model: `model.cacheRetention`. Keep-alive warming between runs is loop behaviour, so Run: `run.cacheWarming` (Mac only). | Splits by the assignment rule. Recorded as the rule's worked example. |
| 3 | A computer-use tool | Enabling the tool is Tools (`tools.active`). Which apps it may drive, and foreground input, are Permissions (widen floor: approve). The macOS Screen Recording status is Setup. | Clean. The feature spans three primitives by design. |
| 4 | Sandboxing the shell | Permissions: `permissions.sandbox.mode`. | **Adjusted.** Tightening must apply live, while widening waits for the next start or an approval. Timing became a per-direction schema field, like the floor ([3.4](#34-timing)). Decision 15 reuses it for `context.images.block`. |
| 5 | A new memory type (project memory, vector recall) | Context: `context.memory.<kind>`, with its own sources, loaded and delivered chain. Its model is Model `role=memory`. If a package ships it, Sources shows the package. | Clean. |
| 6 | Per-tool approval ("ask before `bash`") | Permissions: `permissions.toolApproval[tool]`, qualified by tool name. Widen floor approve, narrow floor quiet. | Clean once qualifiers exist. |
| 7 | Multi-model routing, or a subagent model | Model roles: `model.ref[role=subagent]`; a router is a model ref (virtual models already exist). | **Adjusted.** Without roles this would need a new group. Roles were added to Model for this case. |
| 8 | Cost caps (per chat, per task, per day) | Permissions: `permissions.budget.*`. Raise floor approve; lower floor quiet, live. | Clean, with per-direction floors. |
| 9 | A new provider auth flow (device code, workload identity) | Accounts only. The catalog grows, and Model's option source grows with it. | Clean. No harness key changes. |
| 10 | An output-token limit or sampling control | Model: `model.maxOutputTokens`, `model.temperature`, offered only when the catalog declares them. | Clean. |
| 11 | An extension hook that blocks tool calls (a guard) | Hooks are code. Sources lists the extension. Run lists the hook under its event. | **Imperfect.** A hook's effect can belong to any primitive. Hooks stay listed in Run by event, with a badge for effects that matter elsewhere ("can block tools"). Hook behaviour is not a setting key, so no key moves. |
| 12 | A voice or realtime model | Model `role=voice`. Its transport options are Run, qualified by provider. | Clean. |
| 13 | One chat needs more retries for a flaky provider | Run: `run.retry.maxRetries[provider]` at that chat's Chat layer. Other chats keep following the default live. | Clean: Run keys allow Chat (decision 9). The agent raising its own chat's retries is quiet by floor ([Q18](#101-decisions)). |
| 14 | A worker should run a cheaper model than Home for one task | The `delegate` call names the model: a turn-level input that beats "same as Home" and is recorded in the brief with its reason (decision 5). | Clean. |

## 3. Layers and resolution

### 3.1 Precedence and the resolver

F4, top wins:

1. **Chat**: this chat's own values.
2. **Profile (Home)**: the Home profile's typed values.
3. **Project**: the repo's `.pi/` directory, shared through git.
4. **Mac**: the Gateway-global layer.
5. **Built-in**: pi defaults plus Tron's built-in values in the schema.

`settings.resolve` returns, for a target (a chat, the Home profile, a project
path or the Mac) and each key: `{ value, display, layer, applied, reason?,
fixedAt?, badges, layers[] }`, where `layers[]` lists every layer's value so a
row can show what it overrides. A value at a layer the key does not allow is
ignored and returned as a diagnostic.

Per-message choices (steer or follow-up on a queued message, and the model and
thinking a `delegate` call carries) are **turn-level inputs**, not a layer. A
turn-level input either applies to that one message, or writes the Chat layer
of a chat being created (a delegated worker, [6.3](#63-worker-model-same-as-home)).

### 3.2 Stores

F2: each store is its layer's truth.

| Layer | Store | Owner |
|---|---|---|
| Chat | The session JSONL: pi's `model_change` and `thinking_level_change` entries, Tron's `tron.context-window.v1` entry (`packages/gateway/src/providers/context-window-policy.ts:7`), the active tools, and a new `tron.settings.v1` entry for the other Chat-layer keys and the provenance of fixed values. | The session's runtime slot lane. |
| Profile (Home) | `<tronHome>/gateway/home/profile.json`, typed. Not Knowledge note text ([6](#6-the-home-profile-layer)). | `HomeOwner`. |
| Project | `.pi/settings.json`, `.pi/mcp.json` and the rest of `.pi/`, on disk at the chat's worktree root ([Q27](#101-decisions)). | The repo (git). Tron writes the working tree and stages; it never commits ([5.7](#57-project-writes)). |
| Mac | `<tronHome>/agent/settings.json`, `models.json`, `mcp.json`, `trust.json`, plus the Gateway stores (`connections`, `notifications.json`, `settings/floors.json`). | The Gateway. pi CLI runs and hand edits are outside writers. |
| Built-in | Code: pi defaults and the schema's `builtin` values. | The release. |

The Mac layer is `<tronHome>/agent/settings.json`: the agent directory is
`<tronHome>/agent` (`packages/gateway/src/config.ts:434`), not `~/.pi/agent`.

**The Project store's location.** pi reads `<cwd>/.pi/settings.json` with no
upward search (`pi-coding-agent` `dist/core/settings-manager.js:100`). The
Project store for a chat is `.pi/` at that chat's worktree root: a linked
worktree uses its own `.pi/`, never the main checkout's, and a chat started in
a subdirectory uses its worktree's root. Slice 4 verifies that the cwd Tron
gives pi is that root.

### 3.3 Which layers a target has

A target has a layer when it has that layer's store. Nothing else decides it.

- An **ordinary chat in a project** has Chat, Project, Mac and Built-in. It has
  no profile, because profiles are Home-only ([decision 2](#101-decisions)). This
  includes the chats the maintainer starts and the workers Home starts.
- **Home's own chat** has Chat, Profile, Mac and Built-in. It has no project:
  Home runs in a neutral workspace with no project discovery
  (`packages/gateway/src/sessions/runtime-slot.ts:1919-1924`).
- A **Home task worker** is an ordinary chat in its target project. Its model
  and thinking arrive as `delegate` arguments that Home filled from its own
  profile, written into the worker's Chat layer at start
  ([6.3](#63-worker-model-same-as-home)). Being Chat-layer values, they sit above
  the repo's `.pi/` default for that worker ([decision 3](#101-decisions)),
  while the repo default still applies to chats the maintainer starts there.

### 3.4 Timing

Timing is a schema field (F1), and like the floor it may differ by direction.

- **Fixed at start**: anything that changes what the model is or sees: model,
  thinking, context window, tools, instructions, skills, resources and image
  resizing. When a chat starts, the resolver writes these into its Chat layer
  with provenance `{ value, from: "mac" | "project" | "profile" | "builtin" |
  "delegate", at, ref }`. They are then explicit Chat-layer values. The row says
  **"From default at start: X"** and offers **"Use the current default"**, which
  re-resolves the key and writes the result through the change path. For
  resources that action is Reload, as today.
- **Live**: operational policy: retry, transport, timeouts, compaction
  thresholds, queue delivery. Nothing is copied. The chat reads the resolved
  value at the key's effect point. A Chat-layer value for a live key is an
  explicit override; it holds until the row's **"Follow the default"** unsets
  it.
- **Per direction**: a key may be live in the narrowing direction and fixed in
  the widening one. Sandboxing, per-tool approval and `context.images.block`
  ([decision 15](#101-decisions)) declare that: turning image blocking on
  applies from the next request, and turning it off waits for the next chat
  start. A widening that was approved (or tapped by the maintainer) applies at once. pi
  already re-reads `images.blockImages` on every request and replaces image
  content with a placeholder (`pi-coding-agent` `dist/core/sdk.js`,
  `convertToLlmWithBlockImages`), so "on" needs no new pi hook.

The **effect point** is a separate field: `next-turn`, `next-request`,
`new-chat`, `reload` or `restart`. The row shows it when a change does not take
effect at once ("Applies after restart").

**Today.** Fixed-at-start already holds for the model, thinking and context
window through session entries, and for resources through Reload, but no
provenance is recorded. Only compaction policy follows live: `settings.update`
refreshes it for open chats (`packages/gateway/src/transport/gateway-service.ts:1974-1976`).
Each runtime builds its own `SettingsManager` when it starts
(`runtime-slot.ts:1924`), so, as far as the code reads, retry, transport and
queue modes reach an open chat only when its runtime is rebuilt. That is
inferred; slice 7 verifies and fixes it. pi's `SettingsManager.applyOverrides`
is the inspected candidate for Chat-layer Run values. For Home, Tron passes no
`SettingsManager` (`runtime-slot.ts:1924,1952`) and pi's session services
create their own (`pi-coding-agent` `dist/core/sdk.js:76`), so the override
path must reach that one too.

**No sticky defaults (verified).** pi 1.0.4's `AgentSession.setModel(model, options)`
and `setThinkingLevel(level, options)` write `defaultModel` and
`defaultThinkingLevel` only when `options.persist` is true. Tron calls both
without options (`runtime-slot.ts:9284`, `runtime-slot.ts:9323`). pi's own
terminal model selector can persist a default; if someone runs the pi CLI
against the same agent directory, that is an outside change (F2). A Home chat's
model change is written to `home.json` so a later chapter restores it
(`runtime-slot.ts:9285-9289`); that is Home's Chat layer carried across
chapters, not a default.

### 3.5 Trust and an untrusted project's layer

Trust is schema data, not an exception. `permissions.projectTrust` is a Mac-layer
key qualified by project path, stored in `<tronHome>/agent/trust.json` through
pi's `ProjectTrustStore` (`packages/gateway/src/admin/trust-service.ts:30`). Its
allowed layers exclude Project, so a repo can never grant itself trust. Its widen
floor is `approve` by default (F3). The default policy (`defaultProjectTrust`:
ask, always or never) is a Mac-layer key.

An untrusted project's `.pi/` layer is **present but not applied** (F4):

- The Gateway reads `.pi/settings.json` as JSON data, which executes nothing;
  executable resources stay gated by trust as today. `settings.resolve` returns
  the Project value with `applied: false, reason: "untrusted"`, and the
  effective value comes from the next layer down.
- Rows show the repo's value struck through, with a **"Project · not applied
  (untrusted)"** badge and **Review trust**. Today `settings.get` returns
  `project: null` when untrusted (`settings-service.ts:138`), which hides what
  trusting would change.
- Tron never writes the Project layer of an untrusted project, as today's
  `trust_required` refusal does (`settings-service.ts:202-204`).

### 3.6 Capability-constrained values

Some keys take only the values a capability allows, such as the thinking levels
the selected model supports. The schema names the option source
([4.1](#41-fields)). When a value meets a model that does not support it (the
chat's model changes, or a `delegate` call names a model that lacks Home's
thinking level), the resolver uses the **closest supported value** and says so
with a "Clamped" badge; a `delegate` brief records it
([Q23](#101-decisions)). pi already clamps a thinking level to the model's
supported levels (`clampThinkingLevel` in `AgentSession.setThinkingLevel`), so
this names existing behaviour rather than adding a rule.

## 4. The schema

F1: one typed schema in the Gateway declares every key. It drives resolution
(`settings.resolve`), validation and application (`settings.change`), the tier
(F3), and the iOS rows ([7](#7-presentation-and-the-rendering-contract)). The
Gateway serves it to clients; iOS holds no per-key code.

### 4.1 Fields

**Behaviour**

| Field | Meaning |
|---|---|
| `id` | A stable dotted id, independent of storage: `model.thinking`. |
| `group` | The section: `model`, `context`, `tools`, `permissions` or `run`, or a supply section: `accounts`, `sources`, `setup` or `iphone`. Sections are themselves declared, with a title and order, so a new one needs no client change. |
| `subgroup` | An optional heading within the section (for example `Compaction`). |
| `qualifiers` | Any of `role`, `model`, `provider`, `tool`, `project`, `connection`, `key`. |
| `type` | The value type and its static validation (range, pattern, length, item type). |
| `options` | A static list of allowed values, or an `optionsSource`: a named Gateway source such as `catalog.models`, `catalog.thinkingLevels(model)` or `catalog.contextWindow(model)`, with the keys it depends on. |
| `layers` | The allowed layers, each with its storage binding (file and path, or session entry type). |
| `builtin` | The built-in value, or `pi-default`. |
| `timing` | `fixed` or `live`, or per direction `{ narrow, widen }` ([3.4](#34-timing)). |
| `effect` | `next-turn`, `next-request`, `new-chat`, `reload` or `restart`. |
| `floor` | The code floor, one tier or per direction `{ widen, narrow }`. Tiers are `quiet`, `notify`, `approve`. The maintainer may override it ([5.4](#54-tiers)). |
| `direction` | How to tell widen from narrow for this type (for example a larger budget widens, a removed tool narrows). Keys without a direction use one floor. |
| `writers` | Which actors may request a change: `ui`, `home`, `worker`, `agent`. `outside` is observed, never admitted. |
| `redacted` | Show "set" or "changed", never the value. The record holds no old value, so the change is not undoable ([Q19](#101-decisions)). |
| `applier` | The owner that performs the write: the pi settings file, a session entry through the slot lane, the profile store, the trust store, the MCP config, or the connections policy. |

**Display** ([7.5](#75-the-rendering-contract))

| Field | Meaning |
|---|---|
| `label`, `help` | The row title and a one-paragraph explanation, written for the maintainer. |
| `order` | Position within its section and subgroup. |
| `importance` | `essential` (in the section summary) or `advanced` (on demand). |
| `control` | One of the fixed control primitives, with an optional `fallback` control for older clients. |
| `unit`, `format` | How the Gateway formats `display` ("200K tokens", "3 retries"). |
| `confirm` | Optional confirmation text when the maintainer's own tap changes a key whose tier would be `approve` for anyone else. |

Provenance is not a field. It is part of every resolved value
([3.1](#31-precedence-and-the-resolver)).

### 4.2 Example entries (real keys)

| id | group | qualifiers | layers → storage | timing / effect | floor (widen / narrow) | writers |
|---|---|---|---|---|---|---|
| `model.ref` | model | `role` | chat → `model_change`; profile → `profile.json` (Home chat); project/mac → `defaultProvider`+`defaultModel` | fixed / next-turn | quiet | ui, home, agent |
| `model.ref[role=worker]` | model | `role` | profile → `profile.json`; built-in `{ sameAs: "home" }` | read when Home delegates | notify | ui, home |
| `model.thinking` | model | `role`, `model` | chat → `thinking_level_change`; profile (Home chat, and `role=worker` built-in `{ sameAs: "home" }`); project/mac → `defaultThinkingLevel`, `modelThinkingLevels`; summarizer → `compaction.thinkingLevel` | fixed (summarizer: live) / next-turn | quiet | ui, home, agent |
| `model.contextWindow` | model | `model` | chat → `tron.context-window.v1`; project/mac → `modelContextWindows` | fixed / next-turn | quiet | ui, home, agent |
| `model.ref[role=memory]` | model | `role` | profile → `profile.json` (today `home.json` `memory.model`) | live / next memory pass | notify | ui, home |
| `context.compaction.reserveTokens` | context | `model` | chat; project/mac → `compaction.reserveTokens`, `compaction.modelOverrides` | live / next compaction | quiet | ui, home, agent |
| `context.compaction.instructions` | context | | project/mac → `compaction.instructions` | live / next compaction | notify | ui, home |
| `context.images.block` | context | | chat; project/mac → `images.blockImages` | narrow live, widen fixed / next-request | approve / quiet | ui, home, agent |
| `tools.active` | tools | | chat → active tool set; profile; project/mac → `defaultTools` | fixed / next-turn | notify / quiet | ui, home, agent |
| `tools.codemode.mode` | tools | | project/mac → `codemode.mode` | fixed / new-chat | notify / quiet | ui, home |
| `permissions.projectTrust` | permissions | `project` | mac → `trust.json` | narrow live, widen live once approved | approve / notify | ui, home |
| `permissions.defaultProjectTrust` | permissions | | mac → `defaultProjectTrust` | live | approve / notify | ui |
| `permissions.connectionWrite` | permissions | `connection` | mac → connections policy | narrow live | approve / quiet | ui |
| `permissions.budget.task` | permissions | | profile | narrow live | approve / quiet | ui, home |
| `permissions.floor` | permissions | `key` | mac → `<tronHome>/gateway/settings/floors.json` | live / next change | lower: approve / raise: quiet | ui |
| `run.queue.steeringMode` | run | | chat; project/mac → `steeringMode` | live / next-turn | quiet | ui, home, agent |
| `run.retry.maxRetries` | run | `provider` | chat → `tron.settings.v1`; project/mac → `retry.maxRetries`, `retry.provider.maxRetries` | live / next-request | quiet | ui, home, agent |
| `run.transport` | run | `provider` | chat → `tron.settings.v1`; project/mac → `transport` | live / next-request | quiet | ui, home, agent |
| `run.httpProxy` | run | | mac → `httpProxy` | live / restart | notify; redacted | ui |

`permissions.floor` is an ordinary key with ordinary floors: lowering a floor
widens what agents may do, so its widen floor is `approve`, and only `ui`
writes it. The maintainer's own tap is that approval (F3). Nothing about it is
special-cased.

### 4.3 How far today's code is from this

- `SettingsService` (`packages/gateway/src/admin/settings-service.ts`) has
  hand-written validators per key (`applyPatch`, `:267-356`), a computed
  effective value through pi's `SettingsManager` merge (`get`, `:121-195`), and
  two layers (global and project) with trust gating (`:202-204`). That is the
  validation half of a schema. It has no metadata, no chat or profile layer, no
  provenance, no record and no undo. The validators move into schema entries;
  they are not duplicated.
- pi exposes a TypeScript `Settings` interface but no runtime schema. Its docs
  state allowed layers for a few keys (`defaultProjectTrust`, `httpProxy` and
  `cacheWarming` are agent-directory only). The schema encodes those once and a
  test checks them against the pinned pi version, so a pi upgrade that adds or
  moves a key fails loudly.
- Chat-layer setters are separate RPCs: `session.setModel`, `setThinking`,
  `setContextWindow` and `setTools` (`runtime-slot.ts:9271-9344`). They keep
  their slot-lane appliers and become appliers behind `settings.change`.
- Trust (`trust.set`), MCP (`mcp.*`), connections policy, Home memory
  (`home.configureMemory`) and Home task grants each have their own RPC. Those
  that hold harness keys become schema appliers. Accounts flows (`auth.*`,
  `connections.setup.*`, `models.custom.*`) stay guided flows
  ([7.6](#76-hand-built-screens)). They record into the same change log, and
  credential values are never recorded.

## 5. Changes, the record and policy

### 5.1 One path for every actor

| Actor | How it asks | Identity recorded |
|---|---|---|
| The maintainer on iPhone | `settings.change` from a row | Paired device id. The tap is the approval. |
| Home | The `settings` tool | Home session and chapter, plus the triggering message id. |
| A task worker | The `settings` tool, if its grant includes it | The worker session and the task id. |
| An agent in an ordinary chat | The `settings` tool | The session id and the tool call id. |
| Outside Tron (hand edit, git, pi CLI) | Not admitted. Found by comparing the store with the record ([5.6](#56-outside-changes)). | `outside`, plus the file, and git `HEAD` and branch for repo files. |

The `settings` tool is a Tron module tool, a thin client of `settings.resolve`
and `settings.change`. Agent instructions tell agents to use it instead of
editing settings files. Direct edits are still found (F2).

### 5.2 The request and the record

`settings.change` takes a `commandId` and a list of changes:
`{ key, qualifiers, layer, target, op: set | unset, value, expected }`, plus a
`reason`, required for every non-UI actor. `expected` is the value or revision
the actor read, so a stale change is refused instead of overwriting. With
`dryRun: true` it validates and returns the tier without applying, so a row can
say "Needs approval" before anyone commits to it.

The steps:

1. Validate against the schema: type, options, allowed layer and writer.
2. Compute the tier (F3, [5.4](#54-tiers)).
3. If the tier is `approve` and the actor is not the maintainer's tap, record a pending
   change, notify him, and return `pending`.
4. Apply through the key's applier, under that store's own lock. A failed write
   leaves the store unchanged and is recorded as `failed` with its reason.
5. Append to the record.
6. Broadcast `settings.changed { changeId, keys, layer, target }`.

A multi-key change applies atomically within one store. Across stores it applies
in a fixed order and rolls back the stores it already changed, as
`TrustService.setAndApply` does today (`trust-service.ts:118-157`).

**The record** is `<tronHome>/gateway/settings/changes.jsonl`: append-only and
**kept forever** ([decision 12](#101-decisions)). It is split into closed
segments (for example one per month) with an index, and `settings.history`
reads it in pages. Its growth is reported in observability like other Gateway
stores. Each entry holds:

- `changeId`, the time, and the actor with its identity;
- the layer, target, key and qualifiers;
- `before` and `after`, or only "changed" for a redacted key (credentials never
  appear);
- the reason;
- the tier and how it was reached: the floor (code or override), the web step,
  the risk model's raise;
- the status: `applied`, `pending`, `approved`, `declined`, `expired`, `failed`
  or `outside`, with the failure reason when `failed`;
- for a Project write, the git result ([5.7](#57-project-writes));
- `undoOf` or `applyAgainOf` when the entry is one of those.

Later facts about an entry (approved, expired, committed, unstaged, overwritten
outside) are appended as new entries that reference its `changeId`. No entry is
rewritten. The record is never consulted to compute a value (F2).

### 5.3 Undo and Apply again

Both are ordinary changes through the same path, gated like any other.

- **Undo** (`settings.undo { changeId }`) writes `before` back, with `undoOf`.
  It is refused with a conflict when the store's current value is no longer
  `after`, and the row shows what changed since. Undoing a narrowing widens, so
  undoing "remove trust" has trust's widen floor. Undo is offered for any entry
  however old, from the key's history and from Changes
  ([7.4](#74-the-changes-feed)). A redacted entry has no `before`, so it shows
  **Not undoable** ([Q19](#101-decisions)).
- **Apply again** writes a logged value back after an outside change replaced
  or removed it ([5.6](#56-outside-changes)), with `applyAgainOf`. It is only
  ever offered, never automatic (F2).

### 5.4 Tiers

F3 in full.

- **quiet**: apply and record.
- **notify**: apply, record, and push to the maintainer with an Undo.
- **approve**: hold until the maintainer taps Approve. A pending change expires after 24
  hours ([5.5](#55-approvals)).

The inputs:

1. **The floor.** Each key's floor per direction is in the schema. The maintainer may
   raise or lower any key's floor in Settings › Permissions
   ([decision 7](#101-decisions), [Q20](#101-decisions)), through the key
   `permissions.floor[key]`. Lowering is a widening of that key, so it needs his
   tap and is recorded. The default floors make widening a Permissions key, and
   adding credentials, `approve`; those are defaults like any other.
2. **The web step.** If the requesting turn read web or browser content, the
   tier rises one step: `quiet` to `notify`, `notify` to `approve`
   ([decision 6](#101-decisions), [Q21](#101-decisions)). It applies the same way
   in Home, ordinary chats and workers. The Gateway sets the mark per turn from
   the tool calls it executed, never from the model's own account. Whether a
   tool returns web or browser content is that tool's own declaration (web
   search and fetch, the browser, public-post readers), so a new web tool
   declares it and nothing here changes. The mark belongs to the tool call
   only: it does not travel with content another turn reads later, such as a
   worker's report or a Knowledge record ([decision 28](#101-decisions)).
3. **The risk model.** A decision model may raise the tier, never lower it. If
   it fails or times out, the computed tier stands.
4. **The maintainer's tap.** A change he makes from a row is approved by that tap. When
   its tier would be `approve` for anyone else, the row shows the key's
   `confirm` text first.

Each record entry names its floor and any override, so a lowered floor is
visible on every change it let through.

### 5.5 Approvals

Pending changes use the pattern of Home task grants (`home.decideTaskGrant`):

- a push with Approve and Decline;
- a **Pending approval** badge on the row, the pending item at the top of
  Changes, and a "Waiting for you" entry in the section summary
  ([7.2](#72-sections-and-their-summaries));
- a decision RPC bound to the exact pending diff (no approve-then-swap).

A pending change **expires after 24 hours** ([decision 8](#101-decisions)). An
expired or declined change is never applied. **Whoever asked is told** on its
next turn: Home, an ordinary chat's agent, or a worker. That turn's context
carries one line per change it asked for that was declined or expired since
its last turn ([Q22](#101-decisions)), the way task results that miss a wake
reach Home today.

### 5.6 Outside changes

F2. The Gateway compares each store it resolves from with the record:

- the Mac `settings.json`, `models.json`, `mcp.json` and `trust.json`;
- each known project's `.pi/settings.json` and `.pi/mcp.json`, for every
  project with an open chat or a dashboard entry.

Today nothing does this; the only signal is the post-write `settings.changed`
broadcast (`gateway-service.ts:1977`). File events are lossy (editors
rename-replace, events drop), so the comparison rescans by content digest and
treats events only as a prompt to rescan.

When a store's value for a key differs from the value last logged for it:

1. Record an `outside` entry with the file, the per-key diff, and git `HEAD`
   and branch for repo files. Broadcast it.
2. The row shows **"Changed outside Tron"** with the diff. If the outside value
   replaced or removed a value Tron wrote, the row and the Changes entry offer
   **Apply again**.
3. The live value follows the store at the key's effect point. Fixed values in
   open chats are Chat-layer copies and are unaffected.
4. If an agent's tool call wrote that exact path just before, the entry names
   the session ("likely by chat X"). That is a hint, not identity.

**How loudly it is shown follows F3.** An outside change cannot be gated, since
it is already in the store. Its tier is computed like any change from an actor
with no turn (the key's floor for its direction, and the risk model's raise if
any) and decides only the notification: `quiet` is recorded and shown, `notify`
and `approve` also push. With the default floors, that gives decision 13: after
a pull, changes to Permissions keys (which the Project layer ignores, but which
signal an attempt), Tools (`defaultTools`, `.pi/mcp.json`, code mode, shell),
hooks and Sources push; a model or compaction-threshold change does not. A few
other keys with a `notify` floor (compaction instructions, `httpProxy`) also
push, because their floor says so, not because of a list. Changing what pushes
is changing a floor.

Git operations need no rules of their own. A revert, stash, reset or branch
switch that drops a value Tron wrote is an outside change with Apply again
([Q25](#101-decisions)). A branch switch that carries the edit along changes no
value, so nothing is recorded beyond the badge the git state now gives
([5.7](#57-project-writes)).

### 5.7 Project writes

[Decision 14](#101-decisions): Tron edits a repo's `.pi/` files and stages them.
It never commits, pushes or opens a pull request; the maintainer reviews and commits.
F2 settles everything else: the file on disk is the Project layer, and git
state is a property of that store, shown as a badge.

The Project applier, under the project's store lock:

1. Locate the store: `.pi/` at the chat's worktree root ([3.2](#32-stores)).
2. Check `expected` against the value on disk. A file that cannot be parsed,
   for example one with unresolved merge markers, is a `failed` change: the
   store cannot be validated.
3. Write the key into the file, keeping every other key and the file's layout.
4. Stage the path with `git add` when git can take it. When it cannot (no
   repository, a gitignored `.pi/`, a locked index), the write stands and is
   not staged ([Q27](#101-decisions)); the entry records why.
5. If the staged path, or the index, also holds changes Tron did not write,
   stage anyway and warn in the Changes entry. That includes the
   maintainer's own unstaged edits in the same file
   ([Q26](#101-decisions), [decision 29](#101-decisions)).
6. Record the entry: the repo root, the path, staged or not and why, and the
   staged blob id.

The value applies from the working tree under the key's usual timing, whether
or not it is staged. Staging is not a pending state.

**Badges come from the store's git state**, computed by the resolver:

| Store state | Badge |
|---|---|
| Value matches `HEAD` | Project |
| Differs from `HEAD`, staged | Project · Staged |
| Differs from `HEAD`, not staged (unstaged by the maintainer, or never staged) | Project · Uncommitted ([Q24](#101-decisions)) |
| No repository, or `.pi/` ignored | Project · Local only |
| Value differs from the last logged value | Changed outside Tron, with Apply again where it removed Tron's value |

Committing appends `committed` with the commit id to the original entry, and
the badge drops to Project. Unstaging keeps the value, so it is not an outside
change; the badge becomes Uncommitted.

## 6. The Home profile layer

### 6.1 What it is

Profiles are Home-only for now, designed as layers so they could become
general later: a chat would then have a profile store and gain the layer, with
no change to the resolver (F4). The Home profile has two parts.

- **Typed values.** Schema keys whose allowed layers include `profile`: the
  worker model and thinking, the memory model, task budgets and scopes. They
  resolve like any layer value, show a **"Profile: Home"** badge, and go through
  the change path.
- **Instructions and learned notes.** The Knowledge-backed learned profile owned
  by #734 (`packages/gateway/src/home/home-profile.ts`). Notes may explain *why*
  a value is set. They never carry the value. A `delegation-default` note that
  names a model is advice to Home; it is not resolved, and the typed key wins.

The typed values live in `<tronHome>/gateway/home/profile.json`, owned by
`HomeOwner` and written only by the change path. The memory model moves there
from `home.json` `memory.model` (`packages/gateway/src/home/home-owner.ts:77`),
and `home.configureMemory` (`:978`) becomes a schema applier. The Home chat's
own model in `home.json` (`home-owner.ts:72`) stays: it is Home's Chat layer,
carried across chapters.

### 6.2 Who it applies to

Only the Home chat has a profile store, so only the Home chat has the layer
([3.3](#33-which-layers-a-target-has), [decision 2](#101-decisions)). Workers get
profile-derived values only because Home resolves them and passes them in its
`delegate` call ([6.3](#63-worker-model-same-as-home)). Home-only keys
(`model.ref[role=worker]`, `model.thinking[role=worker]`,
`model.ref[role=memory]`, `permissions.budget.task`) have Profile as their
highest allowed layer.

### 6.3 Worker model: "same as Home"

Workers start with the same model **and thinking level** as the active Home
session ([decision 4](#101-decisions)). Both are profile keys, built in as:

```
model.ref[role=worker]       { "sameAs": "home" }
model.thinking[role=worker]  { "sameAs": "home" }
```

**Home resolves; the worker receives.** At the moment Home delegates, the
`delegate` handler (Home's side of the Gateway, before task admission) fills
each of `model` and `thinking` the call left out:

1. **The call's own `model` or `thinking`** wins, field by field
   ([decision 5](#101-decisions)). The call gives a short reason, and the brief
   records the choice and the reason ("Worker model: X, chosen by Home: lookup
   only").
2. **Otherwise the profile value.** `sameAs: home` reads the Home chat's
   effective model or thinking at that moment. An explicit model ref in the
   profile is used as is. The brief records "Worker model: X, same as Home".
3. **Capability.** If the resulting model does not support the resulting
   thinking level, the closest supported level is used and the brief notes it
   ([3.6](#36-capability-constrained-values), [Q23](#101-decisions)).

The filled call goes through the existing admission rules (registered,
physical, has credentials; `home-task-worker-choice.ts`) and, at worker start
(`packages/gateway/src/home/home-task-dispatcher.ts:190-193`), is written into
the worker's Chat layer with provenance, for example
`{ from: "delegate", via: "home-profile:sameAs:home", value: anthropic/<model>, at }`.
Manage Session for the worker shows **"From Home at start: same as Home
(<model>)"** or **"From Home at start: chosen for this task (<model>)"**.

If the profile-derived model cannot be used (for example its credentials were
removed), the handler leaves the field unset, the worker resolves its own
Chat > Project > Mac > Built-in default, and the task record and the row say
why.

Today the `delegate` tool tells Home to "omit both for the Gateway default"
(`tron-home-extension.ts:29,77`), and an omitted model keeps the worker
session's default (`home-task-dispatcher.ts:190-191`). Slice 9 replaces both
atomically.

Changing Home's model later does not change running workers: the worker's
values are fixed at start. Changing the profile key from `sameAs: home` to an
explicit model is a profile change with a `notify` floor.

## 7. Presentation and the rendering contract

### 7.1 Posture: calm by default, everything on demand

The maintainer is a power user who must be **able** to see and change every setting,
but ideally rarely needs to. Agents manage settings for projects and sessions;
he checks the few things that carry signal. So every surface opens calm, with
a short summary per section, and the full key list is one step away. Nothing is
hidden: a value that is not in a summary is in the section's full list, in All
settings, and in search.

Everything a surface shows (which keys are in a summary, which badges a row
carries, what a value reads as) comes from the schema and resolver output. iOS
decides layout and style, never meaning.

### 7.2 Sections and their summaries

Every settings surface shows the same sections in the same order: **Model,
Context, Tools, Permissions, Run**, then **Accounts, Sources, Setup, This
iPhone** where the surface has them. Collapsed, each section shows a summary
that `settings.resolve` computes for the target:

- **Effective values that matter**: the section's `essential` keys, as `display`
  strings (for example "Opus 5.5 · High thinking · 200K").
- **What is overridden, and by which layer**: every key whose effective value is
  set above Built-in by an explicit value, with its layer badge ("Retries 6 ·
  Chat"). Values fixed at start from a default are not overrides and stay out of
  the summary.
- **Pending approvals** in this section, with Approve and Decline.
- **Recent agent changes** in this section, newest first and capped (for
  example three, then "+N more" into Changes), each with its actor, reason and
  Undo.

A section with nothing overridden, pending or recent shows only its essential
values. Expanding a section shows all its keys: essential first, then
**Advanced**. **All settings** shows every key of the surface's target, grouped
by section, and **search** matches label, id, help and current value.

### 7.3 Badges

One badge component. The resolver returns each row's badges as
`{ kind, label, detail?, action? }`; iOS maps `kind` to a style, and an unknown
kind renders as a neutral badge with its label.

| Kind | Labels |
|---|---|
| Layer | Chat, Profile: Home, Project, Mac, Built-in |
| Source | From default at start, From Home at start, Follows default |
| Scope | The qualifier: a provider, model, tool or project |
| Authority | Who last changed it: You, Home, a named chat or worker, Outside Tron |
| State | Staged, Uncommitted, Local only, Changed outside Tron, Pending approval, Not undoable, Not applied (untrusted), Clamped, Applies after restart |

Scope, source, authority, timing and state are badges, never groups (F1). A
badge's `action` is a change the resolver offers (Apply again, Use the current
default, Follow the default, Review trust), sent back through
`settings.change`.

### 7.4 The Changes feed

Changes is the main place to check up on agents. It reads the record
([5.2](#52-the-request-and-the-record)) through `settings.history`.

- **Each entry**: who (actor and its chat or task, linked), what (key label and
  the before and after `display` strings), why (the reason), when, where (layer
  and target), the tier and how it was reached, the status and state badges.
- **Actions**: Undo, Apply again, Approve and Decline, each through the change
  path. Opening an entry shows the key's full history.
- **Order**: pending approvals pinned on top, then newest first. A "since you
  last looked" marker is kept on the device (This iPhone).
- **Filters**: actor (default: agents and outside changes, with "Everything"
  one tap away), layer, key, section and status (including `failed`, `outside`,
  staged and uncommitted project edits). The record is kept forever and paged.
- **Scopes**: the same component appears in Settings (everything), Manage
  Session (this chat and its project), and Manage Home (Home and the workers it
  started).

### 7.5 The rendering contract

**Control primitives.** iOS implements a small, fixed, versioned set. Every key
names one:

| Control | Renders | Examples |
|---|---|---|
| `toggle` | A switch | `compaction.enabled`, `images.block` |
| `choice` | A picker; an ordered choice may render as a stepped slider | thinking level, steering mode, transport |
| `number` | A field or slider with unit, range and step | retries, timeouts, context window |
| `text` | A single- or multi-line field | compaction instructions, shell prefix |
| `secret` | Write-only entry that shows "Set" or "Not set" | `httpProxy` |
| `list` | An ordered list of a primitive, with add, remove and reorder | search paths, `enabledModels` |
| `catalog` | A searchable picker over a Gateway-served catalog | model, tools, providers, projects |
| `readOnly` | The `display` string | anything a client cannot edit |

**Schema fields for presentation** are in [4.1](#41-fields): section, subgroup,
order, importance, label, help, unit and format, control and fallback, confirm.
Every resolved value carries its Gateway-formatted `display`, so any client can
show any key without understanding its type.

**Dynamic options are served.** A key with an `optionsSource` gets its options
from `settings.options { key, target, qualifiers }`: each option has a value,
label, detail and an optional disabled reason. The schema names the keys a
source depends on, and iOS re-requests when one of them changes (for example
the thinking levels after a model change). Catalogs are paged and searchable on
the Gateway.

**Validation is on the Gateway.** iOS only shapes input to the control (a
number field accepts numbers). `settings.change` with `dryRun` validates as the
user edits and returns per-key errors and the tier, shown inline. There is no
client-side copy of a key's rules.

**Negotiation.** The client sends the control primitives it implements, and the
renderer contract version it speaks, with `settings.resolve`, beside the
existing hello `capabilities`. For each key the Gateway picks the declared
control if the client has it, else the declared `fallback`, else `readOnly`. A
key shown read-only for that reason carries an "Update Tron to edit" note.
Unknown fields, badge kinds and section ids are ignored or shown neutrally. The
rule: **never crash, never hide a value**. Every key always arrives with its
`display`, so the worst case for an old client is a read-only row.

### 7.6 Hand-built screens

Hand-built only where a generic row cannot work: guided flows, inventories with
actions, and content viewers. Each hosts generic rows for any key it shows and
never re-implements a key's control.

| Screen | Why it stays hand-built |
|---|---|
| Accounts sign-in and provider setup (OAuth, device code, API key entry, custom models) | A multi-step flow with an external browser and credential entry, not a value. Its result is a record entry. |
| Setup: pairing, Gateway lifecycle and updates, logs, import and export | Actions on the system, not values. |
| Sources: package install and removal, and the resource chain (source, loaded, delivered) | An inventory of things with actions and stages. Sources' plain keys (search paths, `npmCommand`) are generic rows. |
| MCP server add and edit | A structured record with credentials from Accounts. Its enable state in Tools is a generic row. |
| Home: memory browser, chapters, tasks, and the delivered-context viewer (#743) | Content viewers. |
| The Changes feed and approval cards | A fixed structure over any key; generic in what they show. |
| The Project card header (project, trust, git state) and the New Session sheet | Composites. Their sections are the generic renderer. |

Today's `AgentConfigurationControls`, `ThinkingSlider`, `ContextWindowSlider`
and `CompactionSettingsView` are not on this list: they become the `catalog`,
`choice` and `number` primitives and generic rows.

### 7.7 Surfaces

The same sections and the same renderer appear in Manage Session, Manage Home,
the Project card and Settings. **A surface only decides which layer edits go
to.** Each surface owns a set of targets: Manage Session owns this chat's Chat
layer; Manage Home owns Home's Chat and Profile layers; the Project card owns
this project's Project layer and every key instance qualified by this project
(so trust for this project is edited there, though it is stored at the Mac
layer); Settings owns the Mac layer. A row edits the highest layer the surface
owns that the key allows. If the key allows none of them, the row is read-only
with **"Edit at Project"** or **"Edit at Mac"**, which opens that surface.

| Surface | Edits | Also holds |
|---|---|---|
| **Manage Session** (an ordinary chat) | Chat | The Project card first (project, trust, git state, outside changes); a Settings row, the one door per chat (the ordinary-chat gear opens Manage Session, not Settings: `ChatView.swift:2864-2876`, `ChatRoutes.swift:89-101`); this chat's Changes; the Session section (history, fork, export, archive). |
| **Manage Home** | Chat for Home's chat; Profile for profile keys | Memory browser, chapters, tasks, Home's Changes; #743's next-prompt preview as Context's delivered stage; #734's "About you" beside the profile values. The gear and context ring keep their routing (#748). |
| **Project card** | Project (the `.pi/` working tree), and `permissions.projectTrust` for this project (a Mac key qualified by it) | The repo's outside changes by commit; Staged, Uncommitted and Local only badges ([5.7](#57-project-writes)); an untrusted project's values as not applied, with Review trust. Opened from Manage Session and from the dashboard project list as the same component. |
| **Settings** | Mac | The floor overrides in Permissions; the full Changes feed; Accounts, Sources, Setup and This iPhone. The Global/Project scope pickers are removed. |
| **New Session** | Chat of the new chat, at creation | The resolved values for the picked project with badges, mainly Model, and the trust decision when needed. Overriding never changes a default. `NewSessionSheet.swift:94-96` already says "Use the current agent default"; it gains the badge. |

Why the Project card also opens from the dashboard: today the only way to edit
project settings without a chat is the Global/Project scope picker
(`SettingsScopeRow.swift`, `AgentDefaultsSettingsView.swift`). The dashboard
route keeps three things possible: setting a project's model and tools before
its first chat, reviewing or revoking trust, and seeing what a pull changed.
It is the same component with no new Gateway surface.

### 7.8 Stress tests for rendering

| Case | What changes | Expected iOS change |
|---|---|---|
| A new model with a new reasoning knob (say `effortCurve`, low to max) | A schema entry `model.effortCurve[model]` in Model, control `choice` (ordered), `optionsSource: catalog.effortLevels(model)`, `importance: advanced`. The catalog declares support. | **None.** The row appears for models that declare it and nowhere else. |
| The same knob needs a control iOS lacks (a two-axis budget) | The entry declares `control: "budgetPlane", fallback: "number"` and a new renderer version. | **None to keep working**: current apps get the `number` fallback (or `readOnly` with `display`). A later app release adds the richer control. |
| A new feature group (for example a Scheduling subgroup in Run, or a new section) | Schema entries with a new `subgroup`, or a declared section with title and order. | **None.** Sections and subgroups are schema data. |
| A new layer value source (for example a workspace profile, or an org policy file at the Mac layer) | A new store bound in the schema and a new layer id in the resolver, with its badge label and the surface that edits it (if any). | **None to show it**: the badge is neutral-styled with the Gateway's label, and rows say "Edit at <layer>" or are read-only. A new editing surface would be a new screen, only if the maintainer wants one. |
| An old iOS app talking to a newer Gateway | Newer controls, badge kinds, sections and fields. | **None.** Negotiation sends fallbacks or `readOnly`; unknown badges are neutral; unknown fields are ignored; every value still shows. |

### 7.9 Each duplicate resolved to one editor

| Audit | Today | One key, one editor per layer |
|---|---|---|
| D1. Model and thinking in six places, with three meanings | Manage Session, Agent Defaults (global or project), New Session, Manage Home chat model, Home memory model, `delegate` arguments | `model.ref` and `model.thinking`, by role. Chat in Manage Session and Manage Home (and New Session at creation), Project in the Project card, Mac in Settings › Model. The worker and memory roles in Manage Home (Profile). `delegate` arguments are turn-level inputs. |
| D2. Three controls called "Thinking" | Chat thinking, default thinking, compaction "Summary Thinking" (`CompactionSettingsView.swift:102`) | One key, `model.thinking`, with roles: "Thinking", "Worker thinking" and "Summary thinking", all in Model, each badged with its layer. |
| D3. "Project Trust" with three meanings | Settings › Project Trust as the default policy (dashboard) or as this project's decision (chat) (`SettingsView.swift:99-107`), and the New Session trust prompt | `permissions.projectTrust[project]` in the Project card, prompted by New Session. `permissions.defaultProjectTrust` in Settings › Permissions. |
| D4. Resources with four truths (installed, search paths, loaded, delivered) | Extensions, Locations and Overrides, Project Resources, Agent Instructions | Sources: installed and search paths, with where each came from. Context, Tools and Run show each contribution's chain. |
| D5. Context window | Manage Session slider (session entry) and Agent Defaults (`modelContextWindows`) | `model.contextWindow[model]`, one `number` control with a catalog range, edited at the surface's layer. |
| D6. Compaction shown read-only in a second place | Settings › Compaction edits, and its live policy is repeated read-only (`CompactionSettingsView.swift:244-257`) | Context › Compaction, generic rows at each surface's layer. |
| D7. Queue delivery | Long-press per message versus the `steeringMode` and `followUpMode` defaults | The long-press is a turn-level input and shows "Default: X (Mac)". The defaults are `run.queue.*`. |
| Untracked agent edits | Agents edit `settings.json` directly, and nothing records it | The `settings` tool through the change path. Direct edits are outside changes (F2). |

## 8. Migration from today

Re-verified against `main` at `b76f6ca80`.

**Gateway**

| Today | Becomes |
|---|---|
| `admin/settings-service.ts:121-195` `get`: two documents plus an effective object | `settings.resolve` from the schema: every key with value, `display`, layer, applied flag, badges and section summaries, for a target (Mac, project, session or profile). `settings.get` is removed when its last client moves (no alias). |
| `admin/settings-service.ts:197-356` `update` and `applyPatch`: hand validators | Schema entries own validation. `SettingsService` becomes the pi-settings-file applier. |
| `transport/gateway-service.ts:1948-1978` `settings.get` and `settings.update` | `settings.resolve`, `settings.change` (with `dryRun`), `settings.undo`, `settings.history` and `settings.options`, plus the schema served to clients. |
| `transport/gateway-service.ts:1671-1690` `session.setModel` and `setContextWindow`; `runtime-slot.ts:9271-9344` setters | Chat-layer appliers behind `settings.change`. The lane guards (`assertConfigurationIdle`, expectations) stay. |
| `transport/gateway-service.ts:1980-1996` `trust.set`; `admin/trust-service.ts:107-157` | The `permissions.projectTrust` applier. `setAndApply`'s rollback pattern becomes the cross-store rule. |
| `home/home-owner.ts:77,978` memory model in `home.json`, `home.configureMemory` | `model.ref[role=memory]` in `profile.json`, applied by `HomeOwner`. |
| `home/home-task-dispatcher.ts:190-193`, `home-task-worker-choice.ts`, `tron-home-extension.ts:29,77` ("omit both for the Gateway default") | Home's `delegate` handler fills omitted `model` and `thinking` from the profile (`sameAs: home`) before admission, clamping thinking to the model; an explicit choice wins with its reason ([6.3](#63-worker-model-same-as-home)). |
| `admin/settings-service.ts` project writes: working tree only | The Project applier writes, stages when git can, and records the git result; it never commits ([5.7](#57-project-writes)). |
| No per-chat Run values; `images.blockImages` read per request by pi but only from settings files | Chat-layer values in `tron.settings.v1` for every key that allows Chat, applied to the chat's own settings ([3.4](#34-timing)). |
| `home/home-profile.ts:21-23` `delegation-default` notes | Kept as the *why*. Values move to typed keys. |
| `runtime-slot.ts:1924` one `SettingsManager` per runtime build; compaction-only live refresh (`runtime-registry.ts:3656`) | Live keys read the resolver at their effect point; fixed keys are copied with provenance at chat start. |
| `context-window-policy.ts:7` `tron.context-window.v1` | Kept as the Chat-layer store for `model.contextWindow`, with provenance through `tron.settings.v1`. |
| No comparison of stores with Tron's writes | Outside-change detection by content digest ([5.6](#56-outside-changes)). |
| `notifications/grant-store.ts:223` push policy | Unchanged storage, shown under Setup. |

**iOS**

| Today | Becomes |
|---|---|
| Per-screen settings views with per-key controls | One generic renderer over the served schema: the control primitives, badges, section summaries and negotiation ([7.5](#75-the-rendering-contract)). |
| `UI/Chat/ChatView.swift:2864-2876` gear opens Settings for ordinary chats | Opens Manage Session. Home is unchanged. |
| `UI/Chat/ChatRoutes.swift:89-101` `SettingsView(scope: .project)` sheet | Reached as a row inside Manage Session. |
| `UI/Chat/ChatComposerView.swift:259` context ring | Unchanged: it already opens Manage Session (#748). |
| `UI/Chat/SessionContextSheet.swift:530-590` model card, thinking and context window; `:649-690` session section | The generic sections plus the Project card, this chat's Changes and the Settings row. |
| `UI/Chat/HomeSheets.swift:233-291,351` chat model and context window values, memory model | The generic sections, with Profile rows, plus Home's Changes. |
| `UI/Settings/SettingsView.swift:39-122` groups This iPhone, Agent, Tools & Extensions, Data & Diagnostics, with scope-dependent trust | The sections in order, Mac layer only, and the Changes feed. |
| `UI/Settings/SettingsScopeRow.swift`, `AgentDefaultsSettingsView.swift`, `ResourceSettingsView.swift:188`, `HooksSettingsView.swift:262` scope pickers | Removed. Project editing moves to the Project card. |
| `UI/Settings/AgentConfigurationControls.swift:6,22,115`, `ThinkingSlider.swift`, `ContextWindowSlider.swift` | The `catalog`, ordered `choice` and `number` control primitives, fed by served options. |
| `UI/Settings/CompactionSettingsView.swift:102,244-257` | Generic rows in Context › Compaction, plus Model › Summary thinking. |
| `UI/Chat/NewSessionSheet.swift:94-96,339-343`, `NewSessionConfigurationOwner.swift` | Generic Model rows at the new chat's Chat layer, with badges. |
| The dashboard project list (`UI/Chat/SessionShellView.swift`, inferred owner) | Gains "Project settings", which opens the Project card. |

**Mac menu bar** (`packages/mac-app/Sources/MenuBar/MenuBarController.swift`):
Gateway lifecycle and pairing only (Setup). It has no harness keys, and none are
planned for it.

## 9. Slices

Each slice is a Proposed issue under epic #758; the maintainer moves a slice to Ready.
Slices land on `main` one at a time, in their blocked-by order, with no
integration branch ([decision 16](#101-decisions)). Size is S, M or L. Slice 14
was added after the first numbering; it lands after slice 4 and before slice 8.

| # | Slice | Size | Area | Depends on | Issue |
|---|---|---|---|---|---|
| 1 | One door per chat: the ordinary-chat gear opens Manage Session, and Settings is a row inside it | S | iOS | | #759 |
| 2 | Clear names and the shared badge component on today's rows | S | iOS | | #760 |
| 3 | The schema and `settings.resolve`: layers, provenance, display metadata, an untrusted project shown as not applied, capability clamping | L | Gateway | | #761 |
| 4 | One change path: `settings.change`, the record (kept forever), undo and Apply again, history; today's setters migrate; Project writes are written and staged, never committed | L | Gateway, iOS | 3 | #762 |
| 5 | Tiers: floors with the maintainer's overrides, the one-step web mark, approval by tap with 24-hour expiry and the requester told, and the `settings` tool | L | Gateway, iOS | 4 | #763 |
| 6 | Outside changes: stores compared with the record, "Changed outside Tron" with Apply again, notification by floor, git-state badges | M | Gateway, iOS | 4 | #764 |
| 7 | Fixed-at-start values carry provenance, with "Use the current default"; live keys reach open chats; Chat-layer values for every key that allows Chat; per-direction timing | M | Gateway, iOS | 3, 4 | #765 |
| 14 | The generic renderer: served schema, control primitives, `settings.options`, `dryRun` validation, badges and section summaries from the resolver, negotiation with fallback to read-only | L | Gateway, iOS | 3, 4 | #780 |
| 8 | Manage Session and Manage Home show the sections through the generic renderer (D1, D2, D5, D6, D7) | L | iOS | 2, 7, 14 | #766 |
| 9 | The Home profile becomes a typed layer for the Home chat: worker model and thinking "same as Home" filled into `delegate` by Home, memory model, task budgets | M | Gateway, iOS | 4 | #767 |
| 10 | The Project card in Manage Session: the Project layer with git-state badges, trust, and outside changes | M | iOS | 6, 8 | #768 |
| 11 | Settings becomes the Mac layer by section, the scope pickers are removed (D3, D4), and the Changes feed in Settings, Manage Session and Manage Home | M | iOS | 8, 10 | #769 |
| 12 | The Project card opens from the dashboard project list | S | iOS | 10 | #770 |
| 13 | A risk model can raise a change's tier | M | Gateway | 5 | #771 |

How #743 and #734 fit:

- **#743** (Home next-prompt preview and delivered context) is the delivered
  stage of Home's Context section. It does not depend on this epic. When slice
  8 lands, its viewer sits under Context without rework.
- **#734** (Home acts on your behalf) owns the learned notes and "About you".
  Slice 9 adds the typed profile values beside them; #734's note-based
  `delegation-default` stays as the explanation.

## 10. Decisions and open questions

### 10.1 Decisions

All decided by Mohsin on 2026-10-10. The foundations come first; every other
decision is listed with the foundation it follows from or the place it
refines. The sections above already reflect them.

**Foundations**

| # | Topic | Decision |
|---|---|---|
| F1 | Schema | Each setting is one key declared once on the Gateway (type, group, allowed layers, fixed at start or live, tier floor, redacted, validation, display metadata). iOS renders keys generically; hand-built screens only where a generic row cannot work. New models, features and keys need no iOS release ([1](#f1-schema), [4](#4-the-schema), [7](#7-presentation-and-the-rendering-contract)). |
| F2 | Truth | Each layer's store is the truth; the change log is audit and undo. A store that differs from the last logged value is an outside change with Apply again. No per-git-case rules ([1](#f2-truth), [5.6](#56-outside-changes)). |
| F3 | Policy | Tier = max(key floor, risk-model raise, one step up if the turn read web or browser content). No per-key exceptions. Trust, credential and budget raises default to a tap floor, which the maintainer can lower; lowering any floor needs his tap and is logged ([1](#f3-policy), [5.4](#54-tiers)). |
| F4 | Layers | Uniform, top wins: Chat > Home profile > Project `.pi/` > Mac > Built-in. One resolver takes the top layer that has the key and is allowed to set it. "Mac only" and similar are schema data ([1](#f4-layers), [3](#3-layers-and-resolution)). |

**The first sixteen**

| # | Topic | Decision |
|---|---|---|
| 1 | Doc lifetime | It stays a design doc. Migration and Slices are removed as slices land. |
| 2 | Home profile reach | Home only. Workers get profile-derived values because Home passes them in `delegate`; chats the maintainer starts never see the profile ([3.3](#33-which-layers-a-target-has), [6.2](#62-who-it-applies-to)). |
| 3 | Profile versus a repo's default for workers | Home's worker model beats a repo's `.pi/` default for workers Home starts there; the repo default still applies to chats the maintainer starts ([6.3](#63-worker-model-same-as-home)). |
| 4 | Worker thinking | Defaults to "same as Home" ([6.3](#63-worker-model-same-as-home)). |
| 5 | Explicit `delegate` choice | An explicit model or thinking level in the call beats "same as Home"; the brief records the choice and the reason. |
| 6 | Content escalation | Raises a change one tier, not straight to approval. Refined by F3 and Q20 (the tap for trust, credentials and budgets is a default floor) and Q21 (only web and browser content marks a turn) ([5.4](#54-tiers)). |
| 7 | Floors | Defined in code; the maintainer may raise or lower any floor, and lowering needs his tap and is logged. The risk model can only raise. Now part of F3. |
| 8 | Pending approvals | Expire after 24 hours. Extended by Q22: whoever asked is told on its next turn ([5.5](#55-approvals)). |
| 9 | Chat overrides for Run keys | A single chat may override any Run key and compaction: their allowed layers include Chat (F4). |
| 10 | Push policy placement | Under Setup ([2.2](#22-supply-and-non-harness-sections)). |
| 11 | Retry and transport | Under Run, with a per-provider qualifier ([2.1](#21-harness-primitives)). |
| 12 | Record | Kept forever, with a full Changes feed that supports undo ([5.2](#52-the-request-and-the-record), [7.4](#74-the-changes-feed)). |
| 13 | Outside project changes | Notify only on permission-related `.pi/` changes after a pull (Permissions, Tools, hooks, Sources). Now a consequence of F3: an outside change's tier is its key's floor, and only `notify` or `approve` push ([5.6](#56-outside-changes)). |
| 14 | Project writes | Tron edits a repo's `.pi/` and stages it with `git add`; it never commits, pushes or opens a pull request. Refined by F2 and Q24 to Q27: the file on disk is the layer, and git state is a badge ([5.7](#57-project-writes)). |
| 15 | Image blocking timing | Turning blocking on applies at once; turning it off waits for the next chat start or an approval. Expressed as per-direction timing in the schema ([3.4](#34-timing)). |
| 16 | Landing | Slices land on `main` one at a time, in their blocked-by order ([9](#9-slices)). |

**Answers to Q17 to Q27, as consequences**

| # | Question | Answer | Follows from |
|---|---|---|---|
| 17 | Do chat overrides reach `httpProxy` and `cacheWarming`? | No. They are Mac-only keys: their allowed layers exclude Chat. | F1, F4 |
| 18 | Floor for a chat's agent raising its own retries or timeouts | Quiet and logged: that is those keys' floor. | F3 |
| 19 | Undo of redacted keys | The record has no old value, so the change shows as Not undoable. | F1 `redacted`, F2 |
| 20 | Can the trust, credential and budget tap be lowered? | Yes, like any floor, with the maintainer's tap, logged. | F3 |
| 21 | Which content marks a turn? | Only web and browser content, one step up, in Home, ordinary chats and workers alike. | F3 |
| 22 | Who is told on decline or expiry? | Whoever asked (Home, an ordinary chat's agent, a worker), on its next turn. | F3 (one path for every actor) |
| 23 | `delegate` names a model that lacks Home's thinking level | The closest supported level, noted in the brief. | F1 option sources ([3.6](#36-capability-constrained-values)) |
| 24 | The maintainer unstages a Tron edit but keeps it | The value still applies; the badge reads Project · Uncommitted. | F2 (git state is a property of the store) |
| 25 | A staged edit is lost to a revert, stash, reset or branch switch | Recorded as an outside change, with Apply again; never re-applied automatically. | F2 |
| 26 | Other work is already staged | Stage anyway, and warn in Changes. | Decision 14, F2 |
| 27 | Linked worktrees, subdirectories, an ignored `.pi/` | Use the chat's worktree root. An ignored `.pi/` is written, not staged. | F2 (the store is the file on disk) |

**Foundational follow-ups**, asked after Q17 to Q27, answered directly by
Mohsin on 2026-10-10.

| # | Question | Answer | Follows from |
|---|---|---|---|
| 28 | Does the web mark travel with content another turn reads later (a worker's report, a Knowledge record captured from the web, a snippet of a marked chat)? | No. The mark belongs to the turn whose tool call read web or browser content. | F3 |
| 29 | May staging also stage the maintainer's own unstaged edits in the same `.pi/` file? | Yes: stage anyway, and warn in Changes, as for other staged work. | Decision 14, Q26 |

### 10.2 Open questions

None. A new question is added here only if it concerns a foundation; anything
else is answered by applying F1 to F4.
