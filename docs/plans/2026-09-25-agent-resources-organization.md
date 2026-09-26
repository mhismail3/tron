# Agent resources organization

- **Started:** 2026-09-25
- **Status:** Active
- **Last updated:** 2026-09-25, R-8; R-6 waits for the user's Gateway rebuild
- **Goal:** Settings shows what is installed in or configured on the agent, and the session sheet shows what the agent can use, each in exactly one logical place with a clear origin tag.

## Goal and constraints

The user's model separates two categories:

1. **Configured or installed:** what shapes the agent. This covers third-party
   extensions and packages, Tron's built-in modules, connections and MCP servers,
   hooks, agent definitions and defaults. It belongs in **Settings**.
2. **Available:** what the agent can use as a result. This covers skills,
   prompts, commands, tools, subagents and the assembled instructions. It
   belongs in **Manage Session → Project Resources**.

Rules that override an agent's own judgment:

- Nothing is lost. Every resource or configuration a sheet shows today must
  appear in exactly one place afterwards, and an audit lists each item's
  before and after location.
- Only the organization changes. No resource is added or removed, and nothing
  about installing, removing, trusting or reloading changes behavior.
- Follow the repository's standard components (settings rows, containers,
  sheets, tags) and the chat and settings UX rules in `AGENTS.md`. A new tag is
  one shared component, not per-sheet styling.
- Wire changes are additive: new fields on existing responses. No existing
  field changes meaning.

## Context

State on 2026-09-25 (inspected):

- **Manage Session** (`packages/ios-app/Sources/UI/Chat/SessionContextSheet.swift`)
  has rows for Agent Instructions, Project Resources
  (`ProjectResourcesView.swift`) and Project Hooks (`ProjectHooksView.swift`).
- **Project Resources** groups Prompts, Skills, Tools and Extensions, and reads
  `session.resources`, which `RuntimeSlot.resources()` builds
  (`packages/gateway/src/sessions/runtime-slot.ts`). That response already
  carries `tools`, `skills`, `prompts`, `commands`, `extensions`,
  `hookInventory` and `contextFiles`, each with Pi `sourceInfo` (scope, source
  and origin).
- **Settings → Tools & Extensions → Packages** (`PackagesSettingsView.swift`,
  `packages.list`) has a Global/Current project scope control, lists installed
  packages, and also lists resolved skills (a category-2 item).
- **Tron modules** are first-party extension factories registered in
  `RuntimeSlot` (tron-core, tron-ask-user, notify, display, native capture,
  computer, schedule, knowledge and Jev) plus MCP tools from Connections. No
  response lists them as installed modules.
- **Subagents** are discovered by the `pi-subagents` package from user
  (`~/.tron/agent/agents`), project and built-in definitions. The Gateway does
  not project them today.

## Plan rules

**Vocabulary.** One name per concept, the same in the Gateway, the wire, iOS
and the UI. New identifiers were checked against the repository (2026-09-25) and
collide with nothing.

| Concept | Identifier | UI label | Not to be confused with |
| --- | --- | --- | --- |
| Where an available resource comes from | field `distribution`: `"external"` \| `"module"` \| `"local"`, absent for Pi built-ins; Swift `ResourceDistribution`; Gateway helper `resourceDistribution()` | tag External / Module / Local | Pi's `origin` (`package`/`top-level`), which keeps feeding the existing User/Project scope badge; `ExtensionToolOrigin` (transcript attribution); knowledge and hook `provenance`; model `provider` |
| A third-party install unit | `package` (existing `packages.*` RPCs, `PackageService`) | "Installed" container on the Extensions sheet | — |
| A built-in Tron extension | `TronModule` (Gateway definition and Swift model), RPC `modules.list` | "Tron Modules" container | Node/ES modules (never named `module` alone in new code) |
| Hooks for a scope, without a session | RPC `hooks.list` with `{ cwd? }` | Settings → Agent → Hooks | `session.resources` `hookInventory` (per-session view, same shape) |
| Available subagents | `subagents` array on `session.resources`; Swift `AvailableSubagent` | "Subagents" group | subagent runs and history (`subagent.*` events) |
| The settings sheet for installs | view `ExtensionsSettingsView` (renamed from `PackagesSettingsView`) | "Extensions" | the per-extension rows in the Hooks sheet |

Rules: never add a second field for the same concept; reuse existing
identifiers for existing concepts; RPC names use the existing top-level
namespaces (`packages.`, `modules.`, `hooks.`, `session.`), not a new `agent.`
prefix; a renamed type or view moves every reference in the same commit (no
aliases).

