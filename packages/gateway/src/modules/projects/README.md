# gateway/projects

## Purpose

Gateway-owned project lifecycle for Home and ordinary chats, using the existing
native change-card authority and the canonical Project trust store. Delegated
workers share the ordinary tool surface, but cannot approve their own requests.

## Owns

`project-lifecycle.ts` owns names, filesystem/Git effects, identity checks and
GitHub command admission. `module.ts` owns the `projects` tool.
`runtime-admission.ts` reads canonical runtime/task owners; it stores no worker index. A listing reads
Home work once (one task-store pass for all rows), never once per folder or page of task history.

## Contract

- `create` takes a 1–64-character ASCII letter/digit/underscore/hyphen name starting
  with a letter or digit. It exclusively creates `~/Workspace/<name>` and initializes
  Git on `main` with no templates/hooks. Existing paths, traversal and symlinks refuse.
  Creation intent/completion/failure are logged in Settings Changes. The new exact
  directory is explicitly untrusted before Git initialization, even under default-always
  trust or an enclosing repository. A partial creation is retained, never deleted.
- Creation then requests `project.lifecycle` trust approval. `trust` retries only the
  approval phase for an existing standalone repository, not local creation.
  Optional `github` runs `gh repo create <name> --private --source <path> --remote origin`
  using existing authentication **after the tap**, before granting trust. It never pushes.
  Existing remotes refuse GitHub creation. A partial GitHub error stays untrusted;
  inspect the remote/local state before a new explicit request (never auto-recreate).
- `rename`, `archive` and `untrust` always request a maintainer tap. Rename retains
  the source's effective trust only after successful relocation. Archive moves to
  `~/Workspace/.archive/<name>-<uuid>` and explicitly untrusts it. The departed source
  name stays explicitly false, so reusing a name does not inherit its old grant.
- Recover an archive manually: release workers/claims, move its retained directory
  into an absent direct child of Workspace, then use `projects trust` for a new tap.
  No hard-delete, automatic reverse move or remote repository rename/delete exists.
  Historical session paths/transcripts are not rewritten. Close project sessions before
  a move; start new sessions at the resulting path.

The shared semantic UI broker presents the exact preview/digest and expires an
unanswered card after 24 hours. Only a paired maintainer response can accept it;
the trusted effect callback runs inside the canonical `extension.respond` receipt.
There is no settings approval queue or separate outcome store.
Home can delegate immediately after successful trust. Decline/expiry grant nothing.
An interrupted/failed action is never replayed; inspect retained paths and Changes.
A crash after a local creation intent may leave an unresolved audit row; it does
not imply success and is never replayed. If both runtime reload and compensation
fail, the native owner retires uncertain frames without a success publication and
releases project admission. Canonical session data stays intact; repair failing
resources before reopening the cold session. A refusal before filesystem effects
preserves trust only for the original retained source directory.
Repeating create refuses its existing path; a settled native interaction cannot
apply again. To retry a failed creation's trust phase, explicitly request `trust`.

## Invariants

- Mutation effects serialize in this owner and trust's existing mutation mutex. Moves
  acquire the native transactional trust-reload fence before rechecking worker admission.
  Source/destination are checked by directory identity; destinations are exclusively
  reserved and explicitly untrusted before moving, so a partial move fails closed.
- Active/pending Home tasks, busy project sessions, linked worktrees and retained local
  or remote claim branches refuse at submission and decision/effects. Moving also refuses
  idle live sessions. Claims are inspected only in the work tool's canonical branch
  namespace; more than 200 refs refuses bounded inspection. The claim owner must
  release/clean its branch; lifecycle never does.
- Filesystem checks and reservations exclude Gateway races and existing symlink escapes.
  Same-user processes are trusted: moves are best-effort, not a sandbox against
  another process with the same Mac user's authority. Such a process can replace a
  directory between OS calls or modify trusted resources afterward; pathname trust
  can consequently apply to a replacement. There is no no-TOCTOU guarantee against
  same-UID writers. An enforceable hostile-writer boundary requires OS authority
  separation, not another pathname check or advisory lock. Errors retain paths for
  inspection; inspect retained data before an explicit retry.
- Git subprocesses are bounded, noninteractive and ignore inherited `GIT_*` selectors;
  hooks/templates and repository-configured log signature programs do not execute.
  GitHub stderr/credential-bearing config is not returned.
