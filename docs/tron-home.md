# Tron home layout

A Tron home (`~/.tron`, `~/.tron-dev`, or `TRON_DATA_DIR`) holds installation-scoped
Mac data. Shared host coordination keeps its existing addresses. Owned boundaries are
declared once in [`tron-home-layout.json`](../packages/gateway/src/foundation/tron-home-layout.json)
(version 2). Gateway code resolves paths through `tronHomePath()` / `tronWorkspacePath()`.

## Registry

Unknown fields fail `check`. Explicit child contracts override inherited contracts.

| Field | Meaning and consumer |
|---|---|
| `owner` | Writing/migrating/pruning module, or exactly `pi-sdk`, `pi-subagents`, or `extension <package>`; `check` validates it |
| `class` | `keep` (irreplaceable), `rebuild`, `scratch` (working state/locks), or `log`; inherited from the nearest ancestor; used by backup selection and audit |
| `backup` | Overrides the class default; used for prepared Gateway payload selection |
| `type` | `fifo` admits the registered Debug start gate without opening it; other special files fail audit |
| `credential` | Group/other access to the registered file or key-holding folder is an audit finding |
| `container` | Aggregate whose children need their own contracts; unknown children are not admitted |
| `subtree` | Undeclared descendants belong to this owner; used by check, audit and backup selection |
| `prune` | Owner-enforced `maxAge`, `maxEntries`, `maxBytes`, `keepNewest`, or event `when`; optional `by` names the enforcer |

A bound covers the whole matching set, not each match separately. A rebuild/scratch
subtree requires a prune rule. `prune` documents enforcement; the registry neither
performs cleanup nor grants deletion authority. `not pruned` records an owner gap.

## Roots

| Root | Holds |
|---|---|
| `agent/` | Pi's fixed settings/models/MCP/trust/auth/resources layout, transcripts, subagent definitions and profiles |
| `state/` | devices/pairing, Home record/settings/tasks/cwd, settings history, automations, connections, uploads, displays, delegated-run records, selected Gateway payloads, machine identity, Mac progress and private SSH identity |
| `cache/` | network discovery, search/catalog indexes, managed pi-subagents installs and transform cache |
| `workspace/` | lazy task `tmp/`, indexed documents in `files/`, living owner collections in `state/`, and `builds/ios-ota/`; [workspace policy](../packages/gateway/docs/internal-workspace.md) |
| `logs/` | bounded Gateway, Mac, launcher, deploy and diagnostic logs, each rotated by its writer |
| `internal/` | existing host-wide simulator/device/coordination leases, not installation data |

`repo/ios` owns the remaining `internal/` and `internal/run/` containers: their
children coordinate shared simulator/device leases and host slots. Mac onboarding
and version markers belong to `mac-app/server` under `state/mac/`.

Roots can be mixed: `state` is keep but contains scratch receipts and rebuildable queues.
Observed settings, recent models, mission records, unread state and Mac setup evidence
are keep because losing them is visible and nothing reconstructs them. Exports retain
the export store's limits: 30 minutes, 2 GiB per item, eight items, four GiB total and
four readers. Provider retention is 30-day eligibility with terminal, reference and
resumability protection, not unconditional expiry.

Pi fixes the layout beneath `agent/`. A session header owns its cwd; the encoded cwd
selects the session directory. Offline migration changes those together, preserving
session IDs and every transcript body byte. Historical messages, opaque extension
bindings, launch digests and completed handoff evidence are not rewritten. There are
no symlinks, alternate readers or old-address fallbacks. Mac, Gateway and iPhone consume
the layout in lockstep.

The personal Profile is `workspace/files/Profile.json`, published only by `ProfileStore`.
`state/home/profile.json` is Home's settings layer, not the Profile. The retired
`workspace/state/profile` namespace is never reused.

## Backups

Mac replace and reinstall select by the registry. Keep data is copied, as is **every
unregistered path**, wherever it appears. Subtree descendants are known and follow that
boundary; explicit children override it. Nothing is skipped merely because it is old
or large. Logs, reconstructible indexes/runtimes, scratch/locks, and regenerated
`state/{local-auth,enrollment}.json` are excluded. Provider credentials are copied.
Prepared `state/payloads` are not copied: replace and bundled-offline reinstall
move the Stable channel into the operation, or restore it by redeploying.
`state/subagents` is backed up: delegated-run evidence and resumable results are not
rebuildable; its owner's release policy is independent of backup selection.

The registry classifies canonical names only. Before migration, old `gateway/`,
`internal/` and `ios-builds/` addresses have no compatibility classification; unknown
paths are copied conservatively, including regenerated old-path credentials. Recovery
copies stay local under the private maintenance operation, never in a synced or uploaded
location. Data recovery files are restricted to `0600` and directories to `0700`,
without following symlinks or changing source modes. Reinstall retains original source
metadata in its frozen inventory; the separate app-bundle copy preserves executable
metadata. Source ACLs and extended attributes are preserved verbatim; mode restriction
is not ACL removal. These are evidence-grade byte copies, not launchable executable
trees, except the separate app bundle. Existing Time Machine or other system backups
may include the maintenance store and must be reviewed in the migration packet.
Never sync or upload a recovery copy. The migration approval packet must explicitly disclose the
old-path credential copies rather than silently excluding or redacting them.