**Origin tags.** Every resource row carries exactly one tag, derived by the
Gateway from Pi `sourceInfo` (R-0 verified these rules against the pinned SDK),
never guessed on iOS. The tag is the new field `distribution` (see Vocabulary); the existing
`origin` field keeps Pi's `package`/`top-level` meaning, because iOS already
decodes it (`ResourceCatalogModels.swift`).

| Tag | Rule | Examples |
| --- | --- | --- |
| External | `origin == "package"` | `subagent` from `npm:pi-subagents`; the adapted ask-user package |
| Module | `source == "inline"` (Tron's extension factories, including `tron-mcp-*` MCP tools) | `knowledge`, `display`, `schedule`, `notify` |
| Local | `origin == "top-level"` and `source` is `local`, `auto` or `cli` | skills in `~/.tron/agent/skills`, prompts, project `.agents` files |
| (none) | `source` is `builtin` or `sdk` | `read`, `bash`, `edit` |

Subagents derive `distribution` from their discovery source: `builtin` and
`package` agents come from the pi-subagents package, so they are `external`;
`user` and `project` agents are `local`. The existing "User"/"Project" scope badge stays next to the
new tag.

**Placement decisions** (from the R-0 audit, within the user's intent):

- Project Resources keeps its Diagnostics group and its Reload action.
- Its new Commands group lists only extension commands (`source == "extension"`):
  prompt and skill commands already appear under Prompts and Skills.
- Resources an installed package brings in appear in both places, each in its
  own form (user decision, 2026-09-25): Settings → Extensions shows, per
  installed package, what it **provides** (Skills, Prompts, Subagents, Tools,
  Commands, Themes), answering "what did this install bring in"; Project
  Resources lists the same items by kind with the External tag, answering
  "what can the agent use now". The flat resolved Skills/Prompts lists that
  Packages showed are replaced by the per-package Provides view. Pi themes
  affect only the Mac terminal, not the app's appearance, so they stay under
  Extensions (R-4 finding).
- The wire `extensions` array and `extensionLoadErrors` stay in
  `session.resources`; only the iOS Extensions section goes. The Hooks sheet
  keeps listing extensions that register tools or commands but no hooks, so a
  handler-less extension is never lost.
- `contextFiles` is shown today only through Agent Instructions; unchanged.
- Settings → Tools & Extensions → Locations and Overrides is untouched; its
  "Every Project / Current Project" row is the shared scope component the
  Hooks sheet reuses.
- One module definition: the Tron module list moves out of `RuntimeSlot` into a
  shared definition, so Settings and sessions cannot drift.
- No Tron module registers a command today, so the Tron Modules list shows each
  module's tools, and its commands only when it has some.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| R-0 | Done | Audit: list every item each affected sheet shows today and where it lands afterwards; confirm how `sourceInfo` distinguishes packages, Tron modules, local files and Pi built-ins | none | resources session, 2026-09-25 |
| R-1 | Done | Gateway: add `distribution` (external, module, local, or absent) to each tool, skill, prompt and command in `session.resources`, deriving it from Pi `sourceInfo` per the Plan rules; add a `subagents` list (name, description, model, thinking, source, distribution) using pi-subagents' own discovery loaded through its declared `jiti` dependency, pinned to the installed version and failing soft to an empty list with a diagnostic | R-0 | resources session, 2026-09-25 |
| R-2 | Done | Gateway: move the Tron module list out of `RuntimeSlot` into one shared definition; add RPC `modules.list` listing Tron modules (name, purpose, tools, commands) for Settings; add RPC `hooks.list` per scope (Global or a project folder) without a session, reusing the `PackageService` settings pattern and a `DefaultResourceLoader` under project trust, returning the same shape as `session.resources` hook fields | R-0 | resources session, 2026-09-25 |
| R-3 | Done | iOS Project Resources: groups Skills, Prompts, Commands (extension commands only), Tools and Subagents, each row with the shared origin tag next to the existing scope badge; keep Diagnostics and Reload; remove the Extensions section only (the wire field stays); update the Manage Session row subtitle and the sheet caption | R-1 | resources session, 2026-09-25 |
| R-4 | Done | iOS Settings: rename Packages to Extensions (`ExtensionsSettingsView`) with two containers, Installed (third-party, unchanged actions) and Tron Modules (read-only); remove the resolved Skills/Prompts/Themes lists from it; add the available Themes list to Settings → Appearance | R-2 | resources session, 2026-09-25 |
| R-5 | Done | iOS Settings → Agent → Hooks: new row and sheet carrying today's full hooks view (By Event / By Extension, unregistered-events toggle, extension detail, load issues, omissions notice, refresh), plus the "Every Project / Current Project" scope row reused from Locations and Overrides; keep handler-less extensions listed; remove Project Hooks from Manage Session | R-2 | resources session, 2026-09-25 |
| R-7 | Done | Gateway: `packages.list` gains, per installed package, `provides`: skills, prompts, themes (already resolved per package), subagents attributed to the package (pi-subagents `package` and `builtin` sources, by file path under the package root), and tools and commands from loading the package's extensions session-free (share one loader helper with `hooks.list`, same trust gating and work tracking). Additive fields only | R-2 | resources session, 2026-09-25 |
| R-8 | Done | iOS Settings → Extensions: each Installed package row opens a detail sheet with its Provides groups (Skills, Prompts, Subagents, Tools, Commands, Themes; empty groups hidden), reusing the Project Resources row and tag components; the sheet-level Themes list folds into this per-package view | R-4, R-7 | resources session, 2026-09-25 |
| R-6 | Blocked | E2E check and docs: one simulator run through Manage Session and Settings with screenshots of each changed sheet; update the iOS architecture doc and the Gateway README's resources section | R-3, R-4, R-5, R-8 | |

## Handoff log

### R-0 · Done · 2026-09-25 · resources session (deepseek-worker, checked by the supervisor)

- Result: a complete map of every item on Manage Session, Project Resources, Project Hooks, Packages, Locations and Overrides and the Settings groups, each with a destination. The plan's rules and tasks were corrected from it (see Plan rules).
- Corrections to the draft: the new tag cannot reuse `origin`, which iOS already decodes as Pi's `package`/`top-level` (verified in `ResourceCatalogModels.swift` and the composer badges); tools, skills and prompts do not carry an origin today, so R-1 derives it; commands include prompt and skill entries, so the Commands group filters to extension commands; Prompts and Themes in Packages had no destination; handler-less extensions would have vanished with the Extensions section; the module list is session-owned and needs one shared definition.
- Evidence: SDK source rules verified in the pinned `pi-coding-agent` (`source-info`, `package-manager`, `extensions/loader`, `resource-loader`); pi-subagents discovery exercised read-only through `jiti` (12 built-in, 3 user agents); hooks without a session require loading extensions under project trust (no loader-free path).
- For the next agent: R-1 and R-2 are Gateway-only and independent; R-3 to R-5 follow.

### R-1, R-2 · Done · 2026-09-25 · resources session (deepseek-workers, reviewed by the supervisor)

- R-1: `session.resources` gives every tool, skill, prompt and command a `distribution` from one helper, `resourceDistribution()`; `origin`, `scope` and `source` are unchanged, and Pi built-ins carry no key. A `subagents` array comes from pi-subagents' own `discoverAgentsAll`, loaded through its declared `jiti`, capped at 128, fail-soft to `[]` plus `subagentDiagnostics`. The supervisor sent back one fix: `discoverAgentsAll` does not filter `disabled` agents, so the projection now drops them (test written first).
- R-2: `TRON_MODULES` in `extensions/tron-modules.ts` is the one definition RuntimeSlot registers from (names and order unchanged; a real-session parity test fails on drift). `modules.list` (capability `modules.v1`) lists the modules and MCP tool sources from Connections; individual MCP tool names need a session and are left out. `hooks.list` (capability `hooks.v1`) loads extensions for Global or a trusted project with no session and returns the same shape as the session's hook fields; untrusted projects yield global hooks only.
- Merge fix: R-1 made `resources()` async, so the supervisor added the missing `await` to R-2's two parity tests.
- Evidence (verified): on combined `main`, Gateway `tsc` with declarations and 179 files / 1,898 tests pass. A live probe on this Mac found 14 subagents (11 built-in plus the user's `worker`, which replaces the built-in of the same name, `luna-worker` and `deepseek-worker`, each tagged `local` with its pinned model) and the 9 Tron modules with their tools.
- For the next agent: iOS receives these fields only after the user's next Gateway source rebuild. R-5 should show when a project is untrusted, so global-only hooks are not read as "no project hooks".

### R-7 · Done · 2026-09-25 · resources session (deepseek-worker, reviewed by the supervisor)

- Result: each installed package in `packages.list` carries `provides` (skills, prompts, themes, subagents, tools, commands; capped at 256 names per kind, fail-soft with `providesDiagnostic`). `hooks.list` and `packages.list` share one session-free loader, `admin/session-free-extensions.ts`; the `session.resources` subagent row is unchanged.
- Evidence (verified): full Gateway suite and `tsc` with declarations pass on combined `main`. A live probe on this Mac attributes correctly: `pi-subagents` provides 12 subagents, 2 skills, 6 prompts, `subagent` and `subagent_wait` and 19 commands; `pi-web-access` 4 tools and 4 commands; `pi-agent-browser-native` `agent_browser`; `pi-goal` 3 tools and `/goal`; `pi-anthropic-auth` 9 commands; its core library provides nothing. First call 862 ms, then 40 ms.
- For the next agent: R-8 renders this per package; subagent attribution relies on pi-subagents reporting each agent's file path.

### R-3, R-4, R-5 · Done · 2026-09-25 · resources session (deepseek-workers, reviewed by the supervisor)

- R-3: Project Resources groups Skills, Prompts, Commands (extension commands only), Tools and Subagents; each row shows one `ResourceDistributionTag` beside the existing scope badge (both now use one shared tag label); Diagnostics (including `subagentDiagnostics`), Reload and the detail sheet stay; the Extensions section and the Manage Session Project Hooks row are gone. The wire `extensions` field still feeds Hooks.
- R-4: Packages is now Extensions (`ExtensionsSettingsView`) with Installed (unchanged) and a read-only Tron Modules container from `modules.list`, including MCP tool sources. The flat resolved Skills/Prompts lists left Settings. Pi themes stay under Extensions, because they affect only the Mac terminal, not the app.
- R-5: Settings → Agent → Hooks (`HooksSettingsView`) carries all 12 items of the old view (item map re-checked), fed by `hooks.list`; the "Every Project / Current Project" row is one shared `SettingsScopeRow`, also used by Locations and Overrides; an untrusted project shows a note linking to Project Trust; `ProjectHooksView.swift` is deleted. The supervisor gave the row the Agent group's purple; the sheet keeps the hook teal.
- Review fixes: one shared tag label instead of two copies of the capsule styling; the unread `distribution` fields on the command models removed.
- Evidence (verified): full iOS unit suite on combined `main` 1,655 Swift Testing tests in 134 suites plus 80 XCTest (4 skipped), 0 failures; build 147 s, run 201 s. The branch run also passed. Negative controls in the lane report (capability guard, untrusted note, parity, item map, scope request).
- Known limit: these sheets' rendered text cannot be asserted in the hosting harness (no UIKit labels), so tests assert presentation models and request frames; R-6 covers the rendered result.

### R-8 · Done · 2026-09-25 · resources session (deepseek-worker, reviewed by the supervisor)

- Result: each Installed package row on Settings → Extensions opens `PackageDetailSheet`: source and scope, one External tag in the header, then Provides groups (Skills, Prompts, Subagents, Tools, Commands, Themes) with empty groups hidden, a one-line empty state, and `providesDiagnostic` as the standard notice. `provides` is optional on the existing package model, so an older Gateway shows no groups. The sheet-level Themes list is gone; themes are reached through their package, and themes no package owns stay in a "Local themes" group shown only when some exist.
- Evidence (verified): full iOS unit suite 1,660 Swift Testing tests in 135 suites plus 81 XCTest, 0 failures; six negative controls (optional decode, empty-group hiding, colour ownership, theme reachability, local themes, no extra request). `main` had no other iOS changes, so the result carries over.
- Open for R-6: each Installed row is a button that contains the Update/Remove menu. Whether tapping the ellipsis opens the menu rather than the detail sheet has to be checked by tapping, not in the hosting harness.

### R-6 · Blocked · 2026-09-25 · resources session

- The simulator's Development app is unpaired, and the running Gateway predates R-1, R-2 and R-7, so a walkthrough now would show neither the new data nor a paired session. R-6 runs after the user's Gateway Rebuild from Source and an iOS install: on the phone, or on the simulator once the user pairs it. It must also tap an Installed row's ellipsis to confirm the menu opens, not the detail sheet.

### Section order · 2026-09-25 · resources session

- User decision: Project Resources orders its groups Skills, Subagents, Prompts, Tools, Commands; the package Provides groups use the same order, followed by Themes. The Manage Session subtitle and the iOS development doc match (the doc still described the retired Prompts, Skills, Tools, Extensions order).
