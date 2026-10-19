# Verify

`scripts/tron verify` runs one slice's evidence locally: the static checkers, then
the tests its manifests select
([plan §6.2 V2](../../docs/restructure/plan.md#62-scriptstron-verify-v2-the-one-command)).
The worker owns it. It never queues, waits on another worker, caches a pass,
writes a receipt or gates a landing.

```bash
scripts/tron verify --changed [--base <ref>]   # a slice: the change since merge-base(<ref>, HEAD)
scripts/tron verify --module <id>               # one module's owned tests
scripts/tron verify --all                       # every lock (milestones, kernel changes)
scripts/tron verify --update-locks <id>         # rewrite <id>'s goldens (lock or approved migration slices)
scripts/tron verify ... --skip ios,mac,relay    # accept, explicitly, selections verify cannot run
scripts/tron verify ... --plan                  # print the selection and steps only
```

It reads the committed state: uncommitted or untracked changes are refused
(exit 2). Each step prints `[i/N] name …` when it starts and its result and time
when it ends. The first failure stops the run and prints the log tail. Every
step's full log is in `test-results/verify/<sha>/`, and the report is
`test-results/verify/<sha>.json`. The report's `resultDigest` covers the
selection, each step's outcome and test count, and the verdict, but not timing,
so two runs of one commit can be compared.

## Static checks (existing tools only)

1. `scripts/tron ownership`
2. `scripts/tron budgets HEAD --base <base>`
3. documentation policy
4. the privacy guard over `git diff <base>..HEAD`
5. `git diff --check`
6. `scripts/tron work ledger`, which is **advisory**: issue state is shared
   coordination, not this commit's code, so its violations are reported but
   never fail the run.
7. When the selection touches the Gateway: `npm run check` (production and test
   support typecheck), `npm run lint`, and `scripts/tron layers gateway`.
8. `scripts/tron layers ios`, run only when this commit has a fresh iOS index;
   otherwise it is reported as skipped, never as passed.

The moved-lines report (V10) does not exist yet.

## Selection

Paths changed between the merge base and HEAD, both old and new names, map to
their owning manifests (`tools/ownership`; deleted paths are owned as of the
base). Each module contributes its owned tests:
- `*.test.ts` and `*.test.mjs`;
- `test-*.py` and `test-*.sh`;
- Swift `*Tests.swift` under test targets.

Recorders under `test-fixtures/` are never run. Modules whose `dependsOn` or
`dynamicEdges` reach a selected module add their locks, transitively.

The run widens to **every lock** when the change touches a module at layer
L0–L2 (platform, contracts, kernel), `gateway/package` (toolchain),
`gateway/test-support`, `gateway/pi-sdk`, or an unowned path. Locks are
`*.lock.integration.test.ts`, the Pi SDK behavior trace and persisted-state
corpus, and the iOS UI locks.

Runners are the existing ones:

| Group | Runner |
|---|---|
| `gateway` / `gateway-nested` | Gateway vitest, main or `vitest.nested.config.ts` |
| `node-gateway` / `node` | `node --test` |
| `python` / `shell` | `python3` / `bash` per file |
| `ios` / `mac` / `relay` | not driven by verify |

When `ios`, `mac` or `relay` tests are selected, the run is `incomplete` (exit 1)
unless `--skip` names them; they need the simulator, xcodebuild or the relay's
own dependencies, and their lanes run them. A selection that runs zero passing
tests fails: an empty run is not evidence.

## Mutation sampling

`scripts/tron mutate <packages/gateway/src file> [--count 30] [--seed 1465]` measures
lock sensitivity (plan §6.6; the maintainer's 0.10 decision). For one file it:
1. takes a seeded sample of single-operator flips (`===`/`!==`, `&&`/`||`,
   `true`/`false`, comparisons, `±1`);
2. runs the Gateway vitest tests `verify --changed` would select for a change to
   that file, once per mutant;
3. counts a failing run as a kill.

The file is restored after every mutant. The report goes to
`test-results/mutate/`. It measures and never gates. Stryker is deferred until a
known-kill probe proves its vitest runner activates mutants with the pinned vitest.

## Verify

`scripts/tron test tooling scripts/test-tron-verify.py` drives verify in
disposable repositories whose modules own real Python tests. It covers
one-module selection and a loud failure, kernel/unowned widening, the
zero-test failure, the uncommitted refusal, and identical result digests.
Output is kept in `test-results/verify-cli/`.
