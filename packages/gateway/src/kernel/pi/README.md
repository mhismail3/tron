# gateway/pi

## Purpose

K8, the Pi seam ([K-0 §4](../../../../../docs/restructure/k0-kernel.md#4-k8-pi-seam)):
the one place Gateway production code reaches the pinned Pi SDK (`@earendil-works/*`).

## Owns

One file per Pi package, each an explicit export list of the names the Gateway uses:
`coding-agent.ts` (`pi-coding-agent`), `ai.ts` (`pi-ai`), `agent-core.ts`
(`pi-agent-core`, types only) and `tui.ts` (`pi-tui`).

- `packages.ts`: runtime resolution of the pinned SDK on disk: the host package root
  given to delegated providers, the bundled CLI for MCP administration, the `pi` CLI
  for session export, the alias table that loads the managed `pi-subagents` closure
  against the Gateway's own SDK modules, and the payload's `pi-coding-agent` directory.
- `adapters.ts`: one named adapter per Pi internal the Gateway adapts, owning only the
  Pi side (which member, in which order): `guardCanonicalAppend` (the private
  `SessionManager._appendEntry`, one owner per manager), `wrapModelRuntimeStream`
  (`ModelRuntime.streamSimple`), `installAgentPipeline` (the `Agent` request pipeline),
  `bindRuntimeSession` (`setBeforeSessionInvalidate`/`setRebindSession`) and `initTheme`
  (Pi's process-global theme, pinned to dark).
- `version.ts`: `PI_VERSION`, the one exact, coherent Pi release `package.json`
  declares (Tron's patched tarball counts as its release); a malformed declaration
  throws when the module loads.

## Contract

- **One seam.** Outside this folder, production code imports Pi only from these files,
  type-only imports included (decision D2), and finds Pi packages on disk only through
  `packages.ts`. Tests and `test-support` import Pi directly:
  the faux provider is Pi's.
- **Re-exports, not wrappers.** A name here is Pi's own value or type, unchanged; the
  seam adds no behavior, so extension order, tool schemas and model-visible text are
  Pi's (B1/B2).
- **Patch-removal checklist.** A `// patch N` note marks a name the Gateway uses through
  an API of Tron's patched `pi-coding-agent` tarball (`pi-coding-agent-patch.json`
  `removeWhen`, items 1-5: `projectDir`, image-only dequeue, queued image normalization,
  idle `systemPrompt` sections, revocable run start). When a release ships them, the
  noted names are where the Gateway's use is rechecked
  ([Pi SDK maintenance](../../../docs/pi-sdk-maintenance.md#tron-patched-pi-coding-agent)).
- **The list is the usage.** A name the Gateway stops using leaves its file; a new use
  adds it here first.

## Invariants

- **Pipeline order.** `installAgentPipeline` captures Pi's provider stream first, then
  installs message conversion, request preparation and the stream chain (so a
  stream-side guard is innermost), then the outer context transform and outermost
  preparation, then the turn boundary. Callers pass stages, never reorder them.
- **Theme before extensions.** `startGatewayModules` (`main/modules.ts`) calls
  `initTheme` first; gateway-main starts it before anything loads an extension (global
  provider resources), and test registries start it too. No module sets Pi's theme as an
  import side effect.

- Imports nothing from the Gateway: only `@earendil-works/*` and Node built-ins.
- Resolution runs from this package, so it finds the same `node_modules` as the
  Gateway's own imports.
- The `pi-subagents` fork stays an installed package behind delegation
  (`sessions/managed-subagents.ts`), not a seam import.

## Entry points

`coding-agent.ts`, `ai.ts`, `agent-core.ts`, `tui.ts`, `packages.ts`, `adapters.ts`, `version.ts`
(`PI_VERSION`, reported by `system.info`;
`scripts/ios-gateway-e2e-test` reads it from `dist/kernel/pi/version.js`).

## Signals

None.

## Verify

```bash
scripts/tron verify --module gateway/pi
```

The seam is exercised by every lock: the Pi SDK behavior trace and persisted-state
corpus, the `run-*` locks and `delegation-subagent`; `home-activation-wake` records the
request pipeline's order. Kernel contract: `pi-theme.integration.test.ts` (a runtime
extension finds Pi's global theme initialized).

## Not here

The Pi SDK pin, patch and update scripts (`gateway/pi-sdk`:
[Pi SDK maintenance](../../../docs/pi-sdk-maintenance.md)).
