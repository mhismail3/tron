# Tron home layout

A Tron home (`~/.tron` for Stable, `~/.tron-dev` for Debug, or `TRON_DATA_DIR`) holds
everything Tron writes on the Mac. Every path in it is declared once in
[`tron-home-layout.json`](../packages/gateway/src/foundation/tron-home-layout.json): its
owning module, writer, lifecycle, how it is rebuilt, whether it needs a backup, its
sensitivity, its retention rule and its view. Gateway code resolves paths only through
`tronHomePath()` / `tronWorkspacePath()` in `foundation/tron-home-layout.ts`.

## Groups

Top-level roots follow the owning process. Lifecycle is recorded per path, because a
root's owner, not its lifecycle, decides who may write, migrate or prune it.

| Root | Owner | Holds |
|---|---|---|
| `agent/` | Pi SDK (its fixed layout), pi-subagents, extensions | settings, models, MCP, trust, credentials, subagent agents and profiles, prompts, skills, transcripts (`sessions/`), installed packages |
| `gateway/` | Gateway stores | devices and pairing, Home (record, settings layer, tasks, cwd), settings change log, automations, connections, uploads, displays, indexes, scratch, payloads |
| `workspace/` | `TronWorkspace` | `files/`: agents' documents; `state/<owner>/`: Profile, episodic memory, apps |
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

`scripts/tron home-layout retention --home ~/.tron` prints each on-disk entry's size,
file count, age, lifecycle (or `NO-RULE`), view and rule.

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
Prune never proposes a registered file, so document retention cannot remove it.

## Rules

- A new path is a registry entry first; `scripts/tron home-layout check` (a verify step)
  fails on an unregistered Tron-home literal in Gateway, Mac, script or tool source, and
  on any Gateway `join(tronHome, "...")` outside the registry module.
- `scripts/tron home-layout audit --home DIR` lists on-disk entries no entry covers.
- Moving a path is a persisted-layout migration: add `retired: {from, to}`. The Gateway
  refuses to start while a `from` exists. `scripts/tron home-layout migrate --home DIR
  [--agent-dir DIR]` holds the agent runtime lock (refusing one refreshed in the last
  60 s), replaces `gateway/layout-migration/backup/<from>` with a complete copy, journals,
  moves, and is idempotent and resumable. It is the only reader of old locations and is
  forward-only for the running product: a payload built before the move cannot read the
  new place. Restoring one is an explicit maintainer action: stop Tron, run
  `migrate --rollback` (moves each destination back), then reinstall the prior payload.
  Running either on a live home is the maintainer's action; after accepting the
  cutover the maintainer deletes `gateway/layout-migration/`.
- Retention: `retention` names the rule and its owner, or `null` (reported as
  `NO-RULE`). `prune --home DIR --plan OUT [--files-older-than DAYS]` lists unregistered
  entries, unpinned pi-subagents installs and workspace documents untouched for DAYS,
  never a registered file or a retired source awaiting migration. `prune --apply PLAN
  --confirm DIGEST` deletes exactly that plan; if any candidate's size, file count or
  newest mtime changed it deletes nothing. Applying it is the maintainer's action.
