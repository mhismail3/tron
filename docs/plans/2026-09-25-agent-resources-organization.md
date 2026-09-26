# Agent resources organization

- **Started:** 2026-09-25
- **Status:** Active
- **Last updated:** 2026-09-25, approved; R-0 claimed
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

**Origin tags.** Every resource row carries exactly one tag, derived by the
Gateway from `sourceInfo`, never guessed on iOS:

| Tag | Meaning |
| --- | --- |
| External | Provided by an installed third-party package or extension |
| Module | Provided by a Tron module, including MCP tools from Connections |
| Local | From the user's own or the project's files (skills, prompts, agent definitions, instructions) |
| (none) | Pi built-in tools such as read, bash and edit |

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| R-0 | Claimed | Audit: list every item each affected sheet shows today and where it lands afterwards; confirm how `sourceInfo` distinguishes packages, Tron modules, local files and Pi built-ins | none | resources session, 2026-09-25 |
| R-1 | Ready | Gateway: add an `origin` tag (external, module, local) to each tool, skill, prompt and command in `session.resources`, and a `subagents` list (name, description, origin, model if set) from the same discovery `pi-subagents` uses | R-0 | |
| R-2 | Ready | Gateway: list Tron modules (name, one-line purpose, the tools and commands each provides) for Settings, and let hooks be listed per scope (Global or a project folder) without an open session | R-0 | |
| R-3 | Ready | iOS Project Resources: groups Skills, Prompts, Commands, Tools and Subagents, each row with the shared origin tag; remove the Extensions section; update the row subtitle | R-1 | |
| R-4 | Ready | iOS Settings: rename Packages to Extensions with two containers, Installed (third-party, as today) and Tron Modules (read-only); move the resolved Skills list out to Project Resources | R-2 | |
| R-5 | Ready | iOS Settings → Agent → Hooks: new row and sheet with the same Global/Current project scope picker; remove Project Hooks from Manage Session | R-2 | |
| R-6 | Ready | E2E check and docs: one simulator run through Manage Session and Settings with screenshots of each changed sheet; update the iOS architecture doc and the Gateway README's resources section | R-3, R-4, R-5 | |

## Handoff log
