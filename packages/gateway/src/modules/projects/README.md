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

## Surface

The module exposes the `projects` agent tool and no RPC. The app has no project screen.

- `projects({name, reason})` creates a direct Workspace child: an untrusted folder with a
  Git repository on `main`, trusted after the exact native card is approved. The target
  must be absent; traversal, existing paths and symlinks refuse. Creation reviews are
  bound to the Workspace identity and digest; approval revalidates the digest (`Project
  changed since review`) before any effect.
- Creation's private trust step (`inspect` then `setTrust`) rechecks directory identity,
  canonical standalone Git/trust roots, linked worktrees and busy occupancy before trust is granted.
- Existing-project trust and untrust are not lifecycle actions. Home changes
  `permissions.projectTrust` with a `project` qualifier through the `settings` tool, which
  writes through `TrustService.setAndApply` with runtime reload and abort. That path has
  no lifecycle eligibility preflight. Normal runtime mutation/reload fences still apply;
  creation's linked-worktree and occupancy eligibility rules are not additional Home settings rules.
- Creation and existing-project trust grants use the shared `change` interaction answered by
  `extension.respond`. Narrowing existing-project untrust applies directly and is logged.
  Local clients cannot confirm native cards.

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
| Project changed since review | Compare the reviewed create intent (name, Workspace identity) and the current filesystem before requesting a new review. A wrong digest or changed identity refuses before any effect. Existing-project trust cards use the settings owner's digest, not this one. |

## Verify

```bash
scripts/tron test gateway --mini src/e2e/modules/projects/project-lifecycle.e2e.test.ts
```

The real Gateway/Registry/Pi/faux-model journey retains a regenerable transcript in
`packages/gateway/test-results/project-lifecycle/report.json`. All projects are temporary.
Creation cases use the real Home `projects` tool, the native `change` card and
`extension.respond`: create → approval → trust → delegate admission; decline and Stop leave
no effect; traversal, existing-path, trailing-space and symlink names refuse; uncertain
audit fences keep their receipt; nested exact roots pin under default-always trust.
The existing-project journey opens a persistent project runtime and observes its tool
inventory through the public `session.context` RPC. Home untrust removes the project tool; the exact-path
`permissions.projectTrust` card keeps it absent until approval and then restores it in
that same runtime. Delegation admission follows the resulting trust decision.
Separate trust-owner cases exercise reload and compensation failures, observing restored
tools through public context responses rather than private runtime fields. Creation owns the
standalone-root, linked-worktree and occupancy eligibility checks; those are not additional
existing-project Home settings restrictions (see Surface).

## Not here

Native card presentation and acceptance: kernel host semantic UI broker. Trust records:
kernel resources. Worker control/settlement: native delegation.
