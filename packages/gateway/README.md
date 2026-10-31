# Tron Gateway

Tron Gateway is the minimal always-running Mac service behind the Tron iPhone app. It
embeds the pinned Pi SDK through supported SDK exports; user-facing copy calls the
product and agent **Tron**, and source names Pi only where it means the SDK contract.
The embedded runtime stays canonical for sessions, provider/model semantics,
credentials, settings, packages, resources, compaction and retries; the Gateway keeps
no session database or event journal.

Index only. Module READMEs own each contract (§5.6 shape: Purpose, Owns, Contract,
Invariants, Entry points, Signals, Verify, Not here). Generated indexes replace
hand-kept tables:

```bash
scripts/tron docs modules packages/gateway   # module map with each README
scripts/tron docs rpc                        # RPC methods by namespace
scripts/tron docs settings                   # settings keys and record subjects
scripts/tron docs signals                    # Signals rows of every module README
```

Cross-module contracts live in [`docs/`](docs): wire families (below), [settings
contract](docs/settings-contract.md), [Pi SDK maintenance](docs/pi-sdk-maintenance.md),
[connection resilience](docs/connection-resilience.md),
[observability](docs/observability.md), [scenario locks](docs/scenario-locks.md).
Each heading below keeps its inbound anchor and links to the current owner.

## Chat semantics

