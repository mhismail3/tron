# Proof toolchain

`scripts/tron proof` owns the pinned Dafny toolchain and checks proof blocks. Run `scripts/tron proof doctor` before gate commands; mutation runs also invoke the doctor and use only `${XDG_CACHE_HOME:-$HOME/Library/Caches}/tron-proof/bin/dafny`. Node commands are launched through `scripts/tron-node`.

```sh
scripts/tron proof bootstrap
scripts/tron proof doctor
scripts/tron proof check [<block>...]
scripts/tron proof mutate <block> [--jobs 2] [--no-oracle] [--out <report.json>]
scripts/tron proof packet <block> [--write] [--no-verify] [--recheck]
```

Blocks live under `packages/core/blocks/<area>/<block>/`; each has `block.json` and may have `mutate.json`. Dafny paths in those files are relative to `packages/core`. Reports go to the configured report path, normally within the block directory. Mutation jobs are capped at four concurrent processes and each Dafny invocation uses one core; interrupting the checker kills each child process group, including solver children.

The mutation gate checks a passing baseline, generated implementation mutants, mapped law failures, well-formedness failures, unmapped lemmas, timeouts, survivors, optional oracles, accepted equivalences, and config coverage for every compiled function. Reports bind to the block and checker hashes. `--recheck` recomputes report counts, re-resolves stillborn mutants, reruns all non-kills and samples killed mutants. `--no-oracle` disables configured external oracles; it does not relax law-verdict requirements.

The packet renders English comments and Dafny statements, helper definitions, assumptions, law-kind coverage and proof/review/mutation/shadow gate status. Review, mutation and shadow records are hash-bound and display STALE when source/config changes. Packet rendering does not itself grant readiness.

Limits: mutation is first-order and the tokenizer covers the Dafny subset used by the blocks (no attributes inside bodies or nested comments). Dafny solver `unknown` reported as an ordinary failed goal cannot be distinguished from a refutation without counterexample extraction; a mapped failed law is therefore a kill. A killed claim forged in a report can escape detection unless selected by the random recheck sample. Shadow execution remains owned by the later shadow tool; packet reads existing `SHADOW.json` only.

`scripts/tron-node exec node --test tools/proof/tests/*.test.mjs` runs the proof-tool journeys. Fixtures are test inputs, not core blocks.