# Tron internal workspace

`<tronHome>/workspace` is Tron's durable internal home, not a session's working
directory or a project registry. Stable normally uses `~/.tron/workspace`;
Debug/custom installations use their own resolved `tronHome`. The root is never
inferred from pairing identity, browser preferences, or the current project.

## Ownership and layout

- `files/`: ordinary, deliberately retained documents. Existing filesystem tools
  may read/write these using the resolved absolute root. Subdirectories are lazy.
- `state/<owner>/`: reserved for a real capability's managed data. Knowledge is
  owned by `KnowledgeStore` under `state/knowledge/`; its canonical state,
  immutable content objects, coverage, suppression and cleanup evidence must be
  accessed through that owner, not arbitrary edits. Other namespaces have no
  generic state API. Use the capability's owning interface when one exists.
- `internal/machine-group-id`: one shared Stable/Debug physical-machine
  identity. The retired `~/.tron-machine-group-id` is never read on startup;
  missing or conflicting legacy/canonical files require the explicit operator
  migration command. The value is opaque identity bytes, not a credential.
- `internal/subagents/`: the installed delegated provider's existing
  `PI_SUBAGENTS_TEMP_ROOT` root; its `async-subagent-runs/` child is the only
  lifecycle subtree admitted by Gateway. Provider project/session artifacts,
  retention, cancellation and cleanup remain provider-owned.
- `internal/mac/wizard-state.json`: the Mac wrapper's versioned owner-only wizard
  progress record. `.onboarded` remains the only completion authority.
- Pi's `agentDir` remains authoritative for canonical JSONL, settings,
  credentials, installed packages/resources, retries, and compaction. Gateway
  state remains under `<tronHome>/gateway`; existing extension stores stay with
  their current owners. There are no mirrored sessions or relocated stores.

The generic filesystem browser still browses supported Mac directories, including
hidden folders, and still supports folder creation. Session directory selection,
recent directories, project trust, worktrees, and Automation cwd capture are
unchanged. Merely using this root never changes a session cwd or grants trust.
No workspace document is automatically collected or loaded as global instructions.
Secrets belong in existing credential stores, not workspace documents. Internal-layout publications keep a resumable marker beside staging; recovery completes a source-retired rename only after validating the staged bytes and destination absence, and never recreates a missing authority.

## Initialization, failure and recovery

`TronWorkspace`, owned by `RuntimeRegistry`, creates only an owner-only root and
minimal lifecycle evidence at `gateway/workspace-state/initialized.json` (version
1). It reuses bounded secure reads and durable atomic JSON publication. It holds
a cooperative, refreshed `proper-lockfile` lock on `gateway/workspace-state` for
its lifetime; another owner cannot initialize/use this workspace through this
service. It releases that lock on disposal; crashed-owner locks expire under the
existing lock protocol. Canonical session ownership is still independently
protected by the agent-runtime lock.

An existing safe directory is adopted without scanning or changing its contents.
The installation home, Gateway state directory and workspace root must be real,
current-user-owned directories with mode `0700`. A file, symlink, wrong owner,
missing owner access, or group/world permissions is preserved and rejected,
not automatically repaired. Invalid, oversized, or unknown-version lifecycle
evidence is likewise preserved. Initialization/ownership failures make the
workspace unavailable but do not disable unrelated project sessions.

Once initialization evidence exists, a missing root is **not recreated**. During
one owner lifetime, disappearance or device/inode replacement also makes it
unavailable. There are no fallback writes into `$HOME`, `.pi`, or the project.
The current runtime stays unavailable after such a failure; recovery is a manual
operator action, followed by a user-initiated Gateway lifecycle transition. Restore
the original workspace (or deliberately select a restored safe directory at that
exact root), retain valid lifecycle evidence, and investigate corruption before
changing either. Never delete unknown/newer metadata to force acceptance.

Backups should preserve the workspace and its lifecycle evidence together, and
preserve the separate Pi/Gateway owners needed for a complete installation restore.
Mac application update/uninstall cleanup and local settings/credential reset do
not remove workspace documents, managed namespaces, or lifecycle evidence. This
is not an automatic backup mechanism. Advisory locks and path validation are not
a same-user sandbox: shells/editors can bypass them, and deliberate concurrent
same-user filesystem replacement is not transactionally fenced.

## Operating context and presentation

