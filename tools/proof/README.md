# Proof toolchain

`scripts/tron proof` owns the pinned Dafny toolchain that proof blocks are checked with.

```bash
scripts/tron proof bootstrap   # install the pin if absent, then re-verify it; prints versions and the entry point
scripts/tron proof doctor      # re-verify only; never downloads or writes
```

Exit 0: the install matches `dafny.pin`. Exit 1: missing or mismatched, with the fix. Exit 64: usage.

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

## Verify

`scripts/tron test tooling tools/proof/tests/test-proof.py` runs the real CLI with an isolated cache and
a clean environment (`env -i`, `PATH=/usr/bin:/bin`): doctor fails on the empty cache, bootstrap passes,
doctor reports the pinned versions, a true fixture verifies (on both bundled solvers) and a false law
fails, and a one-byte tamper of the tree is refused by doctor and bootstrap. It copies the archive from
the user cache when present, otherwise downloads it.
