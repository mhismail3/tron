# Gateway agent guide

Read this before editing `packages/gateway/`, with the [root charter](../../AGENTS.md), which
binds everywhere. The [README](README.md) is the package index and `docs/` hold the contracts;
this file holds where to find modules, the test lanes and the local hazards.

## Module map

Each module's README owns its contract. `scripts/tron docs modules packages/gateway` prints every
module with its layer, manifest and README; `scripts/tron ownership --ledger` prints each path's
module and purpose.

## Test lanes

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

**Lint.** `npm run lint` runs Oxlint (pinned in `devDependencies`) over `src`, `test-support`,
`test-fixtures` and `scripts`. `.oxlintrc.json` enables only the rules it lists; a rule
joins only with zero findings, and a disable needs a reason after `--`.
`npm run test:lint` proves real bad fixtures fail. Type-aware async rules and
`no-unused-vars` wait on #1227.

Wire-traffic profiling and multi-session qualification:
[Gateway profile](../../scripts/tron-profile-gateway.md).

## Hazards

- **Host lock and isolation.** `scripts/tron test gateway` takes the host's full-Gateway lock (unless
  its caller already holds it) and gives each run its own HOME and temporary roots
  ([verify](../../tools/verify/README.md#gateway-test-isolation)); a bare `npx vitest run` has neither.
- **Test-host pool.** `scripts/tron verify` and `scripts/tron test gateway` run the Gateway Vitest lanes on the
  Mac mini at the exact commit when it is reachable, set up and idle, and otherwise here, naming the host and why
  ([pool](../../tools/verify/README.md#gateway-and-python-lanes-on-the-test-host-pool)), verify's Python group with them; `--gateway-host local|mini` overrides it.
- **Nested pass.** Files that run nested Vitest or real pi children, or activate the managed
  pi-subagents install, run one at a time in the nested pass; `vitest.nested.config.ts` lists them
  ([test-support](test-support/README.md#contract)).
- **Debug Gateway only.** Agents run `scripts/tron dev` on port 9848; Stable, `~/.tron` and
  `com.tron.server` are the maintainer's ([charter](../../AGENTS.md#safety-boundaries)).
- **Persisted bytes.** A change to stored JSON or JSONL bytes is a migration decision, not a
  refactor ([charter](../../AGENTS.md#architecture-invariants)).
- **Home.** Home memory, the endless Home chat, summarization and chapters keep working exactly as
  they do; cleanup there only preserves behaviour. Triggers and automations stay generic
  Gateway primitives: they carry no Home-specific logic that steers how Home behaves.

## gateway/platform

**Purpose.** Shared bounded host facts, independent of Gateway transport admission and
capability state. `tailscale-status.ts` owns the actual OS command/status probe
used by diagnostics, Mac Terminal host reporting and transport peer lookup.

**Contract.**

- `runBoundedCommand` runs the supplied process with its original timeout,
  kill signal, output bound and caller options; it reports completion or failure.
- `readTailscaleStatus` tries the app CLI before `PATH`, supplies CLI mode and
  bounded JSON output, and returns the same validated self/peer facts or failures.
- `classifyPeer` maps those facts to direct/relay/offline/unknown; offline takes
  precedence over a remembered address. It does not authorize connections.
- Callers own their operation lifetime. This module has no cache, polling,
  readiness controller or Gateway/session ownership. Transport retains its
  address filter, shared in-flight lookup, reuse window and wall-clock deadline.

**Validation.** The existing `src/transport/tailscale-peer.integration.test.ts` uses real fixture CLI
processes for environment, peer health, result reuse, failure and killed-timeout
behavior. Mac Terminal's Swift/tailnet journey is a separate native check, not
implied by the process tests.
