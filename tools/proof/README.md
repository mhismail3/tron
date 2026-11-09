# Proof toolchain

`scripts/tron proof` owns the pinned Dafny toolchain and the check that proof blocks
([packages/core](../../packages/core/README.md)) pass with it.

```bash
scripts/tron proof bootstrap   # install the pin if absent, then re-verify it; prints versions and the entry point
scripts/tron proof doctor      # re-verify only; never downloads or writes
scripts/tron proof check [<block>...] [--json] [--root <dir>] [--cache <file>]
scripts/tron proof mutate <block> [--root <dir>] [--jobs 1..4] [--no-oracle] [--out <report.json>] [--laws <file>]
                          [--config <mutate.json>] [--only <id>] [--list] [--equiv <id>] [--recheck <report.json> [--sample N]]
scripts/tron proof packet <block> [--root <dir>] [--write] [--no-verify] [--recheck]
scripts/tron proof packet --batch <out.md> [--root <dir>] <block>...
scripts/tron proof shadow <block> [--root <dir>] [--out <file>] [--days N [--corpus <dir>]]
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
helpers?, kinds?, translate, setup?, oracles, accepted?, report, resourceLimit?}`. Each mutant runs in its own copy
of the core root (so relative includes hold) with the pinned wrapper after `doctor` passes.

1. **Baseline.** The unmutated block must verify, pass every oracle, and show a Passed row for every law; else exit 2.
2. **Mutants** of the `symbols` bodies only (ghost code and proofs are never mutated): `relational`, `boundary`,
   `arith`, `drop-operand`, `off-by-one`, `constant`, `branch`, `constructor`, `swap-args`, `logic`. Identical
   sources are deduplicated; ids are stable (`<function>/<op>/<from>-><to>#<n>`).
3. **Verdicts.** `killed`: a lemma listed in `laws` failed, or a compiled function's own well-formedness check did.
   Never a kill: `unknown-timeout` (timed out, out of resource or inconclusive; retried once alone), `unmapped`
   (only a lemma not in `laws` failed, so it cannot mask a vacuous law), `verifier-error`, `law-gap` (only an
   oracle caught it), `survived`. `stillborn` (resolution/type error) is excluded from the score.
4. **Gate.** PASS only for a full run (no `--only`) with valid > 0, stillborn ≤ 40% and zero law-gap, survived and
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
a forged `killed` label in a report is caught only if sampled. Oracles run with the repository as working
directory.

## Packet

`packet/packet.mjs` (`proof packet`) renders a block's law review packet, `blocks/<block>/LAWS.md` with `--write`,
from the sources, so it cannot drift from what is proven. Per law: its plain-English comment and Dafny statement
from the block's laws file, supporting lemmas, mutation kills and the reviewer's verdict. Per block: the
implementation under test, the definitions the laws use, `// Assumption A<n>:` world-model assumptions, the
law-kind table and five gates, each bound to the block hash:

- **Proof:** `doctor`, then `dafny verify --verify-included-files` on each `verify` file.
- **Independent review:** `REVIEW.json` at the current hash and tier, every law ACCEPT, every accepted mutant
  AGREE, reviewer agent and model different from the writer's, and the reviewer's Pi transcript naming the
  hash and exactly that model. `reviewer.session` is the transcript's path below its project directory of
  `~/.tron/agent/sessions` (read, never written), so a committed review holds no machine path; it must match
  exactly one transcript.
- **Mutation:** the `report` for the current hash and checker, PASS (with `--recheck`, re-run with 12 samples).
- **Shadow:** `SHADOW.json` match at the current hash and compiled core; cut-over needs real traffic over 7
  (high-stakes) or 3 (leaf) days.
- **Ready for cut-over:** only with `--recheck`, which re-runs the shadow too, and only with a real-traffic
  shadow over the tier's window.

A gate for another hash shows STALE. Exit 1 lists packet problems: a missing English comment, a law lemma not
found, a lemma neither a law nor a declared helper, a law-marked lemma not listed, an escape hatch, an
unaccounted law kind (high-stakes) or a report acceptance not in mutate.json.

## Traffic corpus

Shadows need real inputs. `packages/gateway/src/proof/traffic-recorder.ts` records, at each seam where a
block will replace TypeScript logic, the exact typed inputs and the output the TypeScript returned:
`recordSeam(block, seam, input, output)`, a no-op unless enabled. The first seams are
`nextAutomationOccurrence`, `firstAutomationOccurrence` and `classifyDueOccurrence` in
`packages/gateway/src/automations/schedule.ts`: once and interval triggers record under block
`schedule/occurrence`, calendar triggers under `schedule/calendar`; nested calls are not seams.

- **Enabled only on the Debug Gateway:** `scripts/tron dev start|restart --proof-traffic` sets
  `TRON_PROOF_TRAFFIC=1` for that launch; a running supervisor keeps its setting across promotions, so the
  flag is refused while it runs (stop first). The Gateway honours it only with `TRON_GATEWAY_CHANNEL=dev` and
  never for a home inside the Stable home (also through a symlink), so Stable and Release builds ignore it. It is an environment variable rather
  than a typed setting because every settings key appears in iOS Settings and the settings tool; making it
  a setting is a later product decision.
