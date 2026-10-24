# Mac maintenance scripts

## Purpose

Own the operator-facing Mac replacement and offline reinstall workflows. The
[Mac runbook](../packages/mac-app/docs/development.md) owns the live procedure.

## Owns

`scripts/mac.module.json` lists this module's files. `tron_mac_replace.py` owns
replacement planning and the detached journaled runner; `tron_mac_replace_platform.py`
is its installed-host boundary. `tron_mac_reinstall.py` owns manual preparation,
verified backups, resume and recovery evidence; it never installs or launches an app.

## Contract

`scripts/tron mac replace`, `mac reinstall` and `mac verify` are the entry points.
Replacement builds fetched main, pins the exact-app Quit request and retains rollback
material. Manual reinstall requires successful Quit and writer quiescence before
confirmation; Finder replacement and launch remain operator actions.

## Invariants

- No replacement or activation instruction after a stale source or corrupt backup.
- An interrupted offline window rechecks its persisted inventory in a new process.
- Retired payload selection and predecessor evidence retain their original owner.
- Finish removes only the active pointer after verification, retaining recovery bytes.
- Fixture tests never establish approval for a live install, restart or data migration.

## Verify

`python3 scripts/test-tron-mac-reinstall.py` runs the real parser/workflow in fresh
children over private fixture files and OS locks. Its platform boundary substitutes
identity documents for signed apps and a held OS lock for a host writer. It proves
backup/refusal/resume/evidence behavior, not signing, service detection or launch.
Results, including failures, go to `test-results/mac-reinstall/report.json`.

`python3 scripts/test-tron-mac-replace.py --checkout-only` exercises real Git/LFS
under the launchd PATH; `--quit-only` compiles a standalone AppKit fixture using the
production nonce-bound handoff and termination owners. The full replacement suite
also builds a private Gateway and swaps a fixture app under its own launchd jobs;
that heavier lane is distinct from the offline preparation lock.

`python3 scripts/test-verify-mac-install.py` uses fixture artifacts and real TLS
listeners. No test here qualifies a real reinstall; that proof belongs to the
maintainer's requested rebuild window.

## Signals

`STOP: <category>` refuses an unsafe manual transition and preserves its operation.
Replacement step journals retain exact failures and rollback state.

## Not here

Mac UI, launcher/payload packaging, native helper implementations, Gateway lifecycle
and releases remain with their package owners. No maintenance test touches Stable.
