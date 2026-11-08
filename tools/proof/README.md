# Proof toolchain

`scripts/tron proof` owns the pinned Dafny toolchain and the check that proof blocks
([packages/core](../../packages/core/README.md)) pass with it.

```bash
scripts/tron proof bootstrap   # install the pin if absent, then re-verify it; prints versions and the entry point
scripts/tron proof doctor      # re-verify only; never downloads or writes
scripts/tron proof check [<block>...] [--json] [--root <dir>] [--cache <file>]
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
