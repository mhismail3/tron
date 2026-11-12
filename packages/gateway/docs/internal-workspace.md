# Tron internal workspace

`<tronHome>/workspace` is private cross-session storage, normally
`~/.tron/workspace`; Debug/custom installations use their resolved `tronHome`.
It is not a project, session cwd, trust grant or sandbox. Never copy projects,
sessions, settings, credentials or installed resources here, automatically collect
its contents, or load it as global instructions. Secrets stay in their owned stores.

## Maintain files by lifetime

- `tmp/<taskId>/`: scratch for the task in hand. Create directories lazily. Before
  finishing, retain useful results in files or state and delete remaining task-owned
  scratch. Scratch untouched for over 14 days may be removed without asking after
  checking it is not in use; age never overrides a running task's ownership.
- `files/<topic>-<date>/`: finished things someone will open again: reports, plans,
  review screenshots and exports. Add one line per deliverable to `files/INDEX.md`
  with a relative link and its purpose. Never put scratch here.
- `state/<name>/`: living data read and refreshed over time, such as libraries,
  bookmarks or memory. One skill or capability owns each folder; its short README
  names the owner and explains how to read and refresh it. A skill needs no Gateway
  code owner or generic storage framework. Use its existing reader/writer; choose
  serialization and safe publication appropriate to its actual mutation risks.

Never delete from files or state without maintainer approval. Issue closure and
old timestamps alone are not deletion permission. Read-only tasks stay read-only.
A downloaded snapshot is a finished export; a collection refreshed and queried over
time is state. To present living data, publish only the requested finished view in
files, not a second canonical collection.

Gateway-managed stores retain their owners: `files/Profile.json` is edited only
through Profile actions; episodic memory, Home tasks and `state/apps/` use their
owning interfaces (`swift_app` for installed apps). A skill cannot take over these
namespaces. Pi's agent directory, Gateway state and existing extension stores stay
canonical where they are. A folder's name grants no new mutation authority.

## Runtime safety and recovery

`TronWorkspace` owns root availability. The installation home, Gateway state and
workspace root must be real current-user-owned `0700` directories. Unsafe paths,
symlinks, wrong ownership and invalid lifecycle evidence are preserved and refused,
never repaired automatically. A safe existing root is adopted without scanning or
changing its contents; child folders are created only when needed by their owner.

The service holds the refreshed cooperative `proper-lockfile` lock on
`gateway/workspace-state` until disposal; crashed locks expire through that protocol.
Initialization evidence is exactly `{version:1}` in `initialized.json`; each feature
uses its own strict `<feature>-initialized.json`. Secure bounded reads and durable
atomic publication protect these Gateway records, not arbitrary skill files.
Canonical session ownership has its separate agent-runtime lock.

Once initialized, a missing root is not recreated. Disappearance or inode replacement
during a runtime makes it unavailable; unrelated project sessions can continue.
There are no fallback writes into HOME or projects. Restore the original safe root
and valid lifecycle evidence, investigate the cause, then request the maintainer's
Gateway lifecycle transition. Never delete unknown metadata to force acceptance.
Back up the workspace with lifecycle evidence and the separate canonical owners
needed for a full restore. App updates, uninstall cleanup and credential resets do
not remove this data. There is no automatic backup or garbage collector, and
advisory locks are not a same-user filesystem sandbox.

## Agent context and display

The `tron-core` extension supplies root, availability and the same lifecycle guidance
to every Gateway-owned agent start: Home, ordinary chats, task workers, reloads,
resumes, forks, post-compaction turns and Automations. It does not change cwd or
append workspace context to JSONL.

Direct model `subagent` task/resume calls receive that guidance in the bounded
advisory handoff. Inline Gateway extensions do not propagate to children. For
workflow, slash/RPC and further delegation, the parent must explicitly pass root,
availability, lifecycle and owner rules in every child brief, including resumes;
read-only tasks remain read-only. The [workspace module](../src/workspace/README.md)
owns the handoff and pinned provider limits.

`display` with `source: {kind: "internal_file", path: "topic-date/report.md"}` reads
only beneath files, independently of cwd. The root must be available and files an
existing safe real directory. State and tmp are not display roots. Absolute paths,
traversal, hidden components, symlinks, directories and escaping paths are rejected.
Session-relative `path` sources and public URLs are unchanged. Existing artifact
bounds, immutable authenticated copies, cancellation and retention still apply;
a presentation snapshot is not an editable canonical document.

The delegated provider's `PI_SUBAGENTS_TEMP_ROOT` remains
`<tronHome>/internal/subagents`, set before extension loading. Its run lifecycle,
retention and cleanup remain provider-owned; workspace tmp is not a replacement.
`internal/machine-group-id` remains opaque physical-machine identity;
`internal/mac/wizard-state.json` remains wrapper-owned progress, with `.onboarded`
the sole completion authority.
