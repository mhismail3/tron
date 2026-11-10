# Proof toolchain

`scripts/tron proof` owns the pinned Dafny toolchain and the check that proof blocks
([packages/core](../../packages/core/README.md)) pass with it.

```bash
scripts/tron proof bootstrap   # install the pin if absent, then re-verify it; prints versions and the entry point
scripts/tron proof doctor      # re-verify only; never downloads or writes
scripts/tron proof check [<block>...] [--json] [--root <dir>] [--cache <file>]
scripts/tron proof mutate <block> [--root <dir>] [--jobs 1..4] [--out <report.json>] [--laws <file>]
                          [--config <mutate.json>] [--only <id>] [--list] [--equiv <id>] [--recheck <report.json> [--sample N]]
scripts/tron proof packet <block> [--root <dir>] [--write] [--no-verify] [--recheck]
scripts/tron proof packet --batch <out.md> [--root <dir>] <block>...
scripts/tron proof facade <block> [--check]
scripts/tron proof wire --generate <in.dfy> <out-dir>
scripts/tron proof wire --protocol [--check]
```

`bootstrap`/`doctor`: exit 0 when the install matches `dafny.pin`; 1 when missing or mismatched, with the
fix; 64 on usage.

## Pin

`dafny.pin` holds the exact versions and sha256 digests: the official `dafny-4.11.0-arm64-macos-13.zip`
release archive, its 290-file extracted tree, the bundled .NET 8.0.19 runtime files, the bundled Z3 4.12.1
(the default solver) and Z3 4.14.1 (the alternate for solver-portability checks), and the key Dafny
assemblies. The archive is self-contained, so nothing else is installed: no sudo, Homebrew or global tool.

## Install

The install is one per-user cache shared by every worktree, outside `~/.tron`:
`${XDG_CACHE_HOME:-$HOME/Library/Caches}/tron-proof/` holds `dafny-<version>/` (the verified tree),
`cache/` (the archive), `bin/dafny` (the only entry point callers use) and `bin/z3` (the pinned solver).
Every `bootstrap` and `doctor` run re-verifies the tree digest, file count, component digests, the
generated `bin/dafny` wrapper and the reported versions, so a shared cache cannot drift and a tampered
tree is refused. `bootstrap` serialises installers on `.install.lock` and extracts through a staging
directory. `bin/dafny` turns telemetry off and passes `--cores ${DAFNY_CORES:-1}` to verifying commands
unless the caller sets `--cores` (the Mac is shared).

Bump: edit every line of `dafny.pin` from the new release's published digests, run the test below, and
re-check every block on the new pin in the same change; a solver bump is a full re-check.

## Check

`lawcheck/lawcheck.mjs` (`proof check`) checks the named blocks of `<root>/blocks` (default
`packages/core`) and every block below them, deps first, one `dafny verify --cores 1
--verify-included-files` per block on the pinned wrapper after `doctor` passes. A block's key is the
sha256 of the pin, the checker source and flags, the block's own files and the interface files of its
transitive deps; a passing key is cached in `<git dir>/proof/lawcheck-cache.json` (per worktree), so a
cached block is not re-run. It refuses unknown deps, cycles, and any `include` (comments are blanked
first) from an impl file outside the block's own files and its deps' interfaces, or from an interface
file outside the interface files of the block and its deps. Exit 0: every block passed; 1: a block failed (its verifier output is
printed and blocks above it do not run); 2: usage, block graph or toolchain error.

## Mutation

`mutate/mutate.mjs` (`proof mutate`) checks that a block's laws reject every first-order change to its
compiled functions. Config: `blocks/<block>/mutate.json`, every path relative to the core root:
`{block, tier: "high-stakes"|"leaf", impl, symbols, excludeSymbols?, verify, laws: {"<id> <name>": ["Module.Lemma"]},
helpers?, kinds?, translate, accepted?, report, resourceLimit?}`. Each mutant runs in its own copy
of the core root (so relative includes hold) with the pinned wrapper after `doctor` passes.

