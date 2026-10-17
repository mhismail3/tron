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

## Result (#1262, measured on 129 real content-decision merges)

Verdict: **drop**. Do not install or configure a Mergiraf merge driver; keep Git + rerere
as-is (existing `rerere.enabled`, no new config, no `.gitattributes`).

Per-path counts over the 525 both-content paths (historical content as the oracle proxy):

| Arm | Clean exact | Clean different | Unresolved |
| --- | ---: | ---: | ---: |
| Git (plain, real `git merge`) | 357 | 20 | 148 |
| Mergiraf (per-path driver emulation) | 362 | 31 | 132 |

- Mergiraf leaves 16 fewer paths unresolved but produces 11 more clean-different outputs.
- Syntax-supported paths (363): Git 128 unresolved vs Mergiraf 113. Unsupported paths
  (162, mostly Swift and other extensions Mergiraf does not parse): Git 20 vs Mergiraf 19.
  The unsupported fallback is Mergiraf's line-based merge, so Swift gains almost nothing.
- Two Mergiraf-only wrong clean outputs where Git was exact (merge e596f0b4): duplicated
  `showLocalErrorDetail` declaration in `SheetCoordinator.swift` and a duplicated
  `case .localErrorDetail` arm in `ChatSheetContent.swift`. Text-level check only; no
  Swift compile was run.
- Git + rerere cold (chronological, empty cache): 1 reuse, correct. Seeded from an
  existing rr-cache: 84 reuses, 82 exact, 2 differing (documentation text). The seeded cache
  contains resolutions recorded after these merges, so that arm is optimistic availability
  leakage, not causal evidence of historical manual savings.

Limits: no human time is measured or estimated; "unresolved" is not an effort count.
Whole-merge outcomes are not compared across arms: the Mergiraf arm is a per-path driver
emulation without git index, rename, or modify/delete context. Renames were not modeled
for classification. The Mergiraf binary was an 0.20.0 release artifact, run only from
scratch and removed afterward; no CPU-time comparison is claimed.
