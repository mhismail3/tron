# Settings model

**Status: implemented.** Epic #758 shipped this model (#798, #869, #864, #884).
The doc stays the reference for the foundations, primitives, layers, schema,
change path and rendering contract ([decision 1](#81-decisions)); the migration
plan and slice list were removed once every slice landed. Sections marked
"implemented" name the owning code; the rest is the contract that code follows.

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
8. [Decisions and open questions](#8-decisions-and-open-questions)

## 1. Foundations

Decided by Mohsin on 2026-10-10 ([10.1](#81-decisions)).

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

Precedence is scope first, only among layers the target and key admit:

- **Ordinary Session > Project (`.pi/`) > Mac > Built-in.**
- **Home chapter Session/launch inputs > Home profile > Mac > Built-in.** Home never loads Project settings; ordinary sessions never load Home profile.
- Workers are ordinary sessions. Home may explicitly resolve and copy permitted launch choices into a worker, with canonical launch provenance; this is not an inherited Home layer.

For a model-qualified key, specificity wins **within its scope**. A Mac per-model value cannot outrank a Project plain value or a Session override. Relative tool selections compose from the lower allowed scopes rather than replacing them.

One resolver gives a key's value for a target: it takes the topmost layer that
the target has, that holds a value for the key, that the key's schema allows to
set it, and that is applied. Which layers a target has follows from which
stores it has ([3.3](#33-which-layers-a-target-has)). A layer can be present
but not applied, with a reason; today the only reason is an untrusted project
([3.5](#35-trust-and-an-untrusted-projects-layer)).

### 1.5 What follows

These used to be separate principles. They are consequences of F1 to F4:

- **The effective value is computed, never stored** (F4). The only copies are
  values fixed at session start, retained as Chat-layer launch snapshots distinct from explicit overrides, with canonical evidence of where they came from ([3.4](#34-timing)).
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

The schema's `group` field (F1) declares durable presentation groups. A
model call remains `f(model, context, tools)`, under permissions and driven by
a run loop; presentation groups collect related controls without changing key
IDs, runtime bindings, allowed layers, timing or authority. Runtime request
application follows a key's binding, timing and effect, not its UI group.

### 2.1 Harness groups

| Group | Holds |
|---|---|
| **Model** | The chat model, its thinking level, and context window. |
| **Workers & delegation** | Worker, subagent and background model queues, worker thinking, and task budget. Home additionally embeds its standing delegation scope and conditional grants/requests using the existing permission owner. |
| **Compaction** | Automatic compaction, reserve and keep-recent tokens, summary instructions, summary thinking, and branch-summary reserve. |
| **Tools** | Active tools, code mode and inline budget, shell configuration, and image resize/block controls. |
| **Connection** | Model-request transport, HTTP/WebSocket timeouts, HTTP proxy, and cache warming. |
| **Advanced** | Offered models, thinking budgets, default trust policy, project trust and approval levels, message delivery and retries. Multi-instance approvals retain their existing dedicated editor. |

These groups are Gateway schema data, shared by Home, Chat, Project and Mac
settings. A role or qualifier selects the model/project instance; it never adds
a layer. The stable `model.*`, `context.*`, `tools.*`, `permissions.*` and
`run.*` key namespaces identify the underlying domain independently of
presentation.

### 2.2 Supply and non-harness sections

| Section | Holds | Relation to the primitives |
|---|---|---|
| **Accounts** | Provider credentials and sign-in, the custom model catalog (`models.json`), connected services, MCP credentials. | Setup and status. Model and Tools draw on it; the model option source is built from the catalog Accounts supplies. |
| **Sources** | Packages, extension, skill and prompt search paths, and `npmCommand`. | A package is a delivery format, not a primitive. Sources shows where each thing came from. Each contribution is shown in its primitive: tools in Tools, skills and prompts in Context, hooks in Run. |
| **Setup** | Pairing, Gateway lifecycle and updates, the Mac wizard, `sessionDir`, install telemetry, push notification policy, logs, import and export. | No effect on what the model is, sees or does. |
| **This iPhone** | Appearance, density, dashboard and subagent activity display, the Changes "last looked" marker. Stored on the device. | Never changes harness behaviour, and the section says so. |

The push notification policy is stored on the Gateway
(`<tronHome>/gateway/notifications.json`), so it belongs to Setup, not This
iPhone ([decision 10](#81-decisions)).

### 2.3 Keys by primitive

The pi `settings.json` keys and the Tron stores outside it, as declared in
`packages/gateway/src/admin/settings-schema.ts`. The allowed layers and timing are
schema data (F1); no row here is an exception to a rule. The Primitive column
names the underlying runtime domain, not its current presentation group (2.1).

| Key (storage) | Primitive | Allowed layers | Timing |
|---|---|---|---|
| `defaultProvider` + `defaultModel` → `model.ref[role=chat]` | Model | Chat, Profile, Project, Mac | Fixed |
| `defaultThinkingLevel`, pi `modelThinkingLevels` → `model.thinking[role=chat]` | Model | Chat, Profile, Project, Mac | Fixed |
| `thinkingBudgets` | Model | Project, Mac | Fixed |
| `modelContextWindows` → `model.contextWindow[model]` | Model | Chat (session entry), Profile, Project, Mac | Fixed |
| `enabledModels` → `model.offered` | Model | Project, Mac | Live (picker filter only) |
| `compaction.thinkingLevel` → `model.thinking[role=summarizer]` | Model | Project, Mac | Live |
| `compaction.enabled`, `reserveTokens`, `keepRecentTokens`, `instructions` | Context | Chat (not Home), Project, Mac | Live |
| `branchSummary.reserveTokens` | Context | Project, Mac | Live |
| `images.autoResize` | Context | Chat, Project, Mac | Fixed |
| `images.blockImages` → `context.images.block` | Context | Chat, Project, Mac | Narrow live, widen fixed ([decision 15](#81-decisions)) |
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
| Model fallback queues → `model.queue[role=worker\|subagent\|background]` | Workers & delegation | Profile, Mac; read-only Session launch evidence for worker/subagent | Home captures worker/subagent queues at task admission; ordinary subagents and Knowledge use Mac queues; Home memory uses Profile ([6.3](#63-model-fallback-queues)) |
| Worker thinking (new) → `model.thinking[role=worker]` | Model | Profile | Read when Home delegates ([6.3](#63-model-fallback-queues)) |
| `npmCommand` | Sources | Mac | Live |
| `sessionDir` | Setup | Mac | Restart |
| `enableInstallTelemetry` | Setup | Mac | Live |
| App terminal and Mac Terminal shell idle period (`gateway/settings/gateway.json` `terminal.idleMinutes`) → `setup.terminalIdleMinutes` | Setup | Mac | Live (next idle pass, #479; the Mac Terminal shell host reads it too, #1075) |
| Push policy (`notifications.json`) | Setup | Mac | Live |
| Terminal-only pi keys (`theme`, `tuiMode`, ...) | Not declared | | |

Two consequences worth naming:

- A chat may override every Run key whose allowed layers include Chat
  ([decision 9](#81-decisions)). `httpProxy` and `cacheWarming` do not include
  Chat, because pi reads them only from the agent directory, so a chat cannot
  override them ([Q17](#81-decisions)). That is their schema entry, not an
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
| 13 | One chat needs more retries for a flaky provider | Run: `run.retry.maxRetries[provider]` at that chat's Chat layer. Other chats keep following the default live. | Clean: Run keys allow Chat (decision 9). The agent raising its own chat's retries is quiet by floor ([Q18](#81-decisions)). |
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
of a chat being created (a delegated worker, [6.3](#63-model-fallback-queues)).

### 3.2 Stores

F2: each store is its layer's truth.

| Layer | Store | Owner |
|---|---|---|
| Chat | The session JSONL: pi's `model_change` and `thinking_level_change` entries, Tron's `tron.context-window.v1` entry (`packages/gateway/src/providers/context-window-policy.ts`), the active tools, and a new `tron.settings.v1` entry for the other Chat-layer keys and the provenance of fixed values. | The session's runtime slot lane. |
| Profile (Home) | `<tronHome>/gateway/home/profile.json`, typed. Not Knowledge note text ([6](#6-the-home-profile-layer)). | `HomeOwner`. |
| Project | `.pi/settings.json`, `.pi/mcp.json` and the rest of `.pi/`, on disk at the chat's worktree root ([Q27](#81-decisions)). | The repo (git). Tron writes the working tree and stages; it never commits ([5.7](#57-project-writes)). |
| Mac | `<tronHome>/agent/settings.json`, `models.json`, `mcp.json`, `trust.json`, plus the Gateway stores (`connections`, `notifications.json`, `settings/floors.json`, and `settings/gateway.json` for Gateway-owned keys no pi file holds). | The Gateway. pi CLI runs and hand edits are outside writers. |
| Built-in | Code: pi defaults and the schema's `builtin` values. | The release. |

The Mac layer is `<tronHome>/agent/settings.json`: the agent directory is
`<tronHome>/agent` (`packages/gateway/src/config.ts`), not `~/.pi/agent`.

**The Project store's location.** The Project store for a chat is `.pi/` at
that chat's worktree root: a linked worktree uses its own `.pi/`, never the main
checkout's, and a chat started in a subdirectory uses its worktree's root. The
Gateway's `projectRoot()` resolves it and every owner reads it from
`TrustInspection.projectDir`; the runtime passes it to pi as `projectDir`
([Project root](../README.md#project-root)).

### 3.3 Which layers a target has

A target has a layer when it has that layer's store. Nothing else decides it.

- An **ordinary chat in a project** has Chat, Project, Mac and Built-in. It has
  no profile, because profiles are Home-only ([decision 2](#81-decisions)). This
  includes the chats the maintainer starts and the workers Home starts.
- **Home's own chat** has Chat, Profile, Mac and Built-in. It has no project:
  Home runs in a neutral workspace with no project discovery
  (`packages/gateway/src/sessions/runtime-slot.ts`).
- A **Home task worker** is an ordinary chat in its target project. Its model
  and thinking arrive as `delegate` arguments that Home filled from its own
  profile, written into the worker's Chat layer at start
  ([6.3](#63-model-fallback-queues)). Being Chat-layer values, they sit above
  the repo's `.pi/` default for that worker ([decision 3](#81-decisions)),
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
  ([decision 15](#81-decisions)) declare that: turning image blocking on
  applies from the next request, and turning it off waits for the next chat
  start. A widening that was approved (or tapped by the maintainer) applies at once. pi
  already re-reads `images.blockImages` on every request and replaces image
  content with a placeholder (`pi-coding-agent` `dist/core/sdk.js`,
  `convertToLlmWithBlockImages`), so "on" needs no new pi hook.

The **effect point** is a separate field: `next-turn`, `next-request`,
`new-chat`, `reload` or `restart`. The row shows it when a change does not take
effect at once ("Applies after restart").

**Current implementation.** New chats capture fixed model, thinking, context
window, active tools and declared fixed Chat settings in canonical
`tron.settings.v1` metadata (`value`, `from`, `at`, stable `ref`, and role
qualifiers). SDK model/thinking entries and context policy remain their value
owners. Metadata records their actual capability-clamped values, not a second
runtime setting. Existing chats without provenance do not acquire fabricated
history. Fork and cold resume preserve the metadata and tool choice; a later
canonical choice wins over an older SDK system frame.

The resolver exposes source badges and `fixedAt`. A fixed-key Chat unset means
“Use the current default”: it resolves the lower layers once, records the source,
and applies that exact value through the normal audit/approval path. Subsequent
default changes still cannot move it. The generic iOS renderer understands this
served action, but adoption in Manage Session/Home remains a separate slice.

For `context.images.block`, a live narrowing default is read at request admission
while an unapproved widening remains pinned. After a maintainer tap or recorded
approval changes a Mac or Project default to unblocked, the applied change releases
the inherited image-block pins in already-open chats at that scope. The release
is a branch-local canonical settings entry, so cold resume retains it; an explicit
Chat-layer value is never removed. A Mac change reaches only chats whose effective
image policy still inherits Mac or Built-in, never a Project-shadowed pin. Project
changes reach only matching Project chats whose inherited policy is now unblocked.
The higher-layer negative control is an outside Project widening immediately after
a Mac tap, without an intervening request: that chat must keep blocking. The
changed layer owns propagation, including when a Chat/Home requester edits a
Mac or Project default through a session-targeted change or approval.
Image auto-resize uses its fixed snapshot at the actual conversion boundary.
Resources still apply through Reload. Compaction changes refresh open chats
through `GatewayService.settingsChanged`.

Live Run declarations with a Chat settings binding resolve again before a
prompt and before each provider request. The runtime overlays
only these operational fields on the actual session's `SettingsManager`,
including Home's SDK-created manager; it does not reload fixed resources or
save defaults. Agent queue modes and request transport/retry-delay options also
receive that projection because the SDK copies those controls at construction.
The `prepareRequest` wrapper composes with Home's existing request guard.

An explicit Run override is a branch-local `tron.settings.v1` custom entry
containing the Chat settings document; fork and cold resume read that canonical
entry, never the change record. Unsetting removes the key, so the next request
resolves the current lower layer. The session's own settings tool can append an
override within its already-owned run lane without recursively acquiring that
lane. iPhone changes retain the idle, runtime/model fence and chapter guards.
`settings-gate.e2e.test.ts` proves changed retry counts in an already-open chat,
Chat isolation, unset, agent self-edit, fork/cold-resume persistence without
Mac-default writes, and Home's actual provider transport/retry-delay options.
Optional provider timeout/count and WebSocket timeout use the same Chat store.
Their complete resolved snapshot replaces the three SDK-composed options at
`ModelRuntime.streamSimple`, scoped by the exact agent request across asynchronous
stream work. Unset removes an optional value rather than reviving the manager's
initial defaults; provider timeout then follows the resolved idle timeout. This
uses the runtime-owned view (also for Home), so other sessions and independent
memory/extension calls retain their own options. The same E2E exercises both
ordinary and Home requests with initial Mac values, a Chat override, removed Mac
values and unset, plus optional-value fork/cold resume.
The bounded `settings-run-applied` session diagnostic shows the runtime policy
at request admission, rather than merely the defaults a settings read resolves.

Directional request settings retain canonical `requestPins` snapshots with the
same value/source/time/reference metadata in `tron.settings.v1`. At start and before SDK message conversion, the schema's
direction/timing permits narrowing but retains a fixed-direction value. Image
blocking therefore strips images from the next provider request, including the
next request within a tool turn. A default or outside relaxation cannot expose
images already blocked in that chat; fork and cold resume retain the snapshot.
A Chat-layer approval or maintainer tap can release it, including an unset back
to the current default. Lowering the key's risk floor alone does not change its
timing. Ordinary and Home provider-content journeys prove these boundaries.
The resolver shows the effective pinned value separately from the stored override.

Home rollover carries the adjacent sealed chapter's Chat policy into the reserved
successor: model/thinking entries, bounded effective context preferences, tool
loadout, explicit settings and snapshot provenance. The ledger selects the source;
a live sealed slot supplies its canonical branch, otherwise an identity-fenced
cold read does. Invalid/missing cold evidence fails closed. Adoption of an already
materialized successor never recopies from the predecessor. Neither old messages,
entry identities nor audit receipts are copied. Home's normal summarized memory
view remains independent. Warm and capacity-evicted predecessor journeys exercise
the actual `home.prompt` path and the `settings-from-live`/`settings-from-cold`
recovery diagnostic.

This is not complete timing support: propagation of an approved Mac/Project
widening into existing chats uses the scoped canonical pin release above. End-to-end Chat reset
adoption is implemented in Manage Session's Settings destination, including the
runtime/model/revision fence and reopening proof. Manage Home's generic settings
adoption and the remaining inline card consolidation are still outstanding. The SDK's merge-only
`applyOverrides` is not the owner of optional-field removal; the final provider
boundary above is, after SDK default composition.

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
pi's `ProjectTrustStore` (`packages/gateway/src/admin/trust-service.ts`). Its
allowed layers exclude Project, so a repo can never grant itself trust. Its widen
floor is `approve` by default (F3). The default policy (`defaultProjectTrust`:
ask, always or never) is a Mac-layer key.

An untrusted project's `.pi/` layer is **present but not applied** (F4):

- The Gateway reads `.pi/settings.json` as JSON data, which executes nothing;
  executable resources stay gated by trust as today. `settings.resolve` returns
  the Project value with `applied: false, reason: "untrusted"`, and the
  effective value comes from the next layer down.
- Rows show the repo's value struck through, with a **"Project · not applied
  (untrusted)"** badge and **Review trust**. (The former `settings.get` projection hid
  the untrusted Project document; it is removed.)
- Tron never writes the Project layer of an untrusted project, as today's
  `trust_required` refusal does (`settings-service.ts:202-204`).

### 3.6 Capability-constrained values

Some keys take only the values a capability allows, such as the thinking levels
the selected model supports. The schema names the option source
([4.1](#41-fields)). When a value meets a model that does not support it (the
chat's model changes, or a `delegate` call names a model that lacks Home's
thinking level), the resolver uses the **closest supported value** and says so
with a "Clamped" badge; a `delegate` brief records it
([Q23](#81-decisions)). pi already clamps a thinking level to the model's
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
| `group` | The section: `model`, `workers`, `context`, `tools`, `run` or `advanced`, or a supply section: `accounts`, `sources`, `setup` or `iphone`. Sections are themselves declared, with a title and order, so a new one needs no client change. |
| `subgroup` | An optional heading within the section (for example `Compaction`). |
| `qualifiers` | Any of `role`, `model`, `provider`, `tool`, `project`, `connection`, `key`, `direction` (a floor override's direction). |
| `type` | The value type and its static validation (range, pattern, length, item type). |
| `options` | A static list of allowed values, or an `optionsSource`: a named Gateway source such as `catalog.models`, `catalog.thinkingLevels(model)`, `catalog.contextWindow(model)` or `catalog.tools`, with the keys it depends on. `catalog.tools` offers a chat's live registry (less hidden tools); for a Mac or Project target, pi's built-in tools then the opt-in (`defaultActive: false`) tools the scope's extensions register, since other extension tools are active once registered whatever the selection says. A chosen name the catalog no longer offers stays listed, disabled, so it can be cleared. |
| `layers` | The allowed layers, each with its storage binding (file and path, or session entry type). |
| `builtin` | The built-in value, or `pi-default`. |
| `timing` | `fixed` or `live`, or per direction `{ narrow, widen }` ([3.4](#34-timing)). |
| `effect` | `next-turn`, `next-request`, `new-chat`, `reload` or `restart`. |
| `floor` | The code floor, one tier or per direction `{ widen, narrow }`. Tiers are `quiet`, `notify`, `approve`. The maintainer may override it ([5.4](#54-tiers)). |
| `direction` | How to tell widen from narrow for this type (for example a larger budget widens, a removed tool narrows). Keys without a direction use one floor. |
| `writers` | Which actors may request a change: `ui`, `home`, `worker`, `agent`. `outside` is observed, never admitted. The list is the grant: there is no per-task grant, and a task worker may change every key an agent may ([decision 34](#81-decisions)). |
| `redacted` | Show "set" or "changed", never the value. The record holds no old value, so the change is not undoable ([Q19](#81-decisions)). |
| `applier` | The owner that performs the write: the pi settings file, a session entry through the slot lane, the profile store, the trust store, the MCP config, or the connections policy. |

**Display** ([7.5](#75-the-rendering-contract))

| Field | Meaning |
|---|---|
| `label`, `help` | The row title and a one-paragraph explanation, written for the maintainer. |
| `order` | Position within its section and subgroup. |
| `importance` | `essential` or `advanced`: ordering metadata within a section, not an extra one-row Advanced card. |
| `control` | One of the fixed control primitives, with an optional `fallback` control for older clients. |
| `unit`, `format` | How the Gateway formats `display` ("200K tokens", "3 retries"). |
| `confirm` | Optional confirmation text when the maintainer's own tap changes a key whose tier would be `approve` for anyone else. |
| `entry` | What to type: `{ hint, example }`. The hint names the format in one sentence; the example is a realistic value the client shows as the field's placeholder. Every editable `text` key and string-list key has one, so the client's shared text and add-value rows never invent their own guidance. |

Provenance is not a field. It is part of every resolved value
([3.1](#31-precedence-and-the-resolver)).

### 4.2 Example entries (real keys)

| id | group | qualifiers | layers → storage | timing / effect | floor (widen / narrow) | writers |
|---|---|---|---|---|---|---|
| `model.ref` | model | `role` | chat → `model_change`; profile → `profile.json` (Home chat); project/mac → `defaultProvider`+`defaultModel` | fixed / next-turn | quiet | ui, home, agent |
| `model.queue` | workers | `role` (`worker`, `subagent`, `background`) | profile → `profile.json` `modelQueue.<role>`; mac → `gateway.json` `modelQueues.<role>`; worker/subagent chat → read-only canonical launch inputs; built-in `[]` | defaults live; task choices fixed at admission / delegate, next child launch, next memory pass | notify | ui, home (never launch evidence) |
| `model.thinking` | model / workers / context (by role) | `role`, `model` | chat → `thinking_level_change`; profile (Home chat, and `role=worker` built-in `{ sameAs: "home" }`); project/mac → `defaultThinkingLevel`, `modelThinkingLevels`; summarizer → `compaction.thinkingLevel` | fixed (summarizer: live) / next-turn | quiet | ui, home, agent |
| `model.contextWindow` | model | `model` | chat → `tron.context-window.v1`; project/mac → `modelContextWindows` | fixed / next-turn | quiet | ui, home, agent |
| `context.compaction.reserveTokens` | context | `model` | chat → `tron.settings.v1`; project/mac → `compaction.reserveTokens`, `compaction.modelOverrides` | live / next compaction | quiet | ui, home, agent |
| `context.compaction.instructions` | context | | chat → `tron.settings.v1`; project/mac → `compaction.instructions` | live / next compaction | notify | ui, home |
| `context.images.block` | tools | | chat; project/mac → `images.blockImages` | narrow live, widen fixed / next-request | approve / quiet | ui, home, agent |
| `tools.active` | tools | | chat → active tool set; profile; project/mac → `defaultTools` | fixed / next-turn | notify / quiet | ui, home, agent |
| `tools.codemode.mode` | tools | | project/mac → `codemode.mode` | fixed / new-chat | notify / quiet | ui, home |
| `permissions.projectTrust` | advanced | `project` | mac → `trust.json` | narrow live, widen live once approved | approve / notify | ui, home |
| `permissions.macTerminalKey` | advanced | `device` | mac → `~/.ssh/authorized_keys` (the `tron-mac-terminal:<device>` line; [Mac Terminal](../README.md#mac-terminal)) | live | approve / notify | ui, home, agent, worker (an iPhone sets only its own device) |
| `permissions.defaultProjectTrust` | advanced | | mac → `defaultProjectTrust` | live | approve / notify | ui |
| `permissions.connectionWrite` (connection-policy owner, not a schema key) | — | `connection` | mac → connections policy | narrow live | approve / quiet | ui |
| `permissions.budget.task` | workers | | profile | narrow live | approve / quiet | ui, home |
| `permissions.floor` | advanced | `key`, `direction` | mac → `<tronHome>/gateway/settings/floors.json` | live / next change | lower: approve / raise: quiet | ui |
| `run.queue.steeringMode` | advanced | | chat; project/mac → `steeringMode` | live / next-turn | quiet | ui, home, agent |
| `run.retry.maxRetries` | advanced | `provider` | chat → `tron.settings.v1`; project/mac → `retry.maxRetries`, `retry.provider.maxRetries` | live / next-request | quiet | ui, home, agent |
| `run.transport` | run | `provider` | chat → `tron.settings.v1`; project/mac → `transport` | live / next-request | quiet | ui, home, agent |
| `run.httpProxy` | run | | mac → `httpProxy` | live / restart | notify; redacted | ui |

`permissions.floor` is an ordinary key with ordinary floors: lowering a floor
widens what agents may do, so its widen floor is `approve`, and only `ui`
writes it. The maintainer's own tap is that approval (F3). Nothing about it is
special-cased.

### 4.3 Implemented: the schema and the resolver

Slice 3 (#761) implements this section. The schema is
`packages/gateway/src/admin/settings-schema.ts` (value types in
`settings-types.ts`); the resolver is `settings-resolver.ts`, fed by
`SettingsModel` (`settings-model.ts`), which loads each store from its owner;
`settings.resolve` serves it. What the code fixes that the tables above leave
open:

- **Instances.** A fixed qualifier is part of the declared id
  (`model.queue[role=worker]`). A dynamic `model` qualifier is resolved for the
  target's effective chat model; a `project` qualifier for the target's project,
  or for every saved trust decision on the Mac target. A pi binding may name a
  per-model `qualified` path (`modelThinkingLevels`, `compaction.modelOverrides`):
  that instance is read across every layer before the plain key, exactly as pi
  resolves `modelOverrides ?? ordinary` on its merged settings.
- **Relative values.** pi's `defaultTools` `+name`/`-name` lists modify the value
  below them. That is the value type's `compose`, so the resolver still takes the
  top applied layer and composes it over the layer below. A change names the
  selection it wants; the type's `encode` stores it in the layer's own form: a
  Mac or Project layer holding modifiers (or nothing) keeps `+name`/`-name`
  entries relative to the layers below, so a later Mac change still flows into
  the project, and a selection equal to the one below leaves the layer unset. A
  plain list stays plain. Direction compares what each value selects.
- **Which keys a target shows.** A key appears for a target that has at least one
  of its allowed layers, so Home-only profile keys never appear on an ordinary
  chat.
- **The Project store's location.** The resolver reads the Project store at the
  target's Project root (`TrustInspection.projectDir`): a linked worktree
  resolves its own `.pi/`, and a chat started in a subdirectory reads its
  worktree root's `.pi/` (decision 31). The runtime gives pi that root as the
  Tron-patched SDK's `projectDir`, so pi loads the same settings, resources and
  MCP configuration under the root's trust while the chat keeps its own cwd, tools
  and instruction hierarchy (#864, Gateway README "Project root" and
  "Tron-patched `pi-coding-agent`").
- **Model queues.** `model.queue[role=…]` values are ordered `provider/id`
  lists. Their list kind keeps the generic list editor, and their
  `catalog.models` options source (physical models only) lets that editor add
  from the shared model picker ([6.3](#63-model-fallback-queues)).

### 4.4 What stays outside the schema

- pi exposes a TypeScript `Settings` interface but no runtime schema. Its docs
  state allowed layers for a few keys (`defaultProjectTrust`, `httpProxy` and
  `cacheWarming` are agent-directory only); the schema encodes those once.
- The former per-key setters (`session.setModel`, `setThinking`,
  `setContextWindow`, `setTools`, `trust.set`, `settings.update`) and the
  `SettingsService` validators are gone; their owners are appliers behind
  `settings.change` ([5.3a](#53a-implemented-the-change-path)).
- MCP (`mcp.*`) and Accounts flows (`auth.*`, `connections.setup.*`,
  `models.custom.*`) keep their own RPCs as guided flows
  ([7.6](#76-hand-built-screens)). Credential values are never recorded.

## 5. Changes, the record and policy

### 5.1 One path for every actor

| Actor | How it asks | Identity recorded |
|---|---|---|
| The maintainer on iPhone | `settings.change` from a row | Paired device id. The tap is the approval. |
| Home | The `settings` tool | Home session and chapter, plus the triggering message id. |
| A task worker | The `settings` tool, for every key whose `writers` include `worker`: the same keys as an agent ([decision 34](#81-decisions)) | The worker session and the task id. |
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

Each change's outcome names its key, layer, status and tier, and the value at that
layer `before` and `after` the change (`null` when unset there); a redacted key
reports only `redacted: true`, as its record does. The `settings` tool's result
carries the outcome, so its transcript detail shows old → new without a second read.

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
**kept forever** ([decision 12](#81-decisions)). It is split into closed
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
  **Not undoable** ([Q19](#81-decisions)).
- **Apply again** writes a logged value back after an outside change replaced
  or removed it ([5.6](#56-outside-changes)), with `applyAgainOf`. It is only
  ever offered, never automatic (F2).

### 5.3a Implemented: the change path

Slice 4 (#762) implements 5.1 to 5.3 and 5.7 for the iPhone actor:
`SettingsChangePath` (`packages/gateway/src/admin/settings-model.ts`), the record
(`settings-record.ts`) and the Project applier (`project-settings-writer.ts`);
the Gateway README has the RPC contract. What the code fixes that the sections
above leave open:

- **Record layout.** `<tronHome>/gateway/settings/changes/` holds append-only
  segments of at most 500 entries, named in `index.json`. A page of
  `settings.history` reads at most one segment per request, even for sparse
  filters. A page may be empty and still carry `nextCursor`; consumers continue
  until that cursor is absent, not until an empty page. The real Gateway journey
  in `settings-change.integration.test.ts` traverses empty filtered pages to an
  older matching change without skipping or duplicating it.
- **One target per request.** A request's changes share a target; a target with
  several layers (a project has Project and Mac) gives the cross-store order and
  rollback. Changes serialize per target, so distinct chats change concurrently.
- **The Chat layer's fence.** A Chat-layer change carries `fence: {
  runtimeGeneration, model?, revision? }`, the runtime the client read, and the
  slot lane's existing guards check it; `expected` is the value check for every
  other store.
- **Per-model compaction overrides.** Qualified and plain candidates are combined within each scope before scope precedence. Session reserve/keep-recent overrides beat Project and Mac per-model values. The compaction owner pins its resolved budgets into the SDK’s qualified and plain request settings, because the SDK’s internal qualified-first lookup must not reverse Tron’s scope-first decision.
- **Chat-layer appliers.** `tron.settings.v1` holds a chat's explicit Run and
  compaction values. Run keys reach the SDK at each idle request admission
  (`RuntimeSlot.applyLiveRunSettings`); compaction keys reach it through the
  session's `CompactionOperationPolicy`, which overlays the chat's values on the
  Project and Mac stores at every refresh and applies the budgets at the next
  idle admission, so a summary already prepared is never changed. The summary
  thinking level stays Project/Mac. Home keeps its own history with SDK
  compaction off, so a Home Chat compaction value is refused as unsupported
  rather than shown as effective. A key whose Chat binding has no such owner is
  refused the same way.
- **Keys with no writer.** `setup.sessionDir` declares no writer: the runtime
  fixes its session folder under the ownership lock at start, so it changes only
  while the Gateway is stopped.
- **Applier results.** Trust's applier returns the resulting trust inspection;
  the change outcome carries it, and `trust.changed` broadcasts it.
- **Unparseable Project files.** A `.pi/settings.json` that cannot be parsed is an
  unreadable, empty layer in `settings.resolve` (`projectUnreadable`), and a write
  to it is a `failed` entry with the file untouched.

Slice 5 enforces the tier ([5.4a](#54a-implemented-tiers-floors-and-the-web-mark)).

Undo conflicts return both the current and originally applied values, with display strings from the same schema formatter used for history. The native detail retains the historical diff and shows the current conflict separately; it must not fabricate a diff by expanding an error message or dismiss on a per-change refusal.

### 5.4 Tiers

F3 in full.

- **quiet**: apply and record.
- **notify**: apply, record, and push to the maintainer with an Undo.
- **approve**: hold until the maintainer taps Approve. A pending change expires after 24
  hours ([5.5](#55-approvals)).

The inputs:

1. **The floor.** Each key's floor per direction is in the schema. The maintainer may
   raise or lower any key's floor in Settings › Permissions
   ([decision 7](#81-decisions), [Q20](#81-decisions)), through the key
   `permissions.floor[key]`. Lowering is a widening of that key, so it needs his
   tap and is recorded. The default floors make widening a Permissions key, and
   adding credentials, `approve`; those are defaults like any other.
2. **The web step.** If the requesting turn read web or browser content, the
   tier rises one step: `quiet` to `notify`, `notify` to `approve`
   ([decision 6](#81-decisions), [Q21](#81-decisions)). It applies the same way
   in Home, ordinary chats and workers. The Gateway sets the mark per turn from
   the tool calls it executed, never from the model's own account. Whether a
   tool returns web or browser content is that tool's own declaration (web
   search and fetch, the browser, public-post readers), so a new web tool
   declares it and nothing here changes. The mark belongs to the tool call
   only: it does not travel with content another turn reads later, such as a
   worker's report or a Knowledge record ([decision 28](#81-decisions)).
3. **The risk model.** A decision model may raise the tier, never lower it. If
   it fails or times out, the computed tier stands.
4. **The maintainer's tap.** A change he makes from a row is approved by that tap. When
   its tier would be `approve` for anyone else, the row shows the key's
   `confirm` text first.

Each record entry names its floor and any override, so a lowered floor is
visible on every change it let through.

### 5.4a Implemented: tiers, floors and the web mark

Slice 5 (#763) implements 5.4 and 5.5 on the Gateway: the gate in
`SettingsChangePath` (`settings-model.ts`), pending requests in
`settings-approvals.ts`, and the `settings` tool and web mark in
`tron-settings-extension.ts` (the `tron-settings` module, loaded by every
session, Home included). The Gateway README has the RPC contract. What the code
fixes that 5.4 and 5.5 leave open:

- **The request's tier** is the highest tier of its changes; a request is held
  or applied whole, because it applies atomically (5.2).
- **The maintainer's own change** (`ui`) is applied at once at any tier, and its
  tier is recorded. He is not pushed about his own tap.
- **Floor overrides** are the key `permissions.floor`, qualified by the key and,
  for a key whose floor differs by direction, the direction; a key with one
  floor is overridden for both directions at once. The resolver lists them on the
  Mac target, each with its code floor as the built-in. Every record entry names
  the floor and whether it was the code floor or an override.
- **The web mark is per run**, from the prompt to the agent's final answer: what
  a tool returned stays in context for the rest of the run, so a later turn of
  the same run is marked too. The next run starts clean (decision 28). A tool
  marks the run unless it declares `annotations.openWorldHint: false` (Mohsin,
  2026-10-11); an undeclared tool is untrusted. The `tool_call` hook sets it
  before the call executes, nested codemode calls included. pi's own tools carry
  no annotations, so the module declares `read`, `edit`, `write`, `grep`,
  `find`, `ls`, `bash`, `codemode` and `tool_search` closed-world against their
  built-in source. `bash` is trusted ([decision 33](#81-decisions)): Tron
  passes pi's bash as its direct bash tool, so its source is `<sdk:bash>`, and
  no extension may register that name. Tron's tools declare it in their registrations; `web_search`,
  `web_fetch`, `computer` and the `knowledge` tool (its X, capture and Raindrop
  actions) declare `true`.
- **Pushes.** A notify-tier change by an agent queues an `explicit` push; a
  pending request queues a `waiting` push ("Approve or decline in Tron"). The
  iPhone decides it from the rows in Manage Home and Manage Session.
- **Approve and Decline on the push** ([decision 35](#81-decisions)). The
  waiting push asks the relay for the one allowlisted notification category,
  `settings-approval`, which the relay maps to `aps.category`; the iPhone
  registers that category with Approve and Decline. Both are foreground
  actions: the push carries neither the request id nor its digest, so a
  decision from the push alone could approve a newer request that superseded
  the one the push described. The action opens the requester's chat and its
  Manage sheet (Manage Home for Home's chat), and once the approvals are read
  the chosen decision is staged as a confirmation over the matching row, which
  shows the exact change: one more tap decides it through the row's
  digest-bound `settings.decide`. More than one waiting request from that chat
  leaves the rows to choose from; none says the change is no longer waiting. A
  relay refuses unknown fields, so the Gateway sends the category only to a
  relay that advertises it: before queuing the push it reads the relay's
  `GET /v3/capabilities`, and an older relay (404) gets the push without the
  field. The decision is fixed into the queued request, whose retries resend
  the same body. Deploy order: the push relay README's
  [category release](../../push-relay/README.md#notification-categories).
- **Approval binds to a digest** of the target and each change's instance,
  `before` and `after`. Approving re-plans each change with the recorded
  `before` as `expected`: a store that moved since supersedes the request. A
  newer request for any of the same key instances supersedes an open one at
  once. `superseded` is a record status of its own.
- **Expiry** is evaluated against the change path's clock whenever the path is
  used (a change, the open list, a decision, a requester's next run), so no timer
  runs; an expired request can never be approved.
- **The requester told.** The requester's next run that starts from a prompt
  carries one `tron.settings-outcome.v1` custom message, one line per declined,
  expired or superseded change, once. A Home wake starts its run from the task
  result alone, so Home hears it on the next maintainer message, as task results
  a wake could not take do.
- **A chat's own Chat layer** changes only while the chat is idle, so the tool
  refuses it during its own run; an approval later applies a pending Chat-layer
  change from the iPhone with the chat's fence.
- **Workers** are writers of every key agents may write: a key's `writers`
  list is the grant, with no per-task grant ([decision 34](#81-decisions)). A
  task worker is recorded as `worker` with its task id.
- **The iPhone's rows** read Gateway text only: `settings.approvals` gives each
  request's `requester` and each change's `label`, `display` strings, raw
  `before` and `after` and `confirm`; a dry run of the maintainer's own change
  returns an approve-tier change's `confirm` text for his row to show first.

### 5.4b Implemented: bounded risk assessment

Before applying a non-UI request, the gate may ask the configured Jev classifier
through `SettingsRiskEvaluator` and the existing typed decision adapter. UI taps
and dry-run validation do not dispatch it. An absent/unconfigured classifier,
failure or timeout leaves the deterministic tier intact. The gate always uses
`max(floor + web, assessment)`, including a floor the maintainer lowered; a
classifier can never grant approval.

A whole request shares a 1.5-second classification deadline. Each dispatch uses
the adapter's conservative 0.2688-cent ceiling; the existing 50-change bound
therefore caps the request at 13.44 cents. There is no retry, alternate provider,
or background classification after the gate. This is separate from task-budget
semantics. Deployment with a configured classifier enables this gate; these
changes do not configure credentials or alter any live installation.

Only schema key/layer, actor kind, effective floor/direction/web mark, a bounded
redacted reason and a lossy diff are disclosed. Secret-typed values are absent;
all other string/object values are withheld and arrays expose only cardinality.
No target object, credential store, transcript, actor IDs or full stores are read or attached.
Both tier and rationale are typed choices; audit records the returned tier,
fixed-vocabulary rationale and assessed/failed/timeout state in
`tierBasis.riskEvaluation`, never provider exception text.

The real Gateway/RuntimeRegistry settings-change journey proves a raise holds
the write pending approval, a lower answer preserves the maintainer's lowered
floor and web escalation, failure/timeout retain the base tier, UI and
a mixed bundle containing an unauthorized write does not dispatch at all, and value/reason secrets are withheld.
Its bounded transcript remains `test-results/settings-change.json`.

### 5.5 Approvals

Pending changes use the pattern of Home task grants (`home.decideTaskGrant`):

- a push with Approve and Decline;
- a **Pending approval** badge on the row and the pending item at the top of
  Changes ([7.4](#74-the-changes-feed));
- a decision RPC bound to the exact pending diff (no approve-then-swap).

A pending change **expires after 24 hours** ([decision 8](#81-decisions)). An
expired or declined change is never applied. **Whoever asked is told** on its
next turn: Home, an ordinary chat's agent, or a worker. That turn's context
carries one line per change it asked for that was declined or expired since
its last turn ([Q22](#81-decisions)), the way task results that miss a wake
reach Home today.

### 5.6 Outside changes

F2. The Gateway compares each store it resolves from with the record:

- the Mac `settings.json`, `models.json`, `mcp.json` and `trust.json`;
- each known project's `.pi/settings.json` and `.pi/mcp.json`, for every
  project with an open chat or a dashboard entry.

File events are lossy (editors rename-replace, events drop), so the comparison
rescans by content digest and treats events only as a prompt to rescan.

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
([Q25](#81-decisions)). A branch switch that carries the edit along changes no
value, so nothing is recorded beyond the badge the git state now gives
([5.7](#57-project-writes)).

### 5.6a Implemented: outside changes

`OutsideChanges` (`src/admin/settings-outside.ts`) owns comparison. It keeps the
per-key values Tron last observed in each compared store, with the change that
wrote each one, in `<tronHome>/gateway/settings/observed.json`; the record stays
audit only. Every settings read reconciles the target's stores first, and a
debounced directory event (Mac agent directory, each known project's `.pi/`)
prompts the same comparison, so neither a dropped event nor a rename-replace hides
a change. The provider-request boundary reads values only. Compared stores are the
Mac `settings.json` and `trust.json` and each known project's `.pi/settings.json`
(projects whose settings were read, at most 64), plus the Mac `mcp.json` and
`models.json` and each known project's `.pi/mcp.json`. Those two files are not
settings keys: MCP servers and custom model providers keep their own owners and
hand-built editors ([7.6](#76-hand-built-screens)). They are compared per **record
subject** (`RECORD_SUBJECTS` in `settings-schema.ts`): one instance per MCP server
(`tools.mcp.server`, qualified by `server`) or per provider
(`accounts.models.provider`, qualified by `provider`), by digest only, because a
definition can carry headers, keys or commands. An outside entry for a subject
records the file, the name and whether it was added, changed or removed (never
the definition), takes the subject's code floor (`notify`: decision 13), pushes,
broadcasts `settings.changed`, and refreshes its owner's surface: `mcp.changed`
with the scope (`global`, or `project` and its root) for the MCP screen, and
`models.customChanged` for the custom-model editor. A project's `.pi/mcp.json`
follows the Project root like `.pi/settings.json`, whatever subdirectory a chat
runs in; MCP definitions load at the next reload or chat and custom models at the
next Gateway start, as for Tron's own edits. Tron's own MCP and custom-model
writes go through `OutsideChanges.adopt`, so they are never outside changes:
it first records any outside difference already present, then holds the store
while the owner writes (an outside edit made during that write itself is adopted
with it). Tron's change-path writers enter the same hold under the comparison's
lock, so a comparison already reading a store finishes before Tron writes it. A
project whose `.pi/` appears later is watched through its root until it exists,
then directly.
Subject floors are not overridable: they are not keys.

- A store's first sight is its baseline. Afterwards each differing key instance is
  one `outside` entry (actor `outside`, the file as its id, the target `mac` or the
  project, `HEAD` and branch for a repository file). Redacted keys are compared by
  digest and recorded as changed only.
- Tron's writers bracket the store: the change path and the package owner call
  `begin` before writing and `end` after, so a comparison never reads a half-written
  Tron change and Tron's value is adopted with its change id. A planned write that
  did not land (rolled back) is adopted silently; any other difference found then
  is still an outside change.
- An outside entry that replaced or removed a value Tron wrote refers to that
  change (`refersTo`); its row badge `Changed outside Tron` then carries the Apply
  again action with the entry id. `settings.applyAgain` writes Tron's value back
  as an ordinary change with `applyAgainOf`, expecting the outside value, so a
  newer change refuses it.
- The tier is the key's floor for the change's direction and decides only the
  push ("Changed outside Tron"), listing only the keys whose tier is not quiet.
  After-apply effects and the `settings.changed` broadcast are the same as for
  any change. The risk model is not consulted: an outside change has no requester
  to disclose.
- Project rows carry their git state from `HEAD`, the index and the working file:
  no extra badge when the value matches `HEAD`, otherwise `Staged` or
  `Uncommitted`, and `Local only` outside a repository or for an ignored `.pi/`.
  When `HEAD` holds the blob Tron staged, `committed` with the commit is appended
  to that change.

The real-boundary journey is the `outside changes` block of
`src/admin/settings-change.integration.test.ts`: Mac hand edits (one entry per
key, no echo of Tron's write, rename-replace, redaction, Apply again and its stale
refusal), a file event alone with quiet versus notify pushes, and a temp
repository through staged, committed, unstaged, stash, restore, a carrying and a
dropping branch switch, and a fast-forward pull. Its `outside changes to MCP servers and custom models` block has three
journeys, each with its own fixture: global Mac `mcp.json`, Project `mcp.json`,
and custom models. They drive the production MCP owner over the bundled pi CLI.
Tron's own `mcp.add` and `models.custom.put` record nothing; a hand-edited Mac
`mcp.json` (file event alone) and `models.json` record one digest-only entry each
with a push and the owner's refresh event; a pulled project `.pi/mcp.json` is
recorded against the root with its commit while the chat keeps its subdirectory
cwd.

Fixture ownership: every case runs through `caseIt` or `caseEach`. The test's
own body is registered with its owner, so afterEach joins it even when vitest
has moved on. Each owner (bodies, roots, registries, outside watchers) belongs
to one case: afterEach tears down every owner the test created, including one
whose test failed before it disposed it, and no other case's teardown can reach
them. A teardown joins its owner's bodies first, then disposes its registries and
outside watchers, then removes its roots. It reads the owner's resources only
after the join, because a body registers fixtures as it runs, and a body that
outlives teardown's start can still register one. A failed body is reported
through the teardown's `AggregateError` with its original cause, and its root is
still removed, since the body has settled. A failed registry or outside disposal
is also reported, and it keeps and names its roots, because a runtime that did
not stop may still write there. The disposal control proves this at a real
boundary: an idle slot's run marker (`<tronHome>/gateway/runtime-markers/`, a
gateway-owned persisted path) is replaced by a non-empty directory, so the
slot's real shutdown fails with `EISDIR`; the test repairs it and disposes the
registry before removing the root. The MCP journeys need no environment pin: the
bundled CLI receives the service's own agent directory on every spawn (#1274).

Remaining limits: a body still running past the afterEach hook timeout is joined
only once it settles, so the hook is what bounds it. The every-key matrix retains
its existing explicit 60 s per-layer budget through the ownership wrapper; the
three split MCP/models journeys retain the original 15 s default. A focused real
runner qualification with a shorter default (`--testTimeout=100`) detects a
wrapper that drops the matrix's explicit timeout; it does not raise a budget.
Production retirement: `OutsideChanges.dispose()` closes file watches and queued
debounces, then joins accepted reconciliations through their awaited observers,
not only the store mutex. An observer may resolve settings again while draining;
new comparisons and watch starts are refused after retirement. Concurrent
comparison failures are collected only after all accepted work settles, retaining
the original causes. The real directory-watch journey holds both a store read
and observer publication across disposal; a second journey holds two observers,
causes a real `EISDIR` in one and proves the other still settles before disposal
reports that failure. These controls add no timeout or separate fixture owner.

The Gateway awaits this retirement after its existing accepted-work settlement
and before notification/runtime retirement. `gateway.shutdown-step` with
`step=outside-settings-dispose` attributes its elapsed time; comparison failures
continue through `settings.outside.failed` and shutdown failures through
`gateway.shutdown-failed`. Accepted mutation writes remain owned by their existing
request/command settlement, not by the outside-comparison queue. This is a
file-watch/observer qualification, not a natural-load reproduction of the
historical timeout or an exhaustive whole-Gateway shutdown qualification.

### 5.7 Project writes

[Decision 14](#81-decisions): Tron edits a repo's `.pi/` files and stages them.
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
   not staged ([Q27](#81-decisions)); the entry records why.
5. If the staged path, or the index, also holds changes Tron did not write,
   stage anyway and warn in the Changes entry. That includes the
   maintainer's own unstaged edits in the same file
   ([Q26](#81-decisions), [decision 29](#81-decisions)).
6. Record the entry: the repo root, the path, staged or not and why, and the
   staged blob id.

The value applies from the working tree under the key's usual timing, whether
or not it is staged. Staging is not a pending state.

**Badges come from the store's git state**, computed by the resolver:

| Store state | Badge |
|---|---|
| Value matches `HEAD` | Project |
| Differs from `HEAD`, staged | Project · Staged |
| Differs from `HEAD`, not staged (unstaged by the maintainer, or never staged) | Project · Uncommitted ([Q24](#81-decisions)) |
| No repository, or `.pi/` ignored | Project · Local only |
| Value differs from the last logged value | Changed outside Tron, with Apply again where it removed Tron's value |

Committing appends `committed` with the commit id to the original entry, and
the badge drops to Project. Unstaging keeps the value, so it is not an outside
change; the badge becomes Uncommitted.

## 6. The Home profile layer

### 6.1 What it is

Home is a distinct durable assistant profile, not a default layer for ordinary sessions. Its typed settings and learned notes have different owners:

- **Typed values.** Schema keys whose allowed layers include `profile`: the
  chat model/thinking, curated tools, model fallback queues, worker thinking and task budgets. Task scopes have their own authorization owner. Typed settings
  resolve like any layer value, show a **Home profile** badge, and go through
  the change path.
- **Instructions and learned notes.** The Knowledge-backed learned profile owned
  by #734 (`packages/gateway/src/home/home-profile.ts`). Notes may explain *why*
  a value is set. They never carry the value. A `delegation-default` note that
  names a model is advice to Home; it is not resolved, and the typed key wins.

The typed profile store is `<tronHome>/gateway/home/profile.json`. The settings
change path updates it with a locked JSON write; resolution validates each
schema-declared Profile binding before exposing it. The document is capped at
256 KiB. Undeclared fields do not resolve as settings and are preserved when a
declared field is changed.

Initial designation without an explicit model retains the runtime’s resolved
Profile > Mac > Built-in choice and its launch source; the designation fallback
must not overwrite it. An explicit designation choice is a Session override even
when it equals the profile default. Creation-time Home uses Home scope before
its record is committed, so startup provenance cannot be misattributed to Mac.
Later profile edits do not rewrite the current chapter; an explicit Session reset
adopts the current profile default. `settings-gate.e2e.test.ts` covers all three
initial choices and the audited reset without migrating existing values.

This slice supports writing the schema keys already bound to the `profile`
store. Home's memory has no model key of its own: it runs on the background
model queue ([6.3](#63-model-fallback-queues)). A `memory.model` field left in an
older `profile.json` is undeclared and never resolves.

Task budgets are the key `permissions.budget.task` (Profile only, built in as no
limit). Its value is `{ inputTokens?, outputTokens? }`: the task record's own
spend counters (the input limit caps the prompt total, cache read and write
included), the only spend Tron measures (home.md Spend; provider cost is not
authoritative). It renders with the generic numeric-map editor. A field rising or
being removed widens (floor approve: Home's raise waits for the maintainer's tap);
setting or lowering one narrows (quiet). Timing is narrow live, widen fixed: a task
fixes the budget at admission, a later lower reaches it at its next turn boundary,
a later raise only reaches later tasks. Reaching it ends the task `limited` with
reason `budget` (home.md Budget); `home-task-worker-model.e2e.test.ts` covers the
stop, the unbudgeted control, a live lower, a raise that does not reach a running
task, and Home's gated raise. Task scopes stay owned by Home's task
authorization store and its grant/revoke controls (home.md); they are not a
schema key. Delegation-time worker resolution, fieldwise
explicit choices, capability clamping, queue skips and fixed Chat provenance are
implemented at the Home delegate/dispatcher boundary, independently of the
Profile store. The real `home-task-worker-model.e2e.test.ts` covers these paths,
including a retained explicit thinking field, ordinary Project-default control
and a later Home change leaving the first worker unchanged.

### 6.2 Who it applies to

Only the Home chat has a profile store, so only the Home chat has the layer
([3.3](#33-which-layers-a-target-has), [decision 2](#81-decisions)). Workers get
profile-derived values only because Home resolves them and passes them in its
`delegate` call ([6.3](#63-model-fallback-queues)). Home-only keys
(`model.thinking[role=worker]`, `permissions.budget.task`) have Profile as their
highest allowed layer; the model queues also have a Mac layer.

### 6.3 Model fallback queues

Three keys hold ordered model lists, first choice first, as `provider/id`
strings. Each has Profile and Mac defaults and a built-in empty list. Ordinary
sessions and Knowledge resolve **Mac > Built-in**, never Home. Home delegation
and memory resolve **Profile > Mac > Built-in**. At task admission Home copies
the worker and subagent queues into canonical Session launch inputs, with
`from: delegate`, `via: home-profile` provenance. These inputs are read-only in
the app and through the settings tool, survive rehydration, and outrank later
Mac defaults. Neither audit history nor the current Home profile reconstructs them:

| Key | Runs | Empty means |
|---|---|---|
| `model.queue[role=worker]` | Home task workers | Home's own model ("same as Home") |
| `model.queue[role=subagent]` | managed subagent children of Gateway sessions | each agent's own model |
| `model.queue[role=background]` | Home memory summarization and Knowledge calls | the subagent queue |

**Availability.** `ModelQueueOwner` (`src/providers/model-queue.ts`) answers,
for a role, each queue model with `available` or the reason it is skipped: not
registered, virtual, no credentials, a usage-limit error in the last 15
minutes, or a provider usage window at 95% or more in a fresh
`ProviderUsageOwner` read (the same 60-second cache Providers usage shows). A
stale or unknown usage read never skips a model; the error path catches a limit
the read could not see. When no model is available the owner refuses with one
error naming every model and its reason.

**Usage-limit errors.** A usage-limit error is Pi's non-retryable plan or quota
limit (for example `GoUsageLimitError`, `usage_limit_reached`) or a 429. Each
use retries the same request on the next available model:

- **Workers.** At delegation Home's `delegate` boundary takes the first available
  worker queue model (else Home's own model) and returns the worker queue's and
  subagent queue's availability to Home; the brief records both. A worker
  session runs the queue extension (`src/providers/model-queue-extension.ts`):
  when a run settles on a usage-limit error, the failed request is omitted from
  context as Pi omits a retried attempt, the session moves to the next available
  model, and the run continues. A `tron.model-queue` entry records each skip.
- **Subagents.** The subagent queue is one selectable virtual model,
  `tron/subagent` ("Subagent models"), which routes each request to the first
  available subagent queue model (a tool follow-up stays on the model that
  answered while it is usable). Every non-Home session lists it, and registers
  the same extension as a host-required child extension of the managed
  pi-subagents provider, so every child launched on `tron/subagent` (foreground
  or detached) moves along the queue on a usage-limit error. pi-subagents
  verifies the virtual selection, so the physical model may change under it. A
  ordinary child reads the Gateway's Mac-only projection
  (`<tronHome>/gateway/model-queue.json`). A Home task child instead receives a
  host-required module bound to that exact parent session's captured queue
  projection (`<tronHome>/gateway/model-queue-sessions/<session-hash>.json` and
  its sibling `.json.ts` module). This binding works for foreground children
  sharing the Gateway process and detached children without process-global
  environment changes. The parent rebinds required child policy from canonical
  launch evidence immediately before each launch, including after a completed
  worker cold-opens as an ordinary session. The module and JSON publish atomically
  in the same serialized owner; only the selected queue’s unavailable model
  identities are projected, never unrelated Home/worker failure history.
  Publication is refreshed before each top-level launch and after each recorded
  failure, and fails closed before
  launch if it cannot publish. The session owner joins publication before
  removing both exact files at shutdown. Children also retain their own observed
  failures; projected usage skips expire after 10 minutes. A subagent
  launched on an explicit physical model keeps that model. The worker brief presents
  the queue as the default, not an override of an explicit eligible subagent model
  named by the brief. The worker must pass that physical choice and disclose any
  fallback and its eligibility/usage-limit reason. No global queue/profile change
  is needed to honor a task-specific choice.
- **Background.** Home memory's compactor explicitly selects Home's profile
  queue; Knowledge's observer and model calls select the Mac queue. Both go
  through `ModelQueueOwner.complete`, which retries on the next model
  and records the skip (`model-queue.skip` in the Gateway log).

With no model left, the run ends on its error with a visible message naming
every queue model and why it was skipped.

Worker thinking stays `model.thinking[role=worker]`, built in as
`{ "sameAs": "home" }`. At delegation the call's own `model` or `thinking` wins
field by field ([decision 5](#81-decisions)) and needs a short reason; otherwise
the queue model and the profile thinking (or Home's) apply, and thinking is
clamped to the model's supported levels ([3.6](#36-capability-constrained-values),
[Q23](#81-decisions)). The filled call goes through task admission
(`home-task-worker-choice.ts`) and is written into the worker's Chat layer with
provenance (`home-profile` for a queue model, `home-profile:sameAs:home`,
`home-explicit`). Changing Home's model or a queue later does not change a
running worker's start choice or fallback queue, nor the queues of its future
children. Availability and observed usage-limit skips remain live within those
captured queues. A legacy worker without captured queue evidence uses ordinary
Mac defaults; it never acquires current Home settings implicitly.

Manage Home shows the three queue rows in its model card; the shared list
editor adds a model from the shared model picker, moves a row earlier or later,
and saves the ordered list through the change path.
`home-task-worker-model.e2e.test.ts` covers worker skips, refusal, in-session
fallback and memory fallback; `home-task-subagents-model-queue.e2e.test.ts`
covers foreground and detached managed children, explicit physical selections,
Home-profile changes after task admission, a completed worker’s real child request
after Gateway restart, an ordinary Mac-only control, projection data minimization,
canonical launch-origin inspection, and success/failure projection-file cleanup.

### 6.4 Learned-profile changes

The learned profile (6.1, second part) is not a key: its store is Knowledge, and an
item never resolves as a setting. Its changes still take this document's one path,
so they are logged, shown and undone like any other change.

- **One implementation.** Home's `profile` tool and the maintainer's
  `home.profileChange` both call `SettingsChangePath.changeProfile`, which applies
  ops with `HomeProfileItems` (`home-profile.ts`) under the Home target's lock. The
  actor decides only confirmation: Home writes inferred items, and the maintainer's
  tap writes confirmed ones (`confirmedByUser`).
- **The record.** Each note a change touches is one entry: key `home.profile.item`,
  qualifier `note`, target `home`, layer `profile`. Its `before` and `after` are the
  item's value `{ kind, text, confirmed, state, revisionId, supersedes?,
  supersededBy? }`; a note that did not exist has none. The entries of one change share
  `group: { id, size }`, for example both notes of a supersede or every item of a
  Confirm all. The subject's floor is quiet. Home's run web mark raises it one step,
  so a profile change after open-world content pushes "Undo it in Tron". The risk
  model is not consulted, because an item stays inferred until the maintainer
  confirms it.
- **Undo.** `settings.undo` of a profile entry reverts its whole group, restoring
  each note to its `before`: text, kind, confirmation, retirement and its
  `supersedes` relation. A note that did not exist is retired. Undo is refused with
  `conflict` and `{ current, after, display }` unless every note still equals its
  recorded `after`. Clearing retirement uses Knowledge's `retired: false` draft
  (knowledge.md), which is never stored.
- **Concurrency.** Every maintainer op names the revision he read. A note Home changed
  since is refused with the item as it now stands, never overwritten. Knowledge's
  revision fence also covers the race between Home's read and its write.
- **Not recorded.** A native Knowledge note edit stays the Knowledge owner's. It is
  not a profile change, and no outside-change comparison runs for notes (F2's
  outside detection covers settings files only).

The real-Gateway journey is `src/sessions/home-profile.integration.test.ts`
(F11–F13): maintainer confirm, refine with a kind change, supersede, retire and
their undos over RPC, Changes entries, the stale-edit and stale-undo conflicts, and
the next activation's profile section.

## 7. Presentation and the rendering contract

### 7.1 Posture: calm by default, everything on demand

The maintainer is a power user who must be **able** to see and change every setting,
but ideally rarely needs to. Agents manage settings for projects and sessions;
he checks the few things that carry signal. So every surface opens calm, with
one line describing each section, and the section's full key list is one step
away. Nothing is hidden: every key is on its section's sheet. What needs him
(approvals, agents' changes) is in Changes ([7.4](#74-the-changes-feed)).

Everything a surface shows (a section's words, which badges a row carries, what
a value reads as) comes from the schema and resolver output. iOS decides layout
and style, never meaning.

### 7.2 Sections

Every settings surface uses the Gateway's sections: **Model, Workers &
delegation, Compaction, Tools, Connection, Advanced**, followed by supply/device
sections where applicable. `settings.resolve` serves
`{ id, title, description, order, note?, chatInline? }` for sections with keys.
Model and Workers & delegation declare `chatInline: true`; Home/Chat Settings
show those cards after Changes and collect the remaining destinations into one
card of progressive-sheet links with short summary values. Mac and Project
Settings use the same section titles/membership behind their existing links.

The Settings shell retains Accounts, Agent, Tools & Extensions, This iPhone,
and Tools & Diagnostics. Agent contains Model, Workers & delegation, Compaction,
Connection and Advanced; Tools stays in Tools & Extensions. An unplaced section
joins More. The Project card keeps trust review and its project-owned resources.

Within a section, rows follow Gateway order. Related single-instance values
share the main card; a multi-row subgroup may have its own heading. Importance
never creates another one-row Advanced card, and a subgroup matching its section
title is merged into that section. Many instances of one key still open their
existing editor. Values open their controls directly, never a per-key intermediate
sheet. Owned overrides expose the shared compact reset action, submitting an
unset through preview/confirmation/receipts rather than inventing a default.

String-list values show counts, model queues show `1 model` / `N models` when
configured, and active tools show `1 tool` / `N tools`. Empty queues keep their
inheritance meaning. Typed values and full order remain in the list/tool editor;
history still uses the full formatter. Fixed-source chips name only their source
(e.g. From Home at start); the full formatted value and reason remain in the
badge detail, available through the row's information/context menu.

All surfaces for a target share one resolution/options snapshot. Opening a
section never re-reads a fresh snapshot just because it is a new presentation.
Nothing expands in place.

### 7.3 Badges

One badge component. The resolver returns each row's badges as
`{ kind, label, detail?, action? }`; iOS maps `kind` to a style, and an unknown
kind renders as a neutral badge with its label.

| Kind | Labels |
|---|---|
| Layer | Where the value comes from: Set in this chat, Set in Home profile, Set in project, Set on Mac, Tron default (`LAYER_SOURCE_LABELS`; `LAYER_LABELS` names the layer itself in sentences and the Changes feed) |
| Source | Chosen for this chat; From Mac default / project default / Home profile / Tron default at start; From Home at start |
| Scope | The qualifier: a provider, tool or project; a per-model value reads "For <model display name>" with the `provider/id` as its detail |
| Authority | Who last changed it: You, Home, a named chat or worker, Outside Tron |
| State | Staged, Uncommitted, Local only, Changed outside Tron, Pending approval, Not undoable, Not applied (untrusted), Clamped, Applies after restart |

Scope, source, authority, timing and state are badges, never groups (F1). A
badge's `action` is a change the resolver offers (Apply again, Use the current
default, Follow the default, Review trust), sent back through
`settings.change`.

### 7.4 The Changes feed

Changes is the main place to check up on agents. It reads the record
([5.2](#52-the-request-and-the-record)) through `settings.history`. The Gateway
adds `presentation: { label, section?, actor, layer, display: { before, after } }`
to each page entry using the schema's existing formatter, without writing the
projection to audit. Retired keys show their ID and recorded JSON; redacted values
show Hidden → Changed and are removed from the response's raw value fields.

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
  started). iOS implements these entry points in `SettingsChangesView`; local
  lineage filtering is applied to each bounded `settings.history` page, without
  changing the Gateway's canonical audit or pagination contract. The native
  surface offers Undo, Apply again on an outside entry that replaced Tron's
  value, and pending approval decisions.

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
| `list` | A list of a primitive, with add and remove; items keep their order | search paths, `enabledModels` |
| `checklist` | Several choices from a served option source, saved together | tools |
| `catalog` | A searchable picker over a Gateway-served catalog | model, providers, projects |
| `readOnly` | The `display` string | anything a client cannot edit |

**Schema fields for presentation** are in [4.1](#41-fields): section, subgroup,
order, importance, label, help, unit and format, control and fallback, confirm.
Every resolved value carries its Gateway-formatted `display`, so any client can
show any key without understanding its type.

**Dynamic options are served.** A key with an `optionsSource` gets its options
from `settings.options { key, target, qualifiers }`: each option has a value,
label, detail and an optional disabled reason. `catalog.tools` choices also carry
`resource`, the serializable tool record (description, parameter schema and
origin metadata) used by Settings and Manage Session's shared tool list/detail
presentation. The schema names the keys a
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

### 7.5a Implemented: the renderer contract

Slice 14 (#780) serves the contract above. The Gateway half is
`settings-presentation.ts` beside the resolver, `SettingsModel.options` and the
two RPCs (the Gateway README has the shapes). What the code fixes that 7.2 and
7.5 leave open:

- **Presentation is per instance.** Every resolved key instance carries its
  key's `presentation`, read from the schema with no per-key code; the
  negotiated `control` and its `note` are the only per-client fields.
- **No renderer, no controls.** A client that sends no `renderer` is treated as
  implementing no control: every editable key is read-only with "Update Tron to
  edit", and every value still arrives with its `display`.
- **The iPhone half** is `SettingsRendererView` (iOS architecture, presentation
  parity). It implements `toggle`, `choice`, `number`, `text`, `secret`, `list`,
  `checklist`, `catalog` and `readOnly`. Secret entry is write-only and never
  prefilled; string lists support add and remove; a checklist saves its chosen
  set from the toolbar. Unknown list item
  kinds remain visible read-only. Ordered choices reuse the app's existing anchored
  slider through `SettingsChoiceSlider`; bounded integer numbers use
  `SettingsNumberSlider` with the served range, unit and step. A dynamic range
  replaces the static declaration; unsupported numeric representations remain
  visible read-only. Legacy thinking rows use the shared choice primitive;
  context-window rows use the shared number primitive with a reference value,
  preserving continuous detents and inheritance reset without a second editor.
  Catalog rows mark the current value with the standard checkmark. Model keys
  (`catalog.models`) open the app's shared `ModelPicker`, limited to the models
  the Gateway serves for the key (`SettingsRendererRow.swift`), and every served
  choice option carries a `detail` line. Options reads
  carry managed presentation activity and an exact request fence through both
  success and failure publication; changing a dependency clears old choices before
  fetching replacements.
- **A dynamic source wins over static choices.** A key with both (the chat's
  thinking) serves its source's options from `settings.options`; the static
  list stays in `presentation.options`. A model without reasoning offers no
  thinking options.

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

`AgentConfigurationControls` is not a hand-built exception: its rows use the
`catalog`, `choice` and `number` primitives. Mac defaults and compaction now use
the generic renderer in Settings. Thinking and context-window adapters already use the shared
`SettingsChoiceSlider.swift` and `SettingsNumberSlider.swift` row/editor owners;
the former dedicated context-window editor is removed.

### 7.7 Surfaces

The shared schema renderer is projected by scope; a surface does not invent a key, value, editor or second store. `editableLayers`, `timing` and `effect` are Gateway key metadata. Native selection only filters this projection.

| Surface | Writes | Inspection |
|---|---|---|
| **Global Settings** | Mac defaults and machine integrations; iPhone preferences keep their existing local owners | Full audit history; Home and Project are not alternate edit modes. |
| **Session Settings**, from Manage Session | This session’s allowed Chat layer only | Effective essentials first; **Effective Configuration** inspects all supported values/sources, **Session Overrides** lists explicit overrides only, and **Launch Inputs** distinguishes retained default/delegation snapshots and unattributed legacy session values. |
| **Home Settings**, from Manage Home | Durable `profile` values only | Current chapter Effective Configuration and Launch Inputs are distinct from profile editing. Profile Overrides shows actual typed profile fields. Non-profile-editable keys are not redirected to the chapter or Mac. |
| **Project Settings**, from dashboard, Manage Session or New Session | None | Trust/Git state and actual `.pi/` overrides only. No inherited Mac/Built-in row masquerades as repository configuration; unapplied untrusted values remain inspectable. No trust editor, package/MCP mutation destination, cross-scope editor, Undo or Apply again. Logged agent Project writes and approval of those requests remain supported. |
| **Changes** | Existing scope-authorized approval and receipt-bound undo/apply-again actions, never values for resolution | One audit history, initially contextual when entered from a scope, with an explicit **All scopes** option. Context matches target/layer, not an actor’s unrelated activity. Repository entries are inspection-only even after switching to All scopes. |

Reset removes the owned override; it never copies an inherited effective value into the current scope. Compact round reset actions remain beside controls. Source inspection shows effective value, ordered candidate layers, unapplied reasons, retained launch evidence and application boundary. No “Edit at Mac/Project” mutation escape remains in a read-only projection.

Older session/chapter choices are preserved. Where canonical fixed provenance proves a launch snapshot, `origin` is `launch`; explicit fixed Chat choices and `tron.settings.v1` values are `override`; retained Chat values without attributable provenance are `legacy-session`; lower-scope effective values are `inherited`. History is never mined to invent provenance, and retained chapter choices are never silently migrated to Home profile.

### 7.8 Stress tests for rendering

| Case | What changes | Expected iOS change |
|---|---|---|
| A new model with a new reasoning knob (say `effortCurve`, low to max) | A schema entry `model.effortCurve[model]` in Model, control `choice` (ordered), `optionsSource: catalog.effortLevels(model)`, `importance: advanced`. The catalog declares support. | **None.** The row appears for models that declare it and nowhere else. |
| The same knob needs a control iOS lacks (a two-axis budget) | The entry declares `control: "budgetPlane", fallback: "number"` and a new renderer version. | **None to keep working**: current apps get the `number` fallback (or `readOnly` with `display`). A later app release adds the richer control. |
| A new feature group (for example a Scheduling subgroup in Run, or a new section) | Schema entries with a new `subgroup`, or a declared section with title and order. | **None.** Sections and subgroups are schema data. |
| A new layer value source (for example a workspace profile, or an org policy file at the Mac layer) | A new store bound in the schema and a new layer id in the resolver, with its badge label and the surface that edits it (if any). | **None to show it**: the badge is neutral-styled with the Gateway's label, and rows remain read-only unless the surface owns an allowed editable layer. A new editing surface would be a new screen, only if the maintainer wants one. |
| An old iOS app talking to a newer Gateway | Newer controls, badge kinds, sections and fields. | **None.** Negotiation sends fallbacks or `readOnly`; unknown badges are neutral; unknown fields are ignored; every value still shows. |

### 7.9 Each duplicate resolved to one editor

The executable inventory remains `settings-schema.ts:KEYS`, not a second native
key list. Model, Context, Tools, Permissions and Run values use the generic
primitive appropriate to their served type; thinking-token budgets now serve a
`numberMap` list with field labels and a shared numeric range. Unknown fields
are refused rather than silently erasing the current map. This is the existing
thinking-token budget contract, not the undefined task-budget proposal.
Mac and Project package values retain source/reset rows while their existing
scoped package owner supplies the sole editor; Project also retains its Hooks
inventory. `setup.sessionDir` remains intentionally read-only (no admitted
writer). Role-aware Chat model/thinking/context controls retain the shared
receipt/revision adapter, while the generic rows own provenance and resets.
No independent native key vocabulary or raw-JSON editing escape hatch is added.

| Audit | Today | One key, one editor per layer |
|---|---|---|
| D1. Model and thinking in six places, with three meanings | Manage Session, Agent Defaults (global or project), New Session, Manage Home chat model, Home memory model, `delegate` arguments | `model.ref` and `model.thinking`, by role. Chat in Manage Session and Manage Home (and New Session at creation), Project in the Project card, Mac in Settings › Model. The worker and memory roles in Manage Home (Profile). `delegate` arguments are turn-level inputs. |
| D2. Three controls called "Thinking" | Chat thinking, default thinking, compaction "Summary Thinking" | One key, `model.thinking`, with roles: "Thinking", "Worker thinking" and "Summary thinking", all in Model, each badged with its layer. |
| D3. "Project Trust" with three meanings | Settings › Project Trust as the default policy (dashboard) or as this project's decision (chat) (`SettingsView.swift:99-107`), and the New Session trust prompt | `permissions.projectTrust[project]` in the Project card, prompted by New Session. `permissions.defaultProjectTrust` in Settings › Permissions. |
| D4. Resources with four truths (installed, search paths, loaded, delivered) | Extensions, Locations and Overrides, Project Resources, Agent Instructions | Sources: installed and search paths, with where each came from. Context, Tools and Run show each contribution's chain. |
| D5. Context window | Manage Session slider (session entry) and Agent Defaults (`modelContextWindows`) | `model.contextWindow[model]`, one `number` control with a catalog range, edited at the surface's layer. |
| D6. Compaction shown read-only in a second place | Settings › Compaction edits, and its live policy is repeated read-only | Context › Compaction, generic rows at each surface's layer. |
| D7. Queue delivery | Long-press per message versus the `steeringMode` and `followUpMode` defaults | The long-press is a turn-level input and shows "Default: X (Mac)". The defaults are `run.queue.*`. |
| Untracked agent edits | Agents edit `settings.json` directly, and nothing records it | The `settings` tool through the change path. Direct edits are outside changes (F2). |

## 8. Decisions and open questions

### 8.1 Decisions

All decided by Mohsin on 2026-10-10. The foundations come first; every other
decision is listed with the foundation it follows from or the place it
refines. The sections above already reflect them.

**Foundations**

| # | Topic | Decision |
|---|---|---|
| F1 | Schema | Each setting is one key declared once on the Gateway (type, group, allowed layers, fixed at start or live, tier floor, redacted, validation, display metadata). iOS renders keys generically; hand-built screens only where a generic row cannot work. New models, features and keys need no iOS release ([1](#f1-schema), [4](#4-the-schema), [7](#7-presentation-and-the-rendering-contract)). |
| F2 | Truth | Each layer's store is the truth; the change log is audit and undo. A store that differs from the last logged value is an outside change with Apply again. No per-git-case rules ([1](#f2-truth), [5.6](#56-outside-changes)). |
| F3 | Policy | Tier = max(key floor, risk-model raise, one step up if the turn read web or browser content). No per-key exceptions. Trust, credential and budget raises default to a tap floor, which the maintainer can lower; lowering any floor needs his tap and is logged ([1](#f3-policy), [5.4](#54-tiers)). |
| F4 | Layers | Scope first: ordinary Session > Project `.pi/` > Mac > Built-in; Home Session/launch > Profile > Mac > Built-in. One resolver takes the top layer that has the key and is allowed to set it. "Mac only" and similar are schema data ([1](#f4-layers), [3](#3-layers-and-resolution)). |

**The first sixteen**

| # | Topic | Decision |
|---|---|---|
| 1 | Doc lifetime | It stays the reference. Migration and Slices were removed once every slice landed. |
| 2 | Home profile reach | Home only. Workers get profile-derived values because Home passes them in `delegate`; chats the maintainer starts never see the profile ([3.3](#33-which-layers-a-target-has), [6.2](#62-who-it-applies-to)). |
| 3 | Profile versus a repo's default for workers | Home's worker model beats a repo's `.pi/` default for workers Home starts there; the repo default still applies to chats the maintainer starts ([6.3](#63-model-fallback-queues)). |
| 4 | Worker thinking | Defaults to "same as Home" ([6.3](#63-model-fallback-queues)). |
| 5 | Explicit `delegate` choice | An explicit model or thinking level in the call beats "same as Home"; the brief records the choice and the reason. |
| 6 | Content escalation | Raises a change one tier, not straight to approval. Refined by F3 and Q20 (the tap for trust, credentials and budgets is a default floor) and Q21 (only web and browser content marks a turn) ([5.4](#54-tiers)). |
| 7 | Floors | Defined in code; the maintainer may raise or lower any floor, and lowering needs his tap and is logged. The risk model can only raise. Now part of F3. |
| 8 | Pending approvals | Expire after 24 hours. Extended by Q22: whoever asked is told on its next turn ([5.5](#55-approvals)). |
| 9 | Chat overrides for Run keys | A single chat may override any Run key and compaction: their allowed layers include Chat (F4). |
| 10 | Push policy placement | Under Setup ([2.2](#22-supply-and-non-harness-sections)). |
| 11 | Retry and transport | Under Run, with a per-provider qualifier ([2.1](#21-harness-groups)). |
| 12 | Record | Kept forever, with a full Changes feed that supports undo ([5.2](#52-the-request-and-the-record), [7.4](#74-the-changes-feed)). |
| 13 | Outside project changes | Notify only on permission-related `.pi/` changes after a pull (Permissions, Tools, hooks, Sources). Now a consequence of F3: an outside change's tier is its key's floor, and only `notify` or `approve` push ([5.6](#56-outside-changes)). |
| 14 | Project writes | Tron edits a repo's `.pi/` and stages it with `git add`; it never commits, pushes or opens a pull request. Refined by F2 and Q24 to Q27: the file on disk is the layer, and git state is a badge ([5.7](#57-project-writes)). |
| 15 | Image blocking timing | Turning blocking on applies at once; turning it off waits for the next chat start or an approval. Expressed as per-direction timing in the schema ([3.4](#34-timing)). |
| 16 | Landing | The maintainer-approved #758 integration branch preserves slice dependencies and lands only when all required acceptance is satisfied. It landed as #798 and #869. |

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

**Decided by Mohsin on 2026-10-11**

| # | Topic | Decision |
|---|---|---|
| 30 | Protocol version | #762 removed RPCs, so the Gateway protocol version moves to 8 with no compatibility shim: an older iPhone app is refused at hello with "update required". Landing needs the manual Mac-first reinstall the README describes for a protocol step. |
| 31 | Subdirectory chats (Q27) | The Project layer is the worktree root's `.pi/`, even for a chat started in a subdirectory. That changes what pi loads, so it is made deliberately with a test of its own; it is recorded on slice 6 (#764) and PR 798 ([4.3](#43-implemented-the-schema-and-the-resolver)). |
| 32 | The web mark | A tool that does not declare `annotations.openWorldHint: false` is untrusted: any call to a tool with the hint missing or true marks the turn (one step up). Built-in tools that are safe declare `false` explicitly ([5.4a](#54a-implemented-tiers-floors-and-the-web-mark)). |
| 33 | `bash` | `bash` is trusted: it does not mark the turn. Tron declares it `openWorldHint: false` on pi's behalf, as it does `read`, `edit` and `write` ([5.4a](#54a-implemented-tiers-floors-and-the-web-mark)). |
| 34 | What a task worker may change | The same settings an agent may. A key's `writers` list is the grant; there is no separate per-task grant ([4.1](#41-fields), [5.1](#51-one-path-for-every-actor)). |
| 35 | Approve and Decline on the push | The relay's notification request gains one optional, allowlisted `category`; its only value is `settings-approval`, sent only with the settings "Waiting for you" push, and the relay maps it to `aps.category`. The iPhone registers the category with Approve and Decline as foreground actions that open the matching approval row and stage the decision for one confirming tap. The relay is deployed before the Gateway sends the field: the Gateway sends it only to a relay that advertises it ([5.4a](#54a-implemented-tiers-floors-and-the-web-mark)). |

### 8.2 Open questions

None. A new question is added here only if it concerns a foundation; anything
else is answered by applying F1 to F4.
