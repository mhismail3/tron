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

Cross-module contracts live in [`docs/`](docs/): wire families (below), [settings
contract](docs/settings-contract.md), [Pi SDK maintenance](docs/pi-sdk-maintenance.md),
[connection resilience](docs/connection-resilience.md),
[observability](docs/observability.md), [scenario locks](docs/scenario-locks.md).
Each heading below keeps its inbound anchor and links to the current owner.

## Protocol v7 chat semantics

Invocation receipts, terminal settlement, Stop and transcript order:
[gateway/run](src/sessions/README.md#contract). Protocol version steps:
[transport](src/transport/README.md#contract).

## Pi SDK boundary map

Pi built-ins: [extensions](src/extensions/README.md#contract). Nested execution and
materialization: [gateway/run](src/sessions/README.md#contract). MCP: [MCP
servers](docs/mcp.md). Virtual models and Jev: [providers](src/providers/README.md).

## Connection boundaries

Account envelopes and bindings: [connection management](docs/connections.md); the
Knowledge connector authority: [knowledge](src/knowledge/README.md#contract).

## Knowledge boundaries

See [knowledge module](src/knowledge/README.md) and [knowledge storage](docs/knowledge.md).

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
([security](src/security/)), HTTP/WebSocket serving ([transport](src/transport/README.md)),
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

See [Home module](src/home/README.md), [Home tasks](docs/home-tasks.md) and
[host load](docs/host-load.md).

## Runtime and state

State layout, process environment and background work:
[foundation](src/README.md#contract). Logging: [transport](src/transport/README.md#contract)
and [observability](docs/observability.md), which also owns startup and shutdown records.

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
Browser live viewing and prompt attachments: [media](docs/wire-media.md). Model
context windows, recents and release dates:
[runtime configuration](docs/wire-runtime-configuration.md#model-context-windows).

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

See [episodic memory](docs/episodic-memory.md); Home is its only caller.

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
[wire profiling](docs/wire-profiling.md).

## Session subagent activity

See [delegated activity](docs/delegated-activity.md#session-subagent-activity).

## Extension activity lifecycle and history

See [delegated activity](docs/delegated-activity.md#extension-activity-lifecycle-and-history).