1. **Baseline.** The unmutated block must verify and show a Passed row for every law; else exit 2.
2. **Mutants** of the `symbols` bodies only (ghost code and proofs are never mutated): `relational`, `boundary`,
   `arith`, `drop-operand`, `off-by-one`, `constant`, `branch`, `constructor`, `swap-args`, `logic`. Identical
   sources are deduplicated; ids are stable (`<function>/<op>/<from>-><to>#<n>`). A compiled method is
   never mutated (its loops carry proof annotations the tool cannot tell from code): it goes in `excludeSymbols`,
   and its contract must fix what it returns.
3. **Verdicts.** `killed`: a lemma listed in `laws` failed, or a compiled function's own well-formedness check did.
   Never a kill: `unknown-timeout` (timed out, out of resource or inconclusive; retried once alone), `unmapped`
   (only a lemma not in `laws` failed, so it cannot mask a vacuous law), `verifier-error`, `survived`. `stillborn` (resolution/type error) is excluded from the score.
4. **Gate.** PASS only for a full run (no `--only`) with valid > 0, stillborn ≤ 40% and zero survived and
   unknown. An `accepted` entry exempts a mutant only if it holds: `equivalent` makes the tool prove
   `F == F_mutant` on F's whole domain (its preconditions: the impl's, else those it inherits from the laws'
   signature, which Dafny enforces at every call; optional `hint` proof body); `out-of-contract` only for `tier: "leaf"`. A stale accepted id exits 2, and every compiled
   function must be in `symbols` or `excludeSymbols` with a reason.
5. **Binding.** The report's `inputsHash` is the block hash (`packet/hash.mjs`: the whole mutate.json plus the
   block's laws, impl, verify and `lawContext` files); `--laws` (replaces the block's first laws file in the
   copies) and `--config` runs are marked `override:` and never match. `toolHash` covers mutate.mjs and hash.mjs.
6. **Recheck.** `--recheck <report>` never trusts a report: it recomputes counts and verdict, rejects acceptances
   not in mutate.json, re-resolves every stillborn mutant, re-runs every non-killed one and N killed ones chosen
   with a fresh random seed.
7. **Solver cap.** `--jobs` 1..4 (default 2), each Dafny with `--cores 1`; every child runs in its own process
   group and is killed with its solvers on exit or signal.

Exit 0: PASS; 1: FAIL; 2: config, baseline or toolchain error. Limits: mutants are first-order; the tokenizer
covers the Dafny subset blocks use (no attributes inside bodies, no nested comments in mutated bodies); Dafny
reports a solver "unknown" on a goal as an ordinary failure, so such a failure of a mapped law counts as a kill;
a forged `killed` label in a report is caught only if sampled.

## Packet

`packet/packet.mjs` (`proof packet`) renders a block's law review packet, `blocks/<block>/LAWS.md` with `--write`,
from the sources, so it cannot drift from what is proven. Per law: its plain-English comment and Dafny statement
from the block's laws file (a lemma, or a compiled method whose contract is the law), supporting lemmas, mutation kills and the reviewer's verdict. Per block: the
implementation under test, the definitions the laws use, `// Assumption A<n>:` world-model assumptions, the
law-kind table and five gates, each bound to the block hash:

- **Proof:** `doctor`, then `dafny verify --verify-included-files` on each `verify` file.
- **Independent review:** `REVIEW.json` at the current hash and tier, every law ACCEPT, every accepted mutant
  AGREE, reviewer agent and model different from the writer's, and the reviewer's Pi transcript naming the
  hash and exactly that model. `reviewer.session` is the transcript's path below its project directory of
  `~/.tron/agent/sessions` (read, never written), so a committed review holds no machine path; it must match
  exactly one transcript.
- **Mutation:** the `report` for the current hash and checker, PASS (with `--recheck`, re-run with 12 samples).
- **Cut over:** names the shell that runs the block (`block.json` `shell`); every core block has one.

A gate for another hash shows STALE. Exit 1 lists packet problems: a missing English comment, a law lemma not
found, a lemma neither a law nor a declared helper, a law-marked lemma not listed, an escape hatch, an
unaccounted law kind (high-stakes) or a report acceptance not in mutate.json.

## Façade and wire