The first-party `tron-core` extension additively supplies Tron identity, mobile-
first guidance, the exact execution cwd, resolved root/availability, ownership,
and active-tool guidance on every agent start. It neither replaces the SDK/project
prompt nor appends context messages to JSONL. Gateway new, continued, resumed,
reloaded, forked, post-compaction, and Automation turns use this same runtime path.
Compaction remains SDK-owned; its summary is not a new workspace store.

Use the existing `display` tool with:

```json
{
  "title": "Report",
  "altText": "The retained report",
  "source": { "kind": "internal_file", "path": "reports/summary.md" }
}
```

`internal_file` resolves only beneath `workspace/files`, independent of cwd.
The root must be available and `files` must already be a safe real directory.
Existing `path` sources remain session-relative; public URLs are unchanged.
Absolute paths, traversal, hidden components, symlinks, directories, and escaping
paths are rejected using the existing artifact ingestion policy. `state/` is not
an internal display root. Existing size/type/disk bounds, immutable authenticated
artifact copies, cancellation, retention, iOS renderers, and result schema remain
unchanged. An artifact is a presentation snapshot, not another editable document.

Gateway inline extensions do not automatically propagate to arbitrary child
runtimes. For direct **model tool calls** to `subagent`, Tron prefixes task/resume
text with a bounded advisory handoff; it preserves original task text, cwd,
read-only intent, and the runner's actual tool capabilities. Workflow VM launches,
slash/RPC/structured delegation, and further child launches bypass that hook:
explicitly repeat the facts in each stage/task. External one-shot runners can
receive direct task text, not native extension/fork/tool/supervisor inheritance.
No scripts, package installations, agent definitions, or global settings are
rewritten to manufacture inheritance. See the Gateway README's delegation
contract for the pinned API limits.

## Contract for future managed-state consumers

Implement storage only alongside its production capability and focused tests.
The current managed knowledge namespace is documented in `knowledge.md` and is
created lazily by `KnowledgeStore`; constructing a capability service alone must
not create real namespace state.

- One explicit owner per namespace; bounded reads, schema version, revision and
  validation before mutation. Reject and preserve malformed or newer data.
- Serialize the full read-modify-write across supported processes, check expected
  revision to reject stale updates, and use bounded retries/backoff where safe.
  Advisory locks do not constrain manual shell/editor writes.
- Reuse secure reads and unique temporary files, sync, atomic replacement and
  directory sync. Keep the prior valid value on pre-publication failure; distinguish
  post-publication uncertainty rather than blindly replaying a non-idempotent write.
- Define cancellation before admission, during work and after commit; make accepted
  retries idempotent using the capability's existing command/receipt owner.
- Give migrations an explicit version/owner, recovery/backup policy and failure
  tests. No silent schema downgrades, wholesale reset, or speculative framework.

These are requirements for future owning adapters, not guarantees supplied by an
unimplemented namespace API or by arbitrary filesystem tools today.

## Explicit internal-layout migration

`src/internal-layout-migration.ts` is an operator-run, fail-closed fixture for
retiring the machine-group source and other explicitly selected internal files.
Run `scripts/tron internal-migrate preflight|stage|verify|publish|recover|cleanup`
only against synthetic or a user-quiesced maintenance fixture. It requires
absolute paths, owner-only regular files, exact bytes/permissions, protected
backup and quiescence acknowledgements, and never merges an existing destination.
Staging leaves a durable marker on interruption. Publication retires the old
source before exposing the destination; recovery reports ambiguity rather than
choosing an authority. Gateway startup never invokes this tool or silently
regenerates identity. The command prepares state only; app replacement, Gateway
activation and retirement of live paths remain manual operator actions.

## Explicit delegated-provider root cutover

The pinned `pi-subagents` provider reads `PI_SUBAGENTS_TEMP_ROOT` before its
module initializes and derives its provider-owned trees from that root. Gateway
startup sets `<tronHome>/internal/subagents` only after a read-only inventory
proves no retained provider tree remains outside it. If retained artifacts are
found, startup fails with a migration-required diagnostic; it never silently
adopts a new root. The complete ordered command sequence, backup/quiescence,
reference and recovery checks, activation boundary, and GO/NO-GO checklist are
in the single [integrations cutover runbook](cutover-runbook.md). The delegated
owner contract and synthetic tests are in `delegated-root-migration.ts`; this
file intentionally does not duplicate its operator procedure.
