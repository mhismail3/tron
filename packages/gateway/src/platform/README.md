# gateway/platform

## Purpose

Shared bounded host facts, independent of Gateway transport admission and
capability state. `tailscale-status.ts` owns the actual OS command/status probe
used by diagnostics, Mac Terminal host reporting and transport peer lookup.

## Contract

- `runBoundedCommand` runs the supplied process with its original timeout,
  kill signal, output bound and caller options; it reports completion or failure.
- `readTailscaleStatus` tries the app CLI before `PATH`, supplies CLI mode and
  bounded JSON output, and returns the same validated self/peer facts or failures.
- `classifyPeer` maps those facts to direct/relay/offline/unknown; offline takes
  precedence over a remembered address. It does not authorize connections.
- Callers own their operation lifetime. This module has no cache, polling,
  readiness controller or Gateway/session ownership. Transport retains its
  address filter, shared in-flight lookup, reuse window and wall-clock deadline.

## Validation

The existing `transport/tailscale-peer.integration.test.ts` uses real fixture CLI
processes for environment, peer health, result reuse, failure and killed-timeout
behavior. Mac Terminal's Swift/tailnet journey is a separate native check, not
implied by the process tests.