- The shared native change card and iOS `ChangeReviewSheet` show action items.
  The `projects` tool waits in the asking chat for that card's decision; there is
  no `wait` option or separate pending-request API.

## Native RPC

Capability `projects.lifecycle.v1` is advertised in `system.info`. Module-host
routing uses the same owner as the agent tool, not a tool invocation from the UI.

- `projects.list({limit?, after?})` returns `{workspace, projects, nextCursor}`.
  Limit is 1–50 (default 25); cursor is the last returned name. It sorts visible
  direct Workspace folders/symlinks; directories over 1,000 entries refuse. Hidden
  archives are not listed. Folder paths/names and cursors retain exact whitespace;
  unsupported names are never trimmed into another project. Reads never adopt
  folders, grant trust or reserve moves.
- `projects.inspect({cwd})` reads one absolute folder path, including saved folders
  outside Workspace. Each row is `{name, path, trust, eligibility}`; trust is the
  existing TrustInspection or null for unsafe/uninspectable paths. Eligibility has
  `trust/github/rename/archive/untrust`, each `{allowed:true}` or
  `{allowed:false, code, reason}`. Unsupported layouts/names/outside folders are
  read-only; idle live sessions block moves; existing remotes block GitHub creation.
  These are disposable snapshots. Submission and decision always revalidate;
  rename destination validity/availability is checked on request.
- `projects.change({commandId, action, name, newName?, github?, reason, confirmation?})`
  without `confirmation` plans the action and returns `{status:"review", review, intent}`
  with no effects. Actions are create/trust/rename/archive/untrust; field bounds match
  the tool, with commandId 8–160 characters. Native UI identity is transport-derived,
  never caller-supplied; local clients cannot confirm. The shared card's Approve resends
  the request with `confirmation: {digest, intent}` under a new command ID; the owner
  revalidates canonical filesystem, Git, occupancy and trust state against the digest
  before effects. Create applies only after that tap and creates a trusted repository.
  Agent tools reach the same review through the native `change` interaction.

Canonical receipts bind caller + commandId + method: retries return the original
result even if their payload differs. A new intent requires a new ID; different
methods have separate receipt keys. Native UI terminal requests have no model
continuation/outbox; their canonical audit and receipts serve the caller.
A failed effect's audit append that itself fails, or an applied effect whose history
publication fails, is an uncertain outcome that keeps the receipt fence; inspect the
actual state before a new request. Disconnect cancels disposable reads, not accepted
mutations. Refresh after review/confirmation, reconnect/re-entry and trust/settings
changes. No second project cache, change stream or approval engine is introduced.

## Entry points

`ProjectLifecycle.register`, `ProjectLifecycle.request`, `projectsModule`,
`projectRuntimePort`; composition in `main/modules.ts` and `gateway-main.ts`.

## Signals

Settings Changes key `project.lifecycle` (started/applied/failed action facts) diagnoses
the phase. A failed or uncertain action instructs the requester to inspect operation
state before retry.

## Verify

```bash
scripts/tron test gateway src/modules/projects/project-lifecycle.e2e.test.ts
```

The real Gateway/Registry/Pi/faux-model journey retains a regenerable transcript in
`packages/gateway/test-results/project-lifecycle/report.json`. All projects are temporary;
GitHub success and authentication refusal use spawned fixture executables at the
external CLI port, never a live GitHub repository or host credentials. The refusal
journey runs with real Git but no `gh` on PATH and proves exit 4 leaves a real local
repository without remotes or trust. The success journey proves exact CLI arguments
and remote publication. These test Gateway handling, not the installed GitHub CLI's
authentication implementation; neither requires `gh`, Keychain or Seatbelt.
The list scale journey publishes one real task, derives 299 persisted input records
from those canonical bytes/name, then validates all 300 through the real Home reader.
It measures list reads, not sequential task admission and durability; the calibrated
bound and protection against per-folder/per-page history rescans remain unchanged.
Native cases invoke the real Gateway module route, receipts and exact native decisions:
create → trust → rename → untrust → archive, deny/replay, actual move eligibility,
unsupported folders, authenticated actor provenance and disconnect ownership.

## Not here

Native card presentation and acceptance: kernel host semantic UI broker. Trust records and
serialized relocation: kernel resources. Worker control/settlement: native delegation.
