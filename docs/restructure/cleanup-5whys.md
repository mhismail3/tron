# CLEANUP-5WHYS: why residue piled up, and what now prevents it

Method (maintainer, 2026-11-05): Musk's design order. (1) Every kept thing names a current
need and its owner, found with 5 Whys; (2) delete the rest, recording tips and paths first;
(3) simplify only what survived; (4) shorten the path to safe main; (5) automate last, and
only a surviving, proven step. Each prevention reuses an existing owner. Deleted refs are in
`refs/archive/cleanup-20261105/*` on origin; the maintainer's internal workspace
`files/cleanup-20261105/` lists every deleted ref and path with its restore command.

## Worktrees

1. Why were merged worktrees and unregistered directories left? Removal failed.
2. Why? `git worktree remove` and `rmtree` hit permission errors.
3. Why? `bundle-gateway.sh` seals the Gateway payload read-only (`chmod -R a-w`, the launcher's
   immutability check) and Xcode copies it into DerivedData.
4. Why was that invisible? `tidy --prune` ignored git's exit code; the housekeeping skill's
   manual chmod step was the only knowledge of it.
5. Why manual? Each remover assumed a writable tree. **Root cause:** removers swallowed errors
   on a tree another owner made read-only.

Prevention: `tidy --prune` restores owner-write before removing a merged worktree and reports a
failed removal (`tools/ownership/tests/test-tidy-scope.py`, sealed-payload case). Metric:
registered worktrees beyond main, live workers and the installed build = 0 after a prune;
`tidy` orphan directories = 0.

## Branches

1. Why 108 local / 384 remote branches? Landed and abandoned branches were never deleted.
2. Why? Landing is a plain-Git merge, so GitHub's delete-on-merge never fires; workers push task
   branches for parking and nothing removes them after landing.
3. Why did `tidy --prune` not catch local ones? It deletes only exact ancestors; 17 were
   rebased or cherry-picked equivalents from earlier landing eras.
4. Why did abandoned work survive? Issues closed NOT_PLANNED left their branches as the only
   record. **Root cause:** a branch had no end-of-life step; the archive was the branch itself.

Prevention: the Git skill deletes the task branch on origin after landing; `tidy --prune`
deletes merged local branches; a deleted branch is restorable from `refs/archive/*` on origin,
so deletion is never loss. Not automated: patch-equivalence pruning (current landing is
`--no-ff`, so ancestry suffices). Metric: remote heads = main + open PRs + branches of open
issues (16 on 2026-11-05, from 384).

## Mac replace builds and rollback sets

1. Why 17 old build checkouts (~16 GB) when retention said "current and previous"?
   `prune_builds` failed silently (`rmtree(ignore_errors=True)`) on the sealed payload.
2. Why did older operations keep 92 GB snapshots, old apps and payloads? No code pruned them;
   an unrecorded manual sweep on 2026-11-03 removed some.
3. Why keep them at all? Rollback restores only the newest operation's previous app; an older
   `~/.tron` snapshot is never restored over newer data. **Root cause:** the operation owner
   had no retention for what it wrote.

Prevention: a finished full replacement keeps only its own operation and installed build
(`scripts/tron_mac_replace.py` `prune_store`; `test-tron-mac-replace.py --retention-only`);
failures are journaled, never raised into a rollback. The previous build is dropped: nothing
reads it after install. Metric: `replace/` holds 1 build, 1 rollback set, migration archives.

## Rehearsal and backup data

1. Why 140 GB of Knowledge rehearsals and 66 GB of September–October reinstall sets?
   They were kept after their operations finished.
2. Why? Retention required "an explicit owner decision", which no step ever requested.
3. Why no step? The runbooks end at "verified". **Root cause:** a recovery set had no retirement
   point. Every reinstall set's canonical sessions were in the newest snapshot (one 1.5 KB
   debug session was not; it is preserved).

Prevention: rehearsals are scratch of the operation they rehearse, deleted when it finishes; a
forward-only migration's original archive (and the prior app it needs) stays inside that
migration's operation directory, where replace retention leaves it, until the maintainer
retires it (`packages/mac-app/docs/development.md`). Metric: `~/.tron-maintenance` = current
rollback set + migration archives awaiting a decision.

## Repository layout and backlog

Repository layout: the approved structure plan (#2276); each slice re-asks why each move serves "agents find and own code fast, with fewer collisions".
Backlog (#2193): a tracking issue is a second ledger of scope its children already own (P6);
it closes once every child is closed or stands alone.