- Replace builds `partial-state-snapshot-<n>` before publishing `state-snapshot-<n>`;
  interrupted partial snapshots are rebuilt. Symlinks are copied as links and partly
  selected folders are owner-only. Its private runner stages the registry and layout
  Python modules from the checkout that launches/resumes it.
- Reinstall freezes the selected paths and stages the registry SHA-256. A missing or
  changed staged digest refuses and requires preserving the operation before restart.
  Paths outside the selection may change during the offline window.

`workspace/state/x-library` belongs to its installed skill. The private iPhone-install
feed remains conservatively keep until its owner enforces newest-three-per-app retention.
Managed pi-subagents retention gaps are not deletion authority.

## Read-only audit

```sh
scripts/tron home-layout audit --home /absolute/installation --json
scripts/tron home-layout audit --home /absolute/installation --maintenance /absolute/maintenance --json
```

Audit reports source/manifest/tool digests, metadata, classification, effective backup,
findings, errors and truncation for the explicitly selected home only. Exit **0** is
complete/clean, **1** complete with findings, **2** incomplete/error. Absent lazy paths
are not errors. Delegated documents do not inherit a directory type. Unknown/delegated
subtrees are opaque unless explicit child boundaries require enumeration: opaque does
not mean assessed safe.

Traversal uses no-follow directory descriptors, stat and identity checks. Symlinks and
unregistered special files are reported, never opened; the registered Debug FIFO is
allowed. A symlink in the selected home address refuses. Use physical absolute paths.
Hidden entries are included. The default 10,000-entry budget is adjustable with
`--max-entries`; exhaustion is truncated, never clean. Concurrent replacement or read
errors make the scan incomplete. It is not an atomic snapshot. Payload and credential
bodies are not read. The OS may account for access times; audit invokes no mutation API.

`--maintenance` checks an explicitly supplied owner-maintained README index without
opening recovery-copy bodies. Every immediate entry except `README.md`, and every
immediate `backups/` entry, needs one table row with `Entry`, `Owner` and a rule column.
Entries are root-relative; duplicate, missing or blank rows are findings. Audit never
edits that index. It has no apply, quarantine, repair, prune or migration mode. Reports
are not cleanup authority; CLI-only audit changes require no app install.

## Offline migration

```sh
scripts/tron home-layout migrate --home /absolute/installation --dry-run
scripts/tron home-layout migrate --home /absolute/installation --status
```

These modes observe only the explicit home and `$HOME`, printed as `user_home`. They
list retired moves, device/inode/mode, pending/done/conflict/absent state, refusals,
owned runtime-address changes and private SSH intent. Planning reads bounded metadata
and private journals, not transcript bodies. Each rewrite-selection walk keeps its 100,000-examined-entry
cap and selects owned directory/name shapes before descending: session JSONL headers,
upload metadata, flat Home tasks, mission records/state, and pinned subagent run,
configuration and result-index records. Session, upload, task, mission and subagent
artifact trees are not traversed; their directory entries still count in the admitted
parent. File patterns select regular files, and directory patterns descend only into
directories. Other regular-file/directory artifacts remain opaque, including empty
config-named directories; matching symlinks and special files still refuse.
Rollback refuses without changing home contents or journal bytes
when a journaled record is missing from the current selection, including a record moved
into an artifact tree; the runtime lock is taken and released first. Keep rollback and
old data until the live migration is verified; only then may retention or deletion run.
Deleted journaled records refuse rather than implicitly restoring or skipping them.
Planning never creates/clears locks, writes configuration or actuates launchd. Dry-run exit **0** is clear, **1** refused/blocked,
**2** unreadable/unsupported. Status exit **0** means no pending move, **1** pending or
conflicting; blockers are printed without changing that status exit rule.

Stop Gateway and Mac app → migrate → start. Unsafe files, symlinked components,
occupied targets, cross-volume moves and unregistered relocated entries refuse.
Admission requires a stopped home: the Gateway runtime lease is absent or stale,
the Mac wrapper's whole-file kernel locks are released, and same-user kernel process
arguments, environment and open-file owners do not bind any process to the target.
Unreadable ownership refuses as `stopped_proof_unavailable`; a live owner refuses as
`gateway_running`, `mac_wrapper_running` or `home_process_present`. These probes are
target-scoped, not a production-global process-name grep: a private copy may be
rehearsed while another home is running. Apply reclaims only stale runtime leases
after the stopped proof, holds Gateway leases and Mac wrapper kernel locks through
the operation, and checks ownership again before publishing ready. The sibling Debug
lease also serializes the shared maintenance journal. A new standalone writer must
not be launched during the offline window.

