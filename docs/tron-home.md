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
| `owner` | The module (or exactly `pi-sdk`, `pi-subagents`, or `extension <package>`) that may write, migrate or prune the path | `check`: must name a module or an exact external owner; package names contain no whitespace |
| `class` | What is lost if the path is deleted: `keep` (irreplaceable), `rebuild` (its owner rebuilds it), `scratch` (working state, locks, in-flight work) or `log`. Stated on every top-level entry and wherever a child differs; otherwise inherited from the nearest ancestor | backup selection, `check`, `audit` |
| `backup` | Overrides the default, which is: `keep` is backed up, the other classes are not. Used for the selected Gateway payloads | Mac replace snapshot, Mac reinstall backup, `audit` |
| `type` | `fifo` for the Debug start gate; other entries use the ordinary file/directory checks | `check`, `audit`: a registered FIFO is allowed without opening it; another type is `expected_fifo` |
| `credential` | `true` when the path holds a key or token | `audit`: group or other access to the registered entry (a file, or the folder that holds the keys) is a `credential_mode` finding |
| `container` | An aggregate whose registered children carry their own contracts; it does not admit unknown children | `audit` |
| `subtree` | Undeclared descendants belong to this boundary's owner; explicit children still take precedence | `check`, `audit`, backup selection |
| `prune` | The release rule its owner enforces: `maxAge` (`30m`, `24h`, `14d`), `maxEntries`, `maxBytes`, `keepNewest`, or `when` for an event; `by` names the enforcer when it is not the owner. Required on every `rebuild` or `scratch` subtree. A bound covers everything the entry matches together: a subtree's contents, or all files a pattern matches (`logs/deploy.jsonl*` is two 1 MiB files, so 2 MiB) | `check` |

The registry's `retired` list holds `{from, to}` moves for `migrate`; a path is
home-relative or starts with `~/`. It is empty when no layout change is pending.

Class and backup describe today's addresses, so a root can be mixed: `internal` is
`scratch` yet holds the `keep` machine identity and Mac onboarding evidence, and
`gateway` is `keep` yet holds receipts, staging and rebuildable indexes. A `prune.when`
of "not pruned" records a known gap, not a rule. Exports use the export store's limits (30
minutes, 2 GiB per item, eight items, four GiB total, four readers and one production),
not the blob store's. Provider run retention is 30-day eligibility with terminal,
reference and resumability protection, not unconditional expiry. Installed Pi resources
can contain user source and state. `gateway/settings/observed.json` is `keep` because it
is the baseline that outside-change detection compares against, and
`gateway/model-recents.json` because nothing rebuilds the user's recent models. Mission
records (`agent/missions`), unread state (`gateway/session-attention.json`), Mac setup
progress (`internal/mac`) and the onboarding marker (`internal/run/.onboarded`) are
`keep` for the same reason: losing one is visible and nothing regenerates it.

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
`backup` flag says so, and **every path the registry does not know is copied too**,
wherever it sits (an unregistered file in `logs/` is copied; the registered log files
beside it are not). A path under a `subtree` entry is known: it belongs to that entry and
follows it; so does a name that an entry's pattern matches (`logs/mac.jsonl.bak` matches
`logs/mac.jsonl*`). Nothing is skipped because of its age or size.

- `scripts/tron mac replace` clones the selection into the operation's `state-snapshot-<n>`
  before the swap, building it as `partial-state-snapshot-<n>` first so an interrupted
  clone is rebuilt whole. Symlinks are cloned as links. Folders that are only partly
  selected are created owner-only. The runner works from a private copy of the registry
  and of `home_layout.py`, staged and validated with the runner's scripts each time the
  runner is launched (a resumed operation takes them from the checkout that resumes it).
- `scripts/tron mac reinstall` stages the registry in its operation directory when the
  operation begins, then inventories and copies the selection; its frozen-source check
  covers the same paths. Its receipt records the staged registry's SHA-256; a missing
  digest or changed registry refuses with an instruction to preserve the operation and
  begin again with `--restart`. A path outside the selection may change during the offline window.

