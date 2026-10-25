# Docs indexes

`scripts/tron docs` prints cross-module indexes from manifests and code, so no
doc keeps a hand-edited copy of them
([plan §5.6](../../docs/restructure/plan.md#56-docs-target), D1 in
[§4.3](../../docs/restructure/plan.md#43-multi-agent-native-design-principles-dev-time)).
It uses only the standard library of Python and the pinned Node.

```bash
scripts/tron docs modules [<path>]   # module map, optionally only manifests under <path>
scripts/tron docs signals            # Signals rows of every module README
scripts/tron docs rpc                # Gateway RPC methods
scripts/tron docs settings           # settings keys and record subjects
scripts/tron docs check [--base <ref>]  # exit 1 when a generated block in tracked Markdown is stale
scripts/tron docs update             # rewrite stale generated blocks
```

Each generator prints Markdown to stdout. Exit 0: printed (or every block is
current). Exit 1: a source could not be read, or a block is stale or malformed.
Exit 2: usage.

## Sources

| Index | Source of truth |
|---|---|
| `modules` | `tools/ownership` (`git ls-files '*.module.json'`): id, layer, owned-file count, manifest, and the `README.md` in the manifest's folder when that module owns it. Ownership violations are reported on stderr; the map is still printed |
| `signals` | In each README.md a module owns, the tables under its `## Signals` heading, up to the next level-1 or level-2 heading (`###` subsections count). Each row keeps all its cells, the first naming the signal, plus a link to its module. Rows are grouped into one table per distinct header and sorted. Fenced code and generated blocks are skipped |
| `rpc` | The `case` labels of the `switch (method)` in `GatewayService.invoke` (`packages/gateway/src/transport/gateway-service.ts`), grouped by namespace |
| `settings` | `KEYS` (id, dynamic qualifier, group, allowed layers, Home layers, timing, effect, floor) and `RECORD_SUBJECTS` of `packages/gateway/src/kernel/settings/settings-schema.ts`, constructed through the real `main/settings-schema.ts` owner contributions, not parsed, because keys are built in code. `tools/docs/settings-keys.mjs` runs it under the pinned Node with TypeScript stripping, so the Gateway's `node_modules` must be installed |

## Generated blocks

The indexes are meant to be printed on demand. A doc that must carry one may
embed it between markers; the opener's words after `tron docs` are the
generator's arguments:

```markdown
<!-- tron docs modules packages/gateway -->
(output of scripts/tron docs modules packages/gateway)
<!-- /tron docs -->
```

`check` regenerates every block in tracked Markdown and fails, naming the file
and generator, when one differs, has no end marker or names an unknown
generator. With `--base <ref>` (as `verify` runs it), a `settings` block is
regenerated only when one of its sources (any Gateway `src/` file, `package.json`,
`package-lock.json`, `tools/docs/`) or the block's own text changed since `<ref>`:
otherwise regenerating cannot differ, and the Gateway's `node_modules` is not
needed. A missing `node_modules` is named in one line. `update` rewrites the stale
ones, and never a file with an unclosed block. Nothing runs these automatically:
a slice that embeds a block runs `check`. An embedded index makes its doc an
edit point for every change to the source, so embed only where readers need
the table in place.

## Verify

`scripts/tron test tooling scripts/test-tron-docs.py` runs the real CLI against
this repository (the module map equals the tracked manifests, the RPC and
settings lists cover what the protocol answered and settings change receipts applied) and against
disposable fixture repositories, where a deleted manifest or an added settings
key makes a committed block fail `check`. The last run is kept in
`test-results/docs-cli/last-run.txt`.
