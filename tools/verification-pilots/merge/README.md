# Merge-conflict corpus pilot (#1262)

Offline, compact measurement of Git + rerere and Mergiraf on real two-parent merge
history. Evidence and scratch clones live outside the repository. Nothing here is
installed, registered, or run by default: no merge driver config, no `.gitattributes`,
no hooks, no CI gate. Measurement only.

## Pipeline

1. `corpus.py --repo <scratch clone> --tip <sha> --work <dir> --out <manifest.jsonl>`
   builds one row per two-parent commit (oldest first) with the first parent (left),
   second parent (right), single merge base, and the historical resolved tree (oracle).
   Paths that need a content decision are kept as `both-content` or `modify-delete`;
   one-sided paths the merge commit edited by hand are kept as `manual_edit`.
   Rename detection is off for classification; per-side rename counts are recorded.
2. `replay.py --arm git-plain` runs real `git merge --no-commit` in a scratch clone with
   rerere disabled; each merge starts clean.
3. `replay.py --arm git-rerere --cache cold|seeded:<rr-cache copy>` runs real merges with
   rerere enabled, learning in chronological order. `seeded` copies an existing rr-cache;
   it is not a fair repeat-reuse measure because some seeded entries may be the very
   resolutions being replayed. `cold` is the fair one.
4. `replay.py --arm mergiraf --mergiraf <binary>` runs `mergiraf merge base left right -p
   <path> -o <out>` per `both-content` path, with no git merge and no repo configuration.
   Exit 0 is clean, 1 is conflict.

Human resolution is simulated by writing the historical content into every path left
unresolved, then committing (which lets rerere learn). Exact byte equality with the
historical content is an **oracle proxy**. Differing clean outputs are classified by
independent inspection, never labelled wrong automatically. No human-time estimate is made.

Scratch clones must be created with `git clone --local --no-hardlinks` from the source
repository; the tool never writes to a shared checkout. Every Git process runs with
isolated HOME/TMPDIR and `GIT_CONFIG_GLOBAL=/dev/null`; behavior-changing settings are
passed with `-c` (`merge.conflictStyle=diff3`, matching the author's global config).