- **Format:** JSONL under `<Debug home>/gateway/proof-traffic/<block>/<yyyy-mm-dd>.jsonl` (UTC days), one
  record `{schema: "tron-proof-traffic/1", block, seam, seq, at, input, output}` per call (`output` null
  for no value); at most 20,000 records per block and day, newest 14 days kept. Appends are synchronous and
  unsynced: a lost tail record costs one comparison, and a write error never reaches the caller.
- **Privacy:** seams pass typed values only (times, trigger shapes, policies); free text and identities are
  not recorded. A seam that carries an identity must pseudonymise it before it is added. The corpus stays on
  the Mac and is never committed.
- **Determinism:** time enters as a value, the recorder feeds nothing back, and every record carries the
  TypeScript output, so a replay is offline and exact.

## Shadow and oracles

`shadow/shadow.mjs` (`proof shadow`) compiles the block's `translate` file with the pinned toolchain into a
temporary directory and runs `mutate.json` `shadow.cmd` with `{core}` set to the compiled `core.js`; it writes
`blocks/<block>/SHADOW.json` `{status: match|mismatch|error, compared, mismatches, firstMismatch, source,
realTraffic, windowDays, inputsHash, coreJsHash, command, date}`, deleting the old file first, so a failed run
never leaves a stale match.
With `--days N` it replays recorded Debug traffic instead: the newest N day files of
`~/.tron-dev/gateway/proof-traffic/<block>/` (read only; `--corpus` names another directory) go to
`mutate.json` `replay.cmd` (`{corpus}` expands to the files), and the result is `realTraffic: true`,
`windowDays` = the non-empty day files with a real date replayed (gaps allowed; a file is a day), and `corpus: {first, last, hash}` (dates and a digest, no paths). No
recorded traffic is an error. The packet's `--recheck` re-runs a recorded shadow over the same number of days
and requires a match on at least as many calls; a real-traffic shadow counts for cut-over only while its
newest recorded day is at most three days old. The oracle refuses (exit 2) any record the recorder would
not write: another schema, block or seam, a missing `output`, an `at` off the file's day, or an input or
output of the wrong shape. The command must exit 0 with every request agreeing or 1 with mismatches; a crash,
a signal, unparsable output, nothing compared, or an exit status that contradicts the counts is `error`. Generated-input comparisons are `realTraffic: false`. The packet re-compiles the
core to check `coreJsHash`, and `--recheck` re-runs the shadow.

`oracles/<block>.mjs` compare a compiled core with the shipped TypeScript it models on seeded generated
inputs, or with `--replay <files>` on recorded calls (the recorded TypeScript output is the expectation), and
print `{requests, agree, diffs}` (exit 0 iff all agree, 1 on a mismatch, 2 on a record it cannot read); a block's `mutate.json` uses its oracle
both as a mutation oracle (`law-gap` detection) and as its shadow command. `oracles/schedule-occurrence.mjs`
imports `packages/gateway/src/automations/schedule.ts` through `oracles/gateway-source.mjs` (module hooks
that map the sources' `./x.js` imports to `.ts` and apply Node's TypeScript transform) and calls the core
through the block's generated façade. `oracles/schedule-calendar.mjs` does the same for calendar triggers, giving the core
the zone table `packages/gateway/src/automations/zone-table.ts` builds from Intl (also on replay, so a replay
checks the table builder too); generated inputs the TypeScript throws on (a civil date the zone skips) are
counted as `tsRefused`, not compared, since a throw is never recorded. The compiled core's runtime dependency `bignumber.js` is pinned in `packages/core/package.json`
(`scripts/tron-node exec npm --prefix packages/core ci` prepares a worktree).

## Façade

`dafny2wire/facade.mjs` (`proof facade <block> [--check] [--root <dir>]`) writes `packages/core/dist/<block>/core.js`,
the block's `translate` file compiled by the pinned Dafny (unedited, with a generated header), and `facade.ts`, a
typed TypeScript wrapper generated from the datatypes and compiled signatures of the block's laws: `load(corePath)`
binds it to any compiled core (the checked-in one, or a mutant or fresh translation for oracles), and `core` is the
bound checked-in one. It exposes every compiled function and predicate of the laws (ghost and commented-out
declarations are not compiled, so not exposed) and checks each stated precondition before calling, because
compiled code does not check `requires`. Types: `int` -> `number` and `nat` -> `number >= 0` (safe integers, checked
both ways), `bool` -> `boolean`, `seq<T>` -> a readonly array of `T` (also nested and as a field), a datatype of nullary constructors -> a string union of their names, a
one-constructor datatype named like its type -> a plain object, any other datatype -> an object tagged by `$`; an
unknown constructor is a `TypeError` in either direction. Refused before anything compiles: Dafny 3 `function method`
syntax, preconditions other than a call of a compiled predicate on parameters, generic functions, and any other
Dafny type (an unused generic datatype is ignored). `--check` regenerates into a temporary directory and exits 1 if
the checked-in files differ.