Invocation receipts, terminal settlement, Stop and transcript order:
[gateway/run](src/sessions/README.md#contract). Protocol version steps:
[transport](src/transport/README.md#contract).

## Pi SDK boundary map

Pi built-ins: [extensions](src/extensions/README.md#contract). Nested execution and
materialization: [gateway/run](src/sessions/README.md#contract). MCP: [MCP
servers](docs/mcp.md). Virtual models and Jev: [providers](src/providers/README.md).

## Connection boundaries

Account envelopes and bindings: [connection management](docs/connections.md);
read-only connection snapshots: [integrations](src/integrations/README.md).

## Profile and research boundaries

[Profile](src/modules/home/profile.md) owns current-format personal notes. Knowledge
files are ordinary workspace files accessed through the normal file tools, not a
runtime-managed store. Public web research belongs to [workspace](src/workspace/README.md);
the [Knowledge files contract](../../docs/development.md#knowledge-files) describes their current use.

## Pi SDK maintenance

Pi SDK and `pi-subagents` change only through their updaters:
[Pi SDK maintenance](docs/pi-sdk-maintenance.md#update-rules).

### Tron-patched `pi-coding-agent`

See [Pi SDK maintenance](docs/pi-sdk-maintenance.md#tron-patched-pi-coding-agent).

### Tron-owned `pi-subagents` build

See [Pi SDK maintenance](docs/pi-sdk-maintenance.md#tron-owned-pi-subagents-build).

### Pi SDK behavior trace

See [Pi SDK maintenance](docs/pi-sdk-maintenance.md#pi-sdk-behavior-trace).

## Ownership

The Gateway owns mobile infrastructure: enrollment and device credentials
([security](src/security)), HTTP/WebSocket serving ([transport](src/transport/README.md)),
one serialized lane and live runtime per session ([gateway/run](src/sessions/README.md)),
filesystem/Git/PTY access ([machine](src/machine/README.md)), administration and
settings ([admin](src/admin/README.md), [settings contract](docs/settings-contract.md)),
and push admission ([notifications](src/notifications/README.md)). MCP
administration: [MCP servers](docs/mcp.md#administration). Agent home:
[foundation](src/README.md#state-layout). Provider account usage:
[providers](src/providers/README.md#contract).

## Automations

See [automations](src/automations/README.md).

## Moonshot Kimi K3

See [providers](src/providers/README.md#contract).

## Internal workspace

See [workspace module](src/workspace/README.md), [internal
workspace](docs/internal-workspace.md) and [Swift apps](docs/swift-apps.md).

## Tron Home

See [Home module](src/modules/home/README.md), [Home tasks](src/modules/home/tasks.md) and
[host load](docs/host-load.md).

## Runtime and state

State layout, process environment and background work:
[foundation](src/README.md#contract). Logging: [transport](src/transport/README.md#contract)
and [observability](docs/observability.md); startup and shutdown records: [foundation](src/README.md#signals).

### Diagnostic bundle

`scripts/tron diagnose [--since <count><s|m|h|d>] [--out <path>]` writes one read-only
bundle: the `~/.tron/logs` streams in the window (default 2h), device exports, payload
selection documents, launchd `com.tron.server` records, `/health`, Tron processes,
`scripts/tron mac verify` and Tailscale paths. Commands are time-bounded; text is
redacted with the logger's rules; output is one new `0600` file. It needs a Gateway
build (`npm run build`) and exits 66 until the compiled collector (`src/admin/diagnose.ts`) exists.

## Push notifications

See [notifications](src/notifications/README.md).

## Transport

Wire families and the subscription barrier: [transport](src/transport/README.md#contract).
Also [display](src/display/README.md), [uploads](src/machine/uploads.md),
[runtime configuration](src/admin/runtime-configuration.md) (models, context windows,
login) and [host control](src/admin/host-control.md) (update, drain, exit).

## Session invariants

See [gateway/run: Invariants](src/sessions/README.md#invariants).

## Trust and execution

Trust gates project resources (settings, extensions, skills, prompts, packages,
system prompt files run with the Mac user's authority) but is not a sandbox; review
package and extension source before installing. Trust mutations serialize, reload every
open project runtime with the proposed decision and persist only after all reloads
succeed, else restore the prior decision (`TrustService`, [admin](src/admin/README.md)).
Global provider runtime: [providers](src/providers/README.md#contract). Tron context
and delegated children: [workspace](src/workspace/README.md#contract).

### Mac Terminal

See [machine: Mac Terminal](src/machine/README.md#mac-terminal).

### Project root

See [machine: Project root](src/machine/README.md#project-root).

## Session search

See [session search](docs/session-search.md).

## Episodic memory

See [gateway/episodic](src/episodic/README.md); Home is its only caller.

## Development

```bash
npm ci && npm run build && npm test && npm audit --omit=dev   # in packages/gateway
scripts/tron test gateway                                   # from the repo root
scripts/tron-node exec npm --prefix packages/gateway run test:nested
cd packages/gateway && ../../scripts/tron-node exec npx vitest run <file>
scripts/tron chat [--session <id>]   # terminal chat attached to the Gateway runtime
```

- `npm run check` type-checks production and test-support/corpus scopes without
  emitting, using TypeScript's incremental data in `node_modules/.cache/tron/`;
  `npm run build` always emits. `npm run test:typescript-build` proves both
  (`test-results/typescript-build/report.json`).
- `npm test` runs the parallel pass, then the nested pass
  ([test-support](test-support/README.md#contract)).
- `scripts/tron chat` never opens JSONL; a concurrent `pi --session` on the same file is
  unsupported ([charter](../../AGENTS.md#architecture-invariants)).

### Lint

`npm run lint` runs Oxlint (pinned in `devDependencies`) over `src`, `test-support`,
`test-fixtures` and `scripts`. `.oxlintrc.json` enables only the rules it lists; a rule
joins only with zero findings, and a disable needs a reason after `--`.
`npm run test:lint` proves real bad fixtures fail. Type-aware async rules and
`no-unused-vars` wait on #1227.

Wire-traffic profiling and multi-session qualification:
[Gateway profile](../../scripts/tron-profile-gateway.md).

## Session subagent activity

See [delegated activity](src/kernel/delegation/delegated-activity.md#session-subagent-activity).

## Extension activity lifecycle and history

See [delegated activity](src/kernel/delegation/delegated-activity.md#extension-activity-lifecycle-and-history).

## Signals

Rows of the Pi SDK and managed-provider updater scripts (`gateway/pi-sdk`), kept here until it
has a README; every other Gateway module's rows are in its own README
(`scripts/tron docs signals`).

| Signal | Level | Meaning |
|---|---|---|
| `probe process join failed; staging preserved` / `Refusing fixture removal after process join failure` | updater or probe stderr; `TRON_TEST_PROCESS_OWNER_FAILURE` record | A fixture process could not be joined after TERM/KILL; staging stays owned and publications are restored. Settle those exact PIDs before retiring staging; never retry the removal |
| `pi-subagents update failed` | `npm run update:pi-subagents` stderr | Dependency preparation failed, not activation; the suffix names dirty inputs, source, release, packaging or check failure. Candidates are rolled back |
| `pi-subagents update failed: … execution gate failed` / `… rollback probe failed` | updater stderr, before publication | The unpublished candidate cannot execute, or the return leg cannot discover, execute or resume; the original pin stays |
| `pi-subagents pin check failed` during payload staging/verification | bundler or checker stderr | Selected pin metadata, archive, lock or closure is missing or invalid; reject the payload before startup |
