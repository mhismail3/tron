# gateway/projects

## Purpose

Gateway-owned project creation and the paired-native trust review for Workspace
projects, using the existing native change-card authority and the canonical Project
trust store. Only Home changes an existing project's trust with the settings tool
(`permissions.projectTrust`); renames, archives and GitHub repositories use ordinary
`git`/`gh`. Delegated workers share the ordinary tool surface, but cannot approve
their own requests.

## Owns

`project-lifecycle.ts` owns names, creation effects, identity checks and the native
trust review. `module.ts` owns the `projects` tool and the native RPCs.
`runtime-admission.ts` reads canonical runtime/task owners; it stores no worker index. A listing reads
Home work once (one task-store pass for all rows), never once per folder or page of task history.

## Contract

- The `projects` tool takes `{name, reason}` and creates a project. The name is
  1–64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit.
  It exclusively creates `~/Workspace/<name>` and initializes Git on `main` with no
  templates/hooks. Existing paths, traversal and symlinks refuse. Creation
  intent/completion/failure are recorded in the settings change record. The new exact directory is
  explicitly untrusted before Git initialization, even under default-always trust or an
  enclosing repository, and becomes trusted only after the exact tap. A partial
  creation is retained, never deleted.
- Native `trust` and `untrust` always request a maintainer tap. To retry a failed
  creation's trust phase, request `trust`.

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
resources before reopening the cold session. Repeating create refuses its existing
path; a settled native interaction cannot apply again.

## Invariants

- Mutation effects serialize in this owner and trust's existing mutation mutex.
- Active/pending Home tasks, busy project sessions and linked worktrees refuse at
  submission and decision/effects.
- Filesystem checks exclude Gateway races and existing symlink escapes. Same-user
  processes are trusted: this is not a sandbox against another process with the same
  Mac user's authority. Pathname trust can apply to a directory replaced between OS
  calls; there is no no-TOCTOU guarantee against same-UID writers. Errors retain paths
  for inspection; inspect retained data before an explicit retry.
- Git subprocesses are bounded, noninteractive and ignore inherited `GIT_*` selectors;
  hooks/templates do not execute.
- The shared native change card and iOS `ChangeReviewSheet` show action items.
  The `projects` tool waits in the asking chat for that card's decision; there is
  no `wait` option or separate pending-request API.

## Native RPC

Capability `projects.lifecycle.v1` is advertised in `system.info`. Module-host
routing uses the same owner as the agent tool, not a tool invocation from the UI.

- `projects.list({limit?, after?})` returns `{workspace, projects, nextCursor}`.
  Limit is 1–50 (default 25); cursor is the last returned name. It sorts visible
  direct Workspace folders/symlinks; directories over 1,000 entries refuse. Hidden
  folders are not listed. Folder paths/names and cursors retain exact whitespace;
  unsupported names are never trimmed into another project. Reads never adopt
  folders or grant trust.
- `projects.inspect({cwd})` reads one absolute folder path, including saved folders
  outside Workspace. Each row is `{name, path, trust, eligibility}`; trust is the
  existing TrustInspection or null for unsafe/uninspectable paths. Eligibility has
  `trust/untrust`, each `{allowed:true}` or `{allowed:false, code, reason}`.
  Unsupported layouts/names/outside folders are read-only. These are disposable
  snapshots; submission and decision always revalidate.
- `projects.change({commandId, action, name, reason, confirmation?})` without
  `confirmation` plans the action and returns `{status:"review", review, intent}`
  with no effects. Actions are create/trust/untrust; field bounds match the tool,
  with commandId 8–160 characters. Native UI identity is transport-derived, never
  caller-supplied; local clients cannot confirm. The shared card's Approve resends
  the request with `confirmation: {digest, intent}` under a new command ID; the owner
  reconstructs the validated typed intent independently of JSON object-key order,
  then revalidates canonical filesystem, Git, occupancy and trust state against the
  digest before effects. Create applies only after that tap and creates a trusted repository.
  The agent tool reaches the same review through the native `change` interaction.

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

Settings change record key `project.lifecycle` (started/applied/failed action facts) diagnoses
the phase. A failed or uncertain action instructs the requester to inspect operation
state before retry.

| Signal | One-step diagnosis / boundary |
| --- | --- |
| `projects.change` conflict, “Project changed since review” | Compare the reviewed typed intent and current filesystem/Git/trust state before requesting a new review. JSON object-key order alone is not an intent change; the create/untrust reordered-confirmation journey protects that distinction and still refuses a wrong digest. |

## Verify

```bash
scripts/tron test gateway src/e2e/modules/projects/project-lifecycle.e2e.test.ts
```

The real Gateway/Registry/Pi/faux-model journey retains a regenerable transcript in
`packages/gateway/test-results/project-lifecycle/report.json`. All projects are temporary.
The list scale journey publishes one real task, derives 299 persisted input records
from those canonical bytes/name, then validates all 300 through the real Home reader.
It measures list reads, not sequential task admission and durability; the calibrated
bound and protection against per-folder/per-page history rescans remain unchanged.
Native cases invoke the real Gateway module route, receipts and exact native decisions:
create → untrust → trust, unconfirmed reviews, busy-work refusal, unsupported folders,
authenticated actor provenance and disconnect ownership. Runtime reload and
compensation failure use the real trust owner's `setAndApply`.

## Not here

Native card presentation and acceptance: kernel host semantic UI broker. Trust records:
kernel resources. Worker control/settlement: native delegation.