## Wire

The Gateway protocol's value types have one source, `packages/core/wire/Protocol.dfy`: `proof wire --protocol`
writes `packages/gateway/src/protocol/types.ts` (types, decoders and encoders, generated; never edited) and
`--check` exits 1 when that file is not what the source generates. The Gateway still writes frames with
`JSON.stringify` of the values it builds, so the generated encoders serve the codec tests only and the
decoders are the protocol's validators. A type another module owns (the display contract, the upstream error)
is marked `import=<path>`: types.ts imports it and fails to compile unless it equals the stated shape. The
Swift codec is generated and proven against the TypeScript one in the test below; the iOS app still decodes
with its own models.

`dafny2wire/dafny2wire.mjs` (`proof wire --generate`) turns `// @wire` Dafny datatypes into `wire.ts` and
`Wire.swift` codecs: records; `// @wire enum` (a JSON literal per constructor: `{:wire "x"}`, `{:wire 1}`,
`{:wire true}`, else the constructor name); `// @wire tag=<field>` tagged unions (a tag value may be a string,
number or boolean); `// @wire bykind` unions
split by JSON kind (a nullary constructor is `null`; this is how open JSON values are written). Field types:
`string`, `bool`, `int`/`nat` (safe-range JSON integers), `real` (float64), `seq<T>`, `map<string, T>` (or
`map<E, T>` with E a string enum: only E's values are keys),
`Option<T>` (absent key), `Nullable<T>` (JSON null) and `Absent` (the key never appears); a trailing `_`
escapes a Dafny keyword or a shared destructor name. Canonical JSON: keys in declaration order with the tag
first, no whitespace, JSON.stringify string escaping, ECMAScript Number::toString (`-0` as `0`; non-finite
numbers refused by both encoders). Maps keep JavaScript's property order (array-index keys ascending, then
insertion order; a duplicate key keeps its first position and last value), also when built in Swift, so the
Swift codec parses JSON itself rather than through Foundation; an overflowing number literal (`1e400`)
parses as infinity and is rejected at its path by both decoders. The TypeScript decoders are strict: they
reject unknown and absent-only fields, missing fields, wrong kinds, out-of-range integers and unknown
constructors at a named JSON path. The Swift decoders are tolerant, the iOS decoding policy: unknown fields are
ignored; an absent field, or a null one whose type cannot hold null (not `Nullable<T>`, not a union with a null
constructor), takes its type's default (`""`, `0`, `false`, empty, `null`, the `unknown` value of an enum that
has one, an enum's only value, a record of defaults); an unknown value of an enum with an `unknown` value is
`unknown`. A field with no default (another enum, a union) is still required, and wrong kinds, unknown tags and
unknown map keys are still refused; invariants beyond the shape belong to a validator layer, not the decoder.
Limits: Swift refuses a lone UTF-16 surrogate, which JavaScript strings can hold.

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
STALE; and `proof shadow` records a match or mismatch only from a comparison that ran and agrees with
its exit status (`tests/fixtures/mutate-variants/shadow-stub.mjs`). The oracle and `law-gap` path is exercised by the first core block's real oracle, not by this test.

`scripts/tron test tooling tools/proof/tests/test-core.py` is the gate test of the real blocks, declared by
`packages/core/package.module.json`, so any change under `packages/core` runs it: `proof check` passes on a
fresh cache, and for each block with a `mutate.json` the regenerated packet equals the committed `LAWS.md`
and shows proof PASS, a current mutation PASS, a current shadow match, and a `REVIEW.json` for the current
block hash with every law ACCEPT, and `proof facade --check` finds `dist/` fresh. An edit that skips any gate
fails it.

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

`scripts/tron test gateway src/proof/traffic-recorder.integration.test.ts` proves the recorder is refused
outside an opted-in Debug Gateway (Stable channel, no channel, other values, the Stable home), that a
seeded schedule journey through the real seams writes one record per call (none for nested calls), each under
its trigger's block (`schedule/occurrence` or `schedule/calendar`), that replays through the same TypeScript to the recorded outputs, and that the daily cap and
retention hold.

`scripts/tron-node exec node --test tools/proof/tests/facade.test.mjs` generates the façade of the fixture block
`demo/counter` (`tests/fixtures/facade`): it exposes exactly the compiled declarations (a multi-line datatype in
full, an opaque function; no ghost or commented-out one), round trips values (sequences, nested and as fields),
refuses unknown constructors, a non-array sequence, non-integers, negative naturals, a broken precondition and an out-of-range result; `--check` fails on a hand edit of
either file; and `function method`, an uncheckable precondition and an unsupported type are refused.

`scripts/tron-node exec node --test tools/proof/tests/replay.test.mjs` replays a corpus of recorder-format
calls of the shipped schedule functions through the real block: two faithful days are a real-traffic match
over two days, a recorded output nudged by 1 ms is a mismatch naming that record, `--days 1` replays only the
newest day, and a malformed line, a foreign record or an empty corpus is an error.