Historical lifecycle projections are not liveness. Nonterminal status records are
carried byte-for-byte and listed as `interrupted-at-migration` in
`carried_lifecycle_records` in the report and per-home journal receipt. Malformed
status JSON, oversized status files and opaque status-named directories are also
carried unchanged and listed with their reason; file receipts include SHA-256.
Opaque directory contents are not traversed or repaired. No status is marked terminal,
no process-terminal or handoff projection grants/refuses migration, and no cleanup
runs. Terminal status records still receive only owned address rewrites. Normal
Gateway/SDK startup owns lifecycle reconciliation; migration neither resumes work
nor introduces an alternative reconciliation reader.

`--apply` and `--rollback` are prepared capabilities, not permission to migrate a live
installation. Keep both Gateways offline through the maintainer-approved operation and
recovery. Use the same source and registry for both homes. Review dry-run and maintenance
index first; migration does not edit the index. Copies and snapshots are retained.

One private journal at `$HOME/.tron-maintenance/layout-v2/<registry-sha256>.json` owns
moves across homes. Claims bind home, logical endpoints and device/inode. The shared
Debug lease serializes writes. A claim reserved by another home refuses even after a
crash. Inverse releases each claim durably after its rename; another home can then
acquire the restored source. Unknown/replaced destinations and changed digests refuse.
A completed rename is inferred only from its inode, never replayed speculatively.

Per-home receipts bind provenance and full-file SHA-256 snapshots beneath
`backups/2026-11-12-2500-layout-v2-<home-tag>/<layout-id>/{forward,rollback}/` in the
maintenance root. Private filesystem clones are verified before current metadata
changes. The journal's 16 MiB reader/writer budget preflights forward and inverse receipt
growth. Changed sources or damaged snapshots refuse. Session bodies are streamed and
hash-checked during atomic header replacement. Rewrites select schema-owned trust keys,
observed settings instances, Home targets, uploads, mission runtime locators, provider
recovery/results/fanout locators and private SSH config paths; unknown containers and
opaque history are not interpreted recursively as addresses. Pinned nested-child,
parallel-child and import/resume locators are owned fields. Runner configurations
rewrite structured-output file locators, never their schema or model result bodies;
status/result `structuredOutput` values remain opaque. Parallel-group counters have
no path fields. Symlinked homes and ancestors refuse before cwd encoding or SSH
label selection; the admitted home address must be physical.

Inverse carries current files and appended bodies back. Before/after provenance avoids
restoring old whole files or blindly reversing every new-prefix string. Values already
using the new prefix stay unchanged. Forward/inverse snapshots remain intact. Partial
forward or inverse operations resume through the same receipt and inode checks.

Admission closes with `state/layout.json` containing `{"version":2,"migrating":true}`
before effects. Ready `{"version":2}` follows the durable applied receipt. Retired roots
receive exact refusal markers. Startup checks again under its runtime lease before
persisting configuration; legacy/partial layouts refuse with the migration command.
The entrypoint may append a fatal-startup diagnostic, but initializes no second tree.

### Private SSH

The owned launch-agent plist is the sole enabled-intent authority. Migration backs up
the old plist/config, proves the exact job/root/label/config, boots that job out, verifies
absence, and removes its obsolete plist. Root lifecycle leases stay fenced by inode
through renames. Host and authorized keys move without regeneration; inodes survive.

Enabled SSH receives a plist for the new root/label. Gateway startup restores it
automatically, generating current assigned-Tailnet-IPv4 config with its existing verified
identity. Missing/corrupt identity never triggers rotation. Disabled SSH gets no enabled
plist and stays off. Startup failure retains intent and emits
`mac-terminal.startup-failed`; the existing `macTerminal.status` RPC exposes
`serviceState: "failed"` with the identity/job refusal detail. Chat remains available;
SSH is visibly degraded, not silently disabled. It never selects wildcard exposure
or stops a foreign port owner. Inverse retires the new job, carries current intent back, restores old-root
config/plist and bootstraps only when enabled. An unpublished partial operation recovers
original intent from the receipt. Native proofs use uniquely rooted disposable homes,
launch agents and ports, never production labels.

### Interrupted operations

Agent leases refresh while held. SSH leases use the proper-lockfile directory protocol
and follow their parent by proved inode. Every existing lease, even stale, refuses apply;
migration never steals it. A crash can leave leases behind. Keep both Gateways stopped,
preserve journal/snapshots and obtain exact owner-reviewed recovery, rather than editing
claims or substituting copies. Consumers have their own stale reclaim rules; these do
not make a partly migrated home safe to start. Completion failures retain the specific
metadata errors/refusals in the JSON `completion` field.

## Rules

- Register paths first. `scripts/tron home-layout check` validates Gateway/Mac/script/tool
  literals and rejects Gateway home joins outside the registry owner. It recognizes
  home-bound shell variables, nested joins and Swift appending-path chains; not every
  dynamically constructed path is statically resolved.
- Moves are backed-up, maintainer-approved one-shot migrations, never second readers.
- Prune rules describe actual owner enforcement, not permission to delete or wildcard
  registration for historical backups.
- Registry metadata ships in compiled artifacts. Runtime path changes need coordinated
  Mac/Gateway/iPhone delivery; source preparation never performs delivery or live migration.
