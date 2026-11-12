# Tron home layout

A Tron home (`~/.tron` for Stable, `~/.tron-dev` for Debug, or `TRON_DATA_DIR`) holds
installation-scoped Tron data on the Mac. Shared host coordination keeps its existing
addresses. Owned boundaries are declared once in
[`tron-home-layout.json`](../packages/gateway/src/foundation/tron-home-layout.json)
(version 2). Gateway code resolves paths only through `tronHomePath()` /
`tronWorkspacePath()` in `foundation/tron-home-layout.ts`.

## Registry entries

Every field has a consumer; an unknown field fails `check`.

| Field | Meaning | Acted on by |
|---|---|---|
| `owner` | The module (or `pi-sdk`, `pi-subagents`, `extension …`) that may write, migrate or prune the path | `check`: must be a module |
| `class` | What is lost if the path is deleted: `keep` (irreplaceable), `rebuild` (its owner rebuilds it), `scratch` (working state, locks, in-flight work) or `log`. Stated on every top-level entry and wherever a child differs; otherwise inherited from the nearest ancestor | backup selection, `check`, `audit` |
| `backup` | Overrides the default, which is: `keep` is backed up, the other classes are not. Used for a credential that is re-issued instead of restored and for the selected Gateway payloads | Mac replace snapshot, Mac reinstall backup, `audit` |
| `credential` | `true` when the path holds a key or token | `audit`: group or other access is a `credential_mode` finding |
| `container` | An aggregate whose registered children carry their own contracts; it does not admit unknown children | `audit` |
| `subtree` | Undeclared descendants belong to this boundary's owner; explicit children still take precedence | `check`, `audit`, backup selection |
| `prune` | The release rule its owner enforces: `maxAge` (`30m`, `24h`, `14d`), `maxEntries`, `maxBytes`, `keepNewest`, or `when` for an event; `by` names the enforcer when it is not the owner. Required on every `rebuild` or `scratch` subtree | `check` |

The registry's `retired` list holds `{from, to}` moves for `migrate`; a path is
home-relative or starts with `~/`. It is empty when no layout change is pending.

Class and backup describe today's addresses, so a root can be mixed: `internal` is
`scratch` yet holds the `keep` machine identity and Mac onboarding evidence, and
`gateway` is `keep` yet holds receipts, staging and rebuildable indexes. A `prune.when`
of "not pruned" records a known gap, not a rule. Export limits (30 minutes, eight items,
4 GiB) are the export store's, not the blob store's. Provider run retention is 30-day
eligibility with terminal, reference and resumability protection, not unconditional
expiry. Installed Pi resources can contain user source and state.

## Roots

| Root | Owner | Holds |
|---|---|---|
| `agent/` | Pi SDK (its fixed layout), pi-subagents, extensions | settings, models, MCP, trust, credentials, subagent agents and profiles, prompts, skills, transcripts (`sessions/`), installed packages |
| `gateway/` | Gateway stores | devices and pairing, Home (record, settings layer, tasks, cwd), settings change log, automations, connections, uploads, displays, indexes, scratch, payloads |
| `workspace/` | `TronWorkspace` | lazy task `tmp/`, indexed documents in `files/` (including Profile), living owner collections in `state/`; [workspace policy](../packages/gateway/docs/internal-workspace.md) |
| `internal/` | delegation, Mac wrapper, dev scripts | subagent run scratch, managed pi-subagents installs, Mac wrapper markers, simulator leases |
| `logs/` | each writer rotates its own | Gateway, Mac, launcher, deploy, diagnostic exports |
| `ios-builds/` | `scripts/ios-share-publish.py` | phone install feed |
| `mac-terminal/` | `MacTerminalService` | sshd host key, config, authorized keys |

## Why addresses are fixed

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

## Backups

Two tools copy a home and both select by the registry: a path is copied when its class or
`backup` flag says so, and **every path the registry does not know is copied too**.
Nothing is skipped because of its name or age.

- `scripts/tron mac replace` clones the selection into the operation's `state-snapshot-<n>`
  before the swap. The runner works from a private copy of the registry and of `home_layout.py`,
  staged and validated when the operation starts.
- `scripts/tron mac reinstall` inventories and copies the selection, and its frozen-source
  check covers the same paths. A path outside the selection may change during the offline
  window.

Both skip logs, rebuildable indexes and runtimes, scratch, the selected Gateway payloads
(the tools keep those separately), and `agent/auth.json`, `gateway/local-auth.json` and
`gateway/enrollment.json`, which are re-issued, never restored.

## Read-only audit

```sh
scripts/tron home-layout audit --home /absolute/installation --json
```

`check` validates tracked source, not live disk. `audit` observes the explicitly selected
home's metadata and prints JSON to stdout only: source revision and manifest/tool SHA256,
root metadata, per-entry classification, matched contract, effective class and backup, findings, errors, completion
and truncation state. Exit **0** means complete with no findings, **1** complete with
findings, **2** incomplete/error even when findings were also observed. Absent lazy paths
are not errors. Paths are component-matched; explicit child contracts override delegated
parents. A delegated document does not inherit its ancestor boundary's directory type.
A credential entry that group or others can access is a `credential_mode` finding.
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

## Migration plan

```sh
scripts/tron home-layout migrate --home /absolute/installation --dry-run
scripts/tron home-layout migrate --home /absolute/installation --status
```

Both print JSON and change nothing; there is no apply or rollback mode. `--dry-run` lists
each `retired` move with its source and destination, the source's identity (type, device,
inode, mode), its state (`pending`, `done`, `conflict`, `absent`) and what an apply would
refuse: `destination_exists`, `unsafe_type` (a symlink or special file), `symlink_component`
(a symlinked parent on either side) and `cross_volume`. `blockers` holds `gateway_running`
when the home's agent-runtime lock was refreshed in the last 60 seconds. `--status` prints
the overall state (`nothing_declared`, `nothing_to_move`, `not_started`, `partly_applied`,
`applied`, `conflict`) and each move's state. Exit **0** means nothing would be refused
(dry run) or nothing is pending (status), **1** means refusals, blockers or pending moves,
**2** an unreadable home or registry. Sizes are the entry's own metadata; no tree is
walked and no file body is read.

## Rules

- A new path is a registry entry first; `scripts/tron home-layout check` (a verify step)
  fails on an unregistered Tron-home literal in Gateway, Mac, script or tool source, and
  on any Gateway `join(tronHome, "...")` outside the registry module. It reads `~/.tron`
  and `~/.tron-dev` literals, shell variables bound to one (`STATE_DIR="$HOME/.tron-dev/gateway"`,
  then `"$STATE_DIR/dev.pid"`), joins wrapped in `resolve()`, and chained Swift
  `appendingPathComponent` calls. A Swift path built from a named constant is not read.
- Moving a path is a persisted-layout migration: a one-shot, backed-up, maintainer-approved
  change (AGENTS.md), never a second reader of the old location.
- `prune` states the rule an owner enforces. The registry does not implement cleanup or
  authorize deletion. Historical backups and other unregistered residues remain unknown
  findings; there is no backup wildcard.
- Manifest metadata is included in compiled Gateway artifacts; source edits require a
  later coordinated Gateway rebuild/delivery to take effect there. CLI/docs alone do
  not require an app rebuild. No addresses, wire contracts or live bytes change.
