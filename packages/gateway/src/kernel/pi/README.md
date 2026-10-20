# gateway/pi

## Purpose

K8, the Pi seam ([K-0 §4](../../../../../docs/restructure/k0-kernel.md#4-k8-pi-seam)):
the one place Gateway production code reaches the pinned Pi SDK (`@earendil-works/*`).

## Owns

One file per Pi package, each an explicit export list of the names the Gateway uses:
`coding-agent.ts` (`pi-coding-agent`), `ai.ts` (`pi-ai`), `agent-core.ts`
(`pi-agent-core`, types only) and `tui.ts` (`pi-tui`).

## Contract

- **One seam.** Outside this folder, production code imports Pi only from these files,
  type-only imports included (decision D2). Tests and `test-support` import Pi directly:
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

- Imports nothing from the Gateway: only `@earendil-works/*`.
- The `pi-subagents` fork stays an installed package behind delegation
  (`sessions/managed-subagents.ts`), not a seam import.

## Entry points

`coding-agent.ts`, `ai.ts`, `agent-core.ts`, `tui.ts`.

## Signals

None.

## Verify

```bash
scripts/tron verify --module gateway/pi
```

The seam is exercised by every lock: the Pi SDK behavior trace and persisted-state
corpus, the `run-*` locks and `delegation-subagent`.

## Not here

The Pi SDK pin, patch and update scripts (`gateway/pi-sdk`:
[Pi SDK maintenance](../../../docs/pi-sdk-maintenance.md)).
