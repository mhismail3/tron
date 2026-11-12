# Tron home layout

A Tron home (`~/.tron` for Stable, `~/.tron-dev` for Debug, or `TRON_DATA_DIR`) holds
installation-scoped Tron data on the Mac. Shared host coordination keeps its existing
addresses. Current owned boundaries are declared once in
[`tron-home-layout.json`](../packages/gateway/src/foundation/tron-home-layout.json): its
owning module, writer, lifecycle, how it is rebuilt, whether it needs a backup, its
sensitivity, its retention rule and its view. Gateway code resolves paths only through
`tronHomePath()` / `tronWorkspacePath()` in `foundation/tron-home-layout.ts`.

## Groups

Top-level roots follow the owning process. Lifecycle is recorded per path, because a
root's owner, not its lifecycle, decides who may write, migrate or prune it.
`container: true` marks an aggregate whose child contracts override its descriptive
fields; it is not a recursive lifecycle or backup policy. `subtree: true` delegates
otherwise undeclared descendants to that boundary's owner. Explicit children take
precedence, including the personal Profile under `workspace/files`. A container alone
does not admit unknown children. External-owner subtrees are opaque; their registration
is not a claim about every descendant's contents or disposability.

Exports use the shipped export store limits: 30 minutes, 2 GiB per item, eight items,
four GiB total, four readers and one production, not the blob store's capacity.
Provider run retention has 30-day eligibility with terminal, reference and resumability
protection, bounded batches and tombstone grace; it is not unconditional expiry.
Installed Pi resources can contain user source and state. `internal` is mixed, including
durable machine identity and onboarding evidence, not recursively disposable scratch.

| Root | Owner | Holds |
|---|---|---|
| `agent/` | Pi SDK (its fixed layout), pi-subagents, extensions | settings, models, MCP, trust, credentials, subagent agents and profiles, prompts, skills, transcripts (`sessions/`), installed packages |
| `gateway/` | Gateway stores | devices and pairing, Home (record, settings layer, tasks, cwd), settings change log, automations, connections, uploads, displays, indexes, scratch, payloads |
| `workspace/` | `TronWorkspace` | lazy task `tmp/`, indexed documents in `files/` (including Profile), living owner collections in `state/`; [workspace policy](../packages/gateway/docs/internal-workspace.md) |
| `internal/` | delegation, Mac wrapper, dev scripts | subagent run scratch, managed pi-subagents installs, Mac wrapper markers, simulator leases |
| `logs/` | each writer rotates its own | Gateway, Mac, launcher, deploy, diagnostic exports |
| `ios-builds/` | `scripts/ios-share-publish.py` | phone install feed |
| `mac-terminal/` | `MacTerminalService` | sshd host key, config, authorized keys |

## Views

Each entry also carries `view`, the answer to "what kind of thing is this":

- **system**: runs the server, the Mac app and devices (credentials, pairing, payloads,
  indexes, scratch, logs, leases).
- **config**: how agents behave (`agent/{settings,models,mcp,trust}.json`, `agent/agents`,
  `agent/profiles`, `gateway/settings/`, `gateway/home/profile.json` (Home's settings
  layer), model queue, automations, connections).
- **knowledge**: what agents know and made (transcripts, skills, prompts, Home record,
  tasks and cwd, uploads, displays, `workspace/`).

## Why the views are not roots

Pi records each session's `cwd` and file path in canonical JSONL; parent transcripts name
subagent run directories and workspace documents. Moving `agent/sessions`,
`gateway/home/workspace`, `internal/subagents` or `workspace/files` would require
rewriting canonical transcripts or adding symlinks, and Pi fixes the names under
`agent/`. The Mac app and launcher read `gateway/{local-auth,enrollment,network,stop-completed}.json`,
`gateway/payloads/`, `logs/` and `internal/run`, so moving them is a Mac lockstep install.

## Profile

The personal Profile is one registered file, `workspace/files/Profile.json`, published
only by `ProfileStore`: one readable file among the workspace documents. The retired
`workspace/state/profile` namespace is never reused. The settings change log records each Profile edit
as subject `home.profile.item` for history and Undo; it is not the Profile.
`gateway/home/profile.json` is Home's settings layer (model, thinking), not the Profile.

## Read-only audit

```sh
scripts/tron home-layout audit --home /absolute/installation --json
```

`check` validates tracked source, not live disk. `audit` observes the explicitly selected
home's metadata and prints JSON to stdout only: source revision and manifest/tool SHA256,
root metadata, per-entry classification and matched contract, findings, errors, completion
and truncation state. Exit **0** means complete with no findings, **1** complete with
findings, **2** incomplete/error even when findings were also observed. Absent lazy paths
are not errors. Paths are component-matched; explicit child contracts override delegated
parents. A delegated document does not inherit its ancestor boundary's directory type.
Aggregate directories are enumerated; external/owner-delegated subtrees and
unknown directories are opaque unless declared child boundaries require enumeration.
`opaque` means descendants were not assessed, not that their contents are known safe.
The result is an ownership-boundary audit, not an inventory of every payload byte.

Traversal uses directory descriptors with no-follow opens for every home component and
child, no-follow stat, and directory identity/metadata checks across enumeration. Symlinks
and special files are reported, never opened; a symlink anywhere in the selected home
address refuses with exit 2. Use a physical absolute path for custom homes. Hidden entries
are included. Unknown directories, including backups, stay findings at their exact address.
No payload or credential bodies are read. The default budget is 10,000 entries;
`--max-entries N` selects a positive budget. Exhaustion is explicitly truncated, never clean.
Read errors and detected concurrent replacements/changes make the scan incomplete. This
is not an atomic snapshot: opaque contents and changes after observation are unassessed.
The OS may account for directory access times; audit invokes no filesystem mutation API.

There is no apply, output-file, quarantine, registration, permission repair, prune or
migration mode. No timer or daemon runs it. Source rollback is `git revert <audit-commit>`;
there is no live undo because audit does not write. Reports are not cleanup authority.
CLI-only changes need no app rebuild or install.

## Rules

- A new path is a registry entry first; `scripts/tron home-layout check` (a verify step)
  fails on an unregistered Tron-home literal in Gateway, Mac, script or tool source, and
  on any Gateway `join(tronHome, "...")` outside the registry module.
- Moving a path is a persisted-layout migration: a one-shot, backed-up, maintainer-approved
  change (AGENTS.md), never a second reader of the old location.
- `retention` names each entry's retention rule and its owner, or `null` when it has none.
  It does not implement cleanup or authorize deletion. Instructions (`agent/AGENTS.md`),
  workspace tmp, Debug PID and command shlock have registered owners. Historical backups
  and other unregistered residues remain unknown findings; there is no backup wildcard.
- Manifest metadata is included in compiled Gateway artifacts; source edits require a
  later coordinated Gateway rebuild/delivery to take effect there. CLI/docs alone do
  not require an app rebuild. No addresses, wire contracts or live bytes change.
