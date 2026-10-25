# gateway/workspace

## Purpose

Tron's durable internal workspace (`<tronHome>/workspace`) and the `tron-core`
extension that tells every Gateway-owned parent runtime who it is, where that
workspace is, and how delegated children receive those facts.

## Owns

`tron-workspace.ts` (`TronWorkspace`: root resolution, initialization, recovery),
`workspace-module.ts` (the module descriptor whose contract is the Gateway's one
`TronWorkspace`; peers read it through `dependsOn`, and the session registry drives its
initialize/dispose order around Home), `core-module.ts` (core descriptor, per-runtime Jev)
and `tron-core-extension.ts`. `web-research-module.ts` composes the shared public-web
owner for all runtime profiles and its explicit scoped native-child socket bridge. The workspace layout, recovery, display and managed-state
contract is [internal-workspace.md](../../docs/internal-workspace.md); installed Swift
apps under `state/apps/` are [swift-apps.md](../../docs/swift-apps.md).

The `resourceRoot` policy supplies this same workspace to the native kernel's
critical lifetime and context reads; capability stores use the module contract.
`operatingContext` supplies the existing `tronContext` formatter to preview without
moving its product copy or changing prompt timing.

## Contract

- `tron-core` appends Tron identity, the resolved workspace path and availability,
  and active-tool guidance to the parent runtime's prompt. It does not change `cwd`,
  load workspace contents, replace Pi's base prompt or write JSONL. It is inline, so
  native `pi-subagents` children do not load it.
- **Delegation handoff.** A public `tool_call` hook prefixes direct model-facing
  `subagent` task/resume text with a bounded (2 KiB UTF-8) advisory handoff, keeping
  the task verbatim. It never rewrites workflow source or mixed `agent`/`workflow`
  requests. Workflow launches, slash/RPC/structured delegation and further children
  bypass the hook, so those tasks must repeat identity, root, availability and
  ownership explicitly. The handoff grants no authority, cwd, extensions or tools.
- **Pinned provider limits.** `pi-subagents` carries `extensionBindings` only as JSON in
  `PI_SUBAGENT_EXTENSION_BINDINGS` (no extension load, no prompt append) and keeps the
  original binding on resume; its request schema has no per-call extension override;
  `subagents.defaultExtensions` configures `extensions` only; `runtimeSnapshotHost`
  snapshots MCP servers only. Pi's built-in MCP config is shared through the agent
  directory for CLI children ([MCP](../../docs/mcp.md)). Tron therefore never
  rewrites Pi settings, agent definitions or workflow scripts to force `tron-core`.
  External CLI/job runners get the facts only as task text.
- **Shared web capability.** `tron-web-research` registers one definition from
  [the public-web owner](../knowledge/README.md#shared-public-web-research).
  Native children load it through required-child extensions, not ambient discovery.
  Scope-bound0600 modules under `gateway/web-research-children/` are disposable
  runtime projections: a reopened parent recreates the same path so retained child
  launches can resume against the current service. The private Unix socket and
  grants are joined and removed on shutdown; no provider credentials enter prompts
  or child settings. Children with a conflicting legacy provider fail explicitly;
  research builtins select an empty ambient-extension list. External CLI/job runners
  do not receive a secretly different web backend.
- Model guidance: write a workflow script to a git-ignored file under the request cwd
  and pass its relative path (absolute paths such as `/tmp` fail); never
  `workflow: true`. Native tasks above 8,000 UTF-16 units use the launcher's private
  task file; workflow stage limits stay runner-owned (1 MiB UTF-8).

## Invariants

- The workspace is separate from every session cwd and the filesystem browser; Pi and
  Gateway canonical stores stay with their owners.
- Delegated children never inherit Gateway-only extensions implicitly.

## Entry points

`TronWorkspace` (resolution and initialization); `tron-core-extension.ts` (prompt
section and the `subagent` handoff hook).

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `workspace.unavailable` | warning | The internal workspace could not be initialized, or its root was lost or replaced (`tron-workspace.ts`): `cause` (`invalid-record`, `unsafe-directory`, `missing-root`, `owned-elsewhere`, `record-write-failed`, `root-changed`) |

## Verify

```bash
scripts/tron verify --module gateway/workspace
scripts/tron test gateway src/workspace/tron-workspace.integration.test.ts
```

Behavior lock: `tron-workspace.lock.integration.test.ts`.

## Not here

The delegated provider's install and admission:
[Pi SDK maintenance](../../docs/pi-sdk-maintenance.md#tron-owned-pi-subagents-build).
Delegated activity projection: [delegated activity](../kernel/delegation/delegated-activity.md).