Both skip logs, rebuildable indexes and runtimes, scratch and locks, and
`gateway/local-auth.json` and `gateway/enrollment.json`, which the Gateway regenerates at
start. Provider credentials (`agent/auth.json`) are copied. The selected Gateway payloads
(`gateway/payloads`) are not copied: replace, and reinstall's `--select-bundled-offline`,
move the Stable channel into the operation instead, and a channel left in place is restored
by redeploying.

## Read-only audit

```sh
scripts/tron home-layout audit --home /absolute/installation --json
scripts/tron home-layout audit --home /absolute/installation --maintenance /absolute/maintenance --json
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
and unregistered special files are reported, never opened; the registered Debug start FIFO is allowed; a symlink anywhere in the selected home
address refuses with exit 2. Use a physical absolute path for custom homes. Hidden entries
are included. Unknown directories, including backups, stay findings at their exact address.
No payload or credential bodies are read. The default budget is 10,000 entries;
`--max-entries N` selects a positive budget. Exhaustion is explicitly truncated, never clean.
Read errors and detected concurrent replacements/changes make the scan incomplete. This
is not an atomic snapshot: opaque contents and changes after observation are unassessed.
The OS may account for directory access times; audit invokes no filesystem mutation API.

Audit has no apply, output-file, quarantine, registration, permission repair, prune or
migration mode. No timer or daemon runs it. Source rollback is `git revert <audit-commit>`;
there is no live undo because audit does not write. Reports are not cleanup authority.
CLI-only changes need no app rebuild or install.

`--maintenance PATH` explicitly includes a maintenance index check, without implicitly
reading a sibling home. Its owner-only recovery copies are never opened. Every immediate
entry other than `README.md`, and every entry immediately under `backups/`, needs one
Markdown table row in the root `README.md`: `Entry`, `Owner` and a column containing
`rule` are required headers; `Former name` and `Created` may be included. Entry names are
relative to that root, optionally in backticks. Missing, duplicate or blank owner/rule rows
produce `maintenance_index` findings. An absent README is a finding for each unindexed
entry; an unsafe or unreadable index is an incomplete audit. The tool never edits the index.

`workspace/state/x-library` belongs to the installed `x-library` skill.
`ios-builds/iphone-install` belongs to `ios-device-install`; it is conservatively `keep`
until that owner enforces its planned newest-three-per-app rule. Registry metadata does
not pretend that an unenforced retention rule exists. Managed pi-subagents' existing
`not pruned` entries remain an explicit unresolved retention gap, not deletion authority.

## Offline migration

```sh
scripts/tron home-layout migrate --home /absolute/installation --dry-run
scripts/tron home-layout migrate --home /absolute/installation --status
```

These two modes print JSON and change nothing. `--dry-run` lists
each `retired` move with its source and destination, the source's identity (type, device,
inode, mode), its state (`pending`, `done`, `conflict`, `absent`) and what an apply would
refuse: `destination_exists`, `unsafe_type` (a symlink or special file), `symlink_component`
(a symlinked parent on either side), `parent_not_directory` and `cross_volume`. `~/` paths
resolve against `$HOME`, printed as `user_home`. `blockers` holds `gateway_running`
when the home's agent-runtime lock was refreshed in the last 60 seconds, and
`debug_gateway_running` when the sibling Debug lock was refreshed. Planning does not
acquire or clear locks. `--status` prints
the overall state (`nothing_declared`, `nothing_to_move`, `not_started`, `partly_applied`,
`applied`, `conflict`) and each move's state. For `--dry-run`, exit **0** means nothing
would be refused and **1** a refusal or a blocker. For `--status`, exit **0** means no move
is pending and **1** a pending move or a conflict; blockers are printed but do not change
it. Exit **2** is an unreadable home or registry. Sizes are the entry's own metadata; no tree is
walked and no payload body is read. Planning may read the tool's own bounded private journals
to prove already-moved identities; it does not create journals or lock directories.

The registry currently declares only recovery-copy renames. After the maintainer approves
an offline live step, `--apply` creates a private journal under
`$HOME/.tron-maintenance/layout-v2/<registry-sha256>.json`, then renames the selected entries
with atomic no-clobber operations. No credential or recovery-copy body is read, cloned,
rewritten or pruned. Modes and inodes survive. `--rollback` requires that journal and
inverts only its moves, carrying later writes back rather than restoring old snapshots.
Both modes acquire the selected home's and Debug's agent-runtime lock directories; any
existing lock, even stale, refuses rather than stealing it. The Debug home and agent
parents are created lazily only in these mutating modes. A held lock or a planning refusal
causes no mutation. While a migration runs, a heartbeat keeps its locks fresh.
A crash leaves lock directories behind: this tool refuses them until explicit offline owner
recovery, but a Gateway's `proper-lockfile` can reclaim them after 60 seconds. Keep both
Gateways stopped through recovery; these locks alone do not make a partly moved home
safe to start.

One journal owns all moves for that registry digest across homes. Every move binds its
owning home, logical source/destination and original device/inode. The shared Debug lock
serializes all homes' writes to it. It is fsynced before any rename; rename parents are
fsynced too. Resume infers a completed rename only from the same inode at its recorded
destination. A pending move reserved by another home refuses even after a crash, so shared
paths never acquire two owners. Forward apply journals newly present registered sources
before moving them and refuses success if a pending move remains. Each home's rollback
inverts only its own records, in either home's rollback order, carrying current data back.
After each inverse rename it removes that move's claim and fsyncs the journal before the
next move. A crash between rename and release retains the claim for an idempotent retry;
a completed rollback releases it so either home can acquire the restored source. A valid
journal with no moves owned by this home returns `nothing_to_rollback` without writing.
Planning checks the same journal ownership and identity constraints before reporting a
clear dry run. A different registry digest cannot use a previous journal as proof of an
already-moved destination; finish both homes against the same registry. A replaced entry, occupied
inverse destination, changed registry or unknown pre-existing destination refuses. It never
replays an uncertain rename. The journal and `layout-v2` maintenance index row are retained
for review, never automatically discarded. `--apply`/`--rollback` are code capabilities,
not permission to use them on a live installation. Root renames, stored-path rewrites and
Gateway startup stamps are not part of this recovery-copy slice.

Before applying, keep both Gateways offline, use the same checkout and registry for both
homes, and review the dry run and maintenance index. The journal intentionally fails closed
for every home if any recorded identity is missing or replaced: stop, preserve the journal
and remaining copies, and obtain an owner-reviewed recovery plan rather than editing claims
or replacing a copy to bypass its inode proof. Do not change the registry between homes'
applies; a new digest does not inherit old reservations. This conservative coupling avoids
silently discarding another home's recovery evidence.

## Rules

- A new path is a registry entry first; `scripts/tron home-layout check` (a verify step)
  fails on an unregistered Tron-home literal in Gateway, Mac, script or tool source, and
  on any Gateway `join(tronHome, "...")` outside the registry module. It reads `~/.tron`
  and `~/.tron-dev` literals, shell variables bound to a home or a path in one
  (`STATE_DIR="$HOME/.tron-dev/gateway"`, then `"$STATE_DIR/dev.pid"`; also
  `"${OVERRIDE:-$HOME/.tron/x}/child"`), joins wrapped in `resolve()`, and chained Swift
  `appendingPathComponent` chains, including chains split across lines. Other split-line
  calls and Swift paths built from named constants are not resolved.
- Moving a path is a persisted-layout migration: a one-shot, backed-up, maintainer-approved
  change (AGENTS.md), never a second reader of the old location.
- `prune` states the rule an owner enforces. The registry does not implement cleanup or
  authorize deletion. Historical backups and other unregistered residues remain unknown
  findings; there is no backup wildcard.
- Manifest metadata is included in compiled Gateway artifacts; source edits require a
  later coordinated Gateway rebuild/delivery to take effect there. CLI/docs alone do
  not require an app rebuild. No addresses, wire contracts or live bytes change.
