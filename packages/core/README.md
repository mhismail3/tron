# Core: proof blocks

`packages/core` holds Tron's proven decision logic as Dafny **blocks**. It has no I/O, clock or ids:
a block is pure, total and deterministic, and the shell (Gateway TypeScript) interprets its effects.
No block replaces shipped TypeScript yet.

```text
laws/<area>/<Block>.dfy          L0: abstract modules: types, signatures, law lemmas with plain-English comments
blocks/<area>/<block>/           L1: one directory per block
  Block.dfy                      `module X refines XLaws`: definitions and proofs
  block.json                     {"interface": [...], "impl": [...], "deps": [...]}
```

## Block contract

- `block.json` lists the block's `interface` (its laws files), its `impl` (definition and proof files),
  both relative to `packages/core`, and its `deps` (other block names; a block's name is its directory
  under `blocks/`, e.g. `schedule/next`).
- A dependent sees only its deps' laws: it imports their abstract modules, and every `include` names
  the block's own files or a transitive dep's interface file. `proof check` refuses any other include,
  because the cache key would not cover what the block depends on.
- Law statements are what review guards; definitions and proofs are what the checker guards. Edit a
  law only with an independent review of that law.
- Escape hatches (`assume`, `{:axiom}`, `{:verify false}`, `{:extern}`) are trusted code and need a
  maintainer decision.

## Check

```bash
scripts/tron proof check                 # every block, plus everything below it
scripts/tron proof check schedule/next   # one block and the blocks below it
```

The check uses only the pinned toolchain (`scripts/tron proof doctor` must pass; see
[tools/proof](../../tools/proof/README.md)) with one solver process. A block's key covers the pin, the
checker, its own files and the laws of every block below it, so a proof edit re-checks one block and a
law edit re-checks every block above it. Passing keys are cached per worktree.
