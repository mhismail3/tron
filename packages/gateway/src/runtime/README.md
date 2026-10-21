# Runtime stream and environment

## Purpose

Request-stream cancellation and process-environment primitives around Pi.

## Owns

- `abort-aware-stream.ts`: one AgentSession stream boundary for ordinary responses
  and summarization, including asynchronous setup and result-only streams.
- `node-command-environment.ts`: supervised Node/Pi alias validation and ordered
  agent-bin/Homebrew PATH configuration before resource discovery.

## Contract

An aborted request's error is classified as aborted; successful terminal results
remain unchanged. No error-message matching authorizes retry or compaction.

Supervised environment validation applies only to the selected payload Gateway
entrypoint, never a source child that inherited supervision markers. Alias targets,
package metadata and executable identity must agree. Stable keeps its payload Node
first; Debug may retain a developer Node first. Agent-bin insertion and Homebrew
append preserve that precedence. These helpers do not install or restart anything.

## Entry points

`abortAwareStream`, `configureSupervisedNodeCommandEnvironment`,
`configureAgentBinEnvironment`, `configureHomebrewPath`.

## Verify

```bash
scripts/tron test gateway src/kernel/run/compaction-policy.integration.test.ts src/kernel/run/direct-bash-process-owner.integration.test.ts
scripts/tron verify --module gateway/runtime
```

## Not here

Compaction policy and the live ModuleHost compaction port:
[gateway/run](../kernel/run/README.md). Run admission and cancellation orchestration
remain in [sessions](../sessions/README.md).