[dafny2wire/README.md](dafny2wire/README.md) owns `proof facade` (a block's compiled core and typed façade, in
its shell) and `proof wire` (the protocol's generated TypeScript and Swift codecs).

## Verify

`scripts/tron test tooling tools/proof/tests/test-proof.py` runs the real CLI with an isolated cache and
a clean environment (`env -i`, `PATH=/usr/bin:/bin`): doctor fails on the empty cache, bootstrap passes,
doctor reports the pinned versions, a true fixture verifies (on both bundled solvers) and a false law
fails, and a one-byte tamper of the tree is refused by doctor and bootstrap. It copies the archive from
the user cache when present, otherwise downloads it.

`scripts/tron-node exec node --test tools/proof/tests/lawcheck.test.mjs` runs `proof check` on a copy of
two fixture blocks (`tests/fixtures/lawcheck`, test input, not blocks): cold and cached runs, a proof-only
edit re-checks one block, a law edit re-checks the block above, a deliberately false law fails and the
block above does not run with the verifier's postcondition error, and an include of a dep's
implementation is refused, also behind a comment and from a laws file.

`scripts/tron-node exec node --test tools/proof/tests/gates.test.mjs` runs `proof mutate` and `proof packet` on a
copy of the fixture blocks `demo/clamp` and `demo/timeout` (`tests/fixtures/mutate`, with law variants in
`tests/fixtures/mutate-variants`; test input, not core blocks), about 2 minutes: the real laws PASS with six
proven equivalences; a weakened law FAILS with the survivor it no longer catches; a false equivalence claim is
rejected by its failing proof; a mutant only an unmapped helper catches is `unmapped`, not killed; a law proof
that runs out of resources is `unknown-timeout` after its retry, never killed; the packet renders each law's
English and statement from the laws file; and an impl or a law edit shows the review and the mutation report
STALE.

`scripts/tron test tooling tools/proof/tests/test-core.py` is the gate test of the real blocks, declared by
`packages/core/package.module.json` and by the generated cores' module (`packages/gateway/src/core`), so any
change under either runs it: `proof check` passes on a fresh cache, and for each block with a `mutate.json` the
regenerated packet equals the committed `LAWS.md` and shows proof PASS, a current mutation PASS and a
`REVIEW.json` for the current block hash with every law ACCEPT, and `proof facade --check` finds the generated
core and façade fresh in the shell the packet names as cut over; and each change listed in a block's `method-mutants.json` (to a compiled method, which `proof mutate` does not
mutate) makes `proof check` fail on a copy of the block with a verification error.
An edit that skips any gate fails it.

`scripts/tron-node exec node --test tools/proof/tests/wire.test.mjs` runs `proof wire`: `--protocol --check`
passes; the protocol's codecs, on 12 seeded values of each of its datatypes, encode exactly what
`JSON.stringify` writes for the value built in declaration order, round trip, and agree byte for byte between
TypeScript and Swift; of eight malformed protocol values TypeScript refuses each at its path and Swift
refuses the wrong boolean tag, the unknown enum map key and the overflowing number but reads the unknown field,
the missing and the null field and the unknown `ChatSemanticKind` tolerantly; and the codecs generated from
`tests/fixtures/wire/Wire.dfy` (one datatype per form) round trip 2,000 seeded random frames plus edge doubles,
keys and strings, TypeScript and Swift (`swiftc -O`) produce identical bytes and identical normalisations of
non-canonical inputs (and a Swift-built map encodes in JavaScript order), and of 16 malformed inputs
TypeScript rejects each at its path and Swift rejects or reads each as stated.

`scripts/tron-node exec node --test tools/proof/tests/facade.test.mjs` generates the façade of the
fixture block `demo/meter` (`tests/fixtures/facade`), which names a shell: its `core.mjs` lands in the shell's directory, imports nothing,
holds the compiler's module output byte for byte and exactly one copied helper, and loads with no
`node_modules` above it; numbers cross only as integers of their newtype's range and preconditions are checked;
a linked list crosses as an array in order, 200,000 items long without touching the call stack;
`--check` fails on a hand edit of either file; the copied helper stands alone and a helper that names anything
but its parameters, locals and `Math` does not; and `function method`, datatype equality, building a sequence, a function named
like a runtime member that uses the runtime, an `int`, a newtype whose range is not literal and a generic datatype
that is not a linked list are each refused, naming the function or type, with nothing written; a constructor
without fields is one shared value found by its own name only; and a compiled method gets a fresh work array on
each call, sized by its precondition, and is refused when an array is unsized or a precondition is one the façade
cannot establish.
