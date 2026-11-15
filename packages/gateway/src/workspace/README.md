# gateway/workspace

## Purpose

Tron's durable internal workspace (`<tronHome>/workspace`) and the `tron-core`
extension that tells every Gateway-owned parent runtime who it is, where that
workspace is, how to maintain scratch, finished artifacts and living data, and how
delegated children receive those facts.

## Owns

`tron-workspace.ts` (`TronWorkspace`: root resolution, initialization, recovery),
`workspace-module.ts` (the module descriptor whose contract is the Gateway's one
`TronWorkspace`; peers read it through `dependsOn`, and the session registry drives its
initialize/dispose order around Home), `core-module.ts` (core descriptor, per-runtime Jev)
and `tron-core-extension.ts`. `web-research-module.ts` composes the shared public-web
owner for all runtime profiles and its explicit scoped native-child socket bridge. The workspace layout, recovery, display and managed-state
guidance is [internal-workspace.md](../../docs/internal-workspace.md); installed Swift
apps under `state/apps/` are [swift-apps.md](../../docs/swift-apps.md).

The `resourceRoot` policy supplies this same workspace to the native kernel's
critical lifetime and context reads; capability stores use the module contract.
The core extension consumes only `ResourceRoot.describe`, not the concrete workspace implementation.
`operatingContext` supplies the existing `tronContext` formatter to preview without
moving its product copy or changing prompt timing.

## Contract

- **One core.** `kernel/host/tron-context.ts` owns the fixed common core, the child
  handoff and `APPROVAL_RULE`, the one literal approval list. Every runtime, Home
  included, receives the core as the SDK host `preamble`, replacing Pi's generic
  identity while Pi keeps its tool, rule and docs sections; a custom system prompt
  renders as the separate `role` section. Repository rules keep their own approval
  routing, not a second list. Wording grants no authority.
- `tron-core` adds a trailing `tron` section with the cwd, the resolved workspace
  path and availability, and active-tool guidance. It does not change `cwd`, load
  workspace contents or write JSONL. It is inline, so native `pi-subagents` children
  do not load it.
- **Browser preference.** Core context names `agent_browser` only while that tool
  is active. Desktop-only and tool-less requests do not advertise it.
- **Delegation handoff.** `tron-core` registers the bounded (4 KiB UTF-8)
  `[Tron handoff]` for its session through the managed provider's
  `child-task-context` API. The provider delivers it once at the start of every
  child's USER or external TASK text: direct, resume, workflow, slash/RPC, nested,
  external CLI and Herdr launches, and retains it for resumes. Tool arguments are
  never rewritten and parents never copy it. It grants no authority, cwd, extensions
  or tools. The provider API is required: a rollback moves Gateway and provider
  together.
- **Pinned provider limits.** `pi-subagents` carries `extensionBindings` only as JSON in
  `PI_SUBAGENT_EXTENSION_BINDINGS` (no extension load, no prompt append) and keeps the
  original binding on resume; its request schema has no per-call extension override;
  `subagents.defaultExtensions` configures `extensions` only; `runtimeSnapshotHost`
  snapshots MCP servers only. Pi's built-in MCP config is shared through the agent
  directory for CLI children ([MCP](../../docs/mcp.md)). Tron therefore never
  rewrites Pi settings, agent definitions or workflow scripts to force `tron-core`.
  External CLI/job runners get the facts only as task text.
- **Shared web capability.** Workspace's `web-research.ts` owns bounded public-web
  evidence; `tron-web-research` registers its definition from `web-research-contract.ts`.
  Native children load it through required-child extensions, not ambient discovery.
  Scope-bound0600 modules under `state/web-research-children/` are disposable
  runtime projections: a reopened parent recreates the same path so retained child
  launches can resume against the current service. The private Unix socket and
  grants are joined and removed on shutdown; no provider credentials enter prompts
  or child settings. Children with a conflicting legacy provider fail explicitly;
  research builtins select an empty ambient-extension list. External CLI/job runners
  do not receive a secretly different web backend.
- Model guidance for workflows lives in the provider's `subagent` prompt guidelines.
  Native tasks above 8,000 UTF-16 units use the launcher's private task file;
  workflow stage limits stay runner-owned (1 MiB UTF-8).

## Invariants

- The workspace is separate from every session cwd and the filesystem browser; Pi and
  Gateway canonical stores stay with their owners.
- Delegated children never inherit Gateway-only extensions implicitly.

## Entry points

`TronWorkspace` (resolution and initialization); `tron-core-extension.ts` (prompt
preamble, `tron` section and child handoff registration).

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `workspace.unavailable` | warning | The internal workspace could not be initialized, or its root was lost or replaced (`tron-workspace.ts`): `cause` (`invalid-record`, `unsafe-directory`, `missing-root`, `owned-elsewhere`, `record-write-failed`, `root-changed`) |

## Verify

```bash
scripts/tron verify --module gateway/workspace
scripts/tron test gateway src/e2e/workspace/tron-workspace.integration.test.ts
```

Behavior lock: `tron-workspace.lock.integration.test.ts`.

## Not here

The delegated provider's install and admission:
[Pi SDK maintenance](../../docs/pi-sdk-maintenance.md#tron-owned-pi-subagents-build).
Delegated activity projection: [delegated activity](../kernel/delegation/delegated-activity.md).
