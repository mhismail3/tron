# gateway/projects

## Purpose

Gateway-owned project lifecycle for Home and ordinary chats, using the existing
settings approval/action authority and the canonical Project trust store. Delegated
workers share the ordinary tool surface, but cannot approve their own requests.

## Owns

`project-lifecycle.ts` owns names, filesystem/Git effects, identity checks and
GitHub command admission. `module.ts` owns the `projects` tool.
`runtime-admission.ts` reads canonical runtime/task owners; it stores no worker index.

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

The settings owner registers the action at startup before decisions. Its existing
queue, exact preview/digest, 24-hour expiry, UI-only decision, execution claim and typed
requester outcomes are authoritative; there is no second queue or outcome store.
Home can delegate immediately after successful trust. Decline/expiry grant nothing.
An interrupted/failed action is never replayed; inspect retained paths and Changes.
A crash after a local creation intent may leave an unresolved audit row; it does
not imply success and is never replayed. If both runtime reload and compensation
fail, the native owner retires uncertain frames without a success publication and
releases project admission. Canonical session data stays intact; repair failing
resources before reopening the cold session. A refusal before filesystem effects
preserves trust only for the original retained source directory.
Repeating create refuses its existing path; repeating an approval refuses its settled
request. To retry a failed creation's trust phase, explicitly request `trust`.

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
- Filesystem checks and reservations exclude Gateway races and existing symlink escapes;
  they are not a sandbox against another process with the same Mac user's authority
  maliciously renaming directories between OS calls. Errors retain paths for inspection.
- Git subprocesses are bounded, noninteractive and ignore inherited `GIT_*` selectors;
  hooks/templates and repository-configured log signature programs do not execute.
  GitHub stderr/credential-bearing config is not returned.
- Existing generic iOS approval chips/sheets show action items; no custom UI is introduced.

## Entry points

`ProjectLifecycle.register`, `ProjectLifecycle.request`, `projectsModule`,
`projectRuntimePort`; composition in `main/modules.ts` and `gateway-main.ts`.

## Signals

Settings Changes keys `project.create` (local creation) and `project.lifecycle`
(pending/approved/declined/expired/superseded/failed action) diagnose the phase.
A failed action outcome instructs the requester to inspect operation state before retry.

## Verify

```bash
scripts/tron test gateway src/modules/projects/project-lifecycle.e2e.test.ts
```

The real Gateway/Registry/Pi/faux-model journey retains a regenerable transcript in
`packages/gateway/test-results/project-lifecycle/report.json`. All projects are temporary;
GitHub success is a spawned fixture executable, never a live repository. The
installed `gh` also runs with empty auth configuration/token environment under
macOS Seatbelt's network deny; this proves unauthenticated refusal/retained state,
not real remote creation. The real-CLI case requires installed `gh` and `sandbox-exec`.

## Not here

Approval/outcome storage and UI authority: kernel settings/admin. Trust records and
serialized relocation: kernel resources. Worker control/settlement: native delegation.
