# Runtime environment

## Purpose

Process-environment primitives around the selected Pi runtime.

## Owns

- `node-command-environment.ts`: supervised Node/Pi alias validation and ordered
  agent-bin/Homebrew PATH configuration before resource discovery.

## Contract

Supervised environment validation applies only to the selected payload Gateway
entrypoint, never a source child that inherited supervision markers. Alias targets,
package metadata and executable identity must agree. Stable keeps its payload Node
first; Debug may retain a developer Node first. Agent-bin insertion and Homebrew
append preserve that precedence. These helpers do not install or restart anything.

## Entry points

`configureSupervisedNodeCommandEnvironment`,
`configureAgentBinEnvironment`, `configureHomebrewPath`.

## Verify

```bash
scripts/tron test gateway src/kernel/run/direct-bash-process-owner.integration.test.ts
scripts/tron verify --module gateway/runtime
```

## Not here

Request-stream cancellation classification, compaction policy and the live ModuleHost
compaction port: [gateway/run](../kernel/run/README.md). Run admission and cancellation
orchestration remain in [sessions](../sessions/README.md).
