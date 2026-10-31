# Personal profile

## Authority and organization

Personal Profile's canonical owner is `ProfileStore`, backed only by storage-version-2
`workspace/files/Profile.json`. The hierarchy owns current placement: seven roots
`life`, `routines`, `communication`, `engineering`, `resources`, `projects` and
`corrections`; separate `inferred/{review,needs-split,project-rules,procedures,uncertain}`
and `prior` sections. Resources includes machines, devices and services; Projects
holds owned projects and pointers, not project instructions. Current stored notes
omit `content.profile`; reads derive that projection from their location. Depth is
at most four lowercase-slug segments including the root.

The file holds current heads, exact claim snapshots referenced by current
Corrections, Not now state and body-free control/command metadata. It has no
per-note files, SQL catalog, revision ledger, backup envelope or archive reader.
An anchor is evidence for an exact `corrects` identity, not current placement.
Unreferenced anchors are removed in the same publication that removes their last
link. Retired Corrections retain their links. Forget removes even linked claim
bodies and leaves an unavailable-claim privacy tombstone.

`home-profile` marks membership; one `kind-*` label retains preference, standing
decision, delegation default, fact or correction. Prior organization preserves
old `home-file-*` labels or unlabelled members without guessing destinations.
Ordinary Home content edits refuse until an exact placement is reviewed. Only
shared Changes Undo may restore Prior placement; new curation writes v2 paths.

Placement, kind and confirmation are distinct. Sorting cannot grant execution
permission, promote confirmation, split content, revoke explicit standing authority
or rewrite provenance. Home chooses relevance and worker brief content; Gateway
performs no semantic selection, automatic content insertion or inferred routing.

## Discovery and exact reads

Each activation receives a metadata-only index: seven roots, active/total counts,
revision fingerprints, separate Unsorted and Prior counts, and diagnostic ID/revision
references. It contains no titles or bodies. The index is at most 8 KiB and pages
diagnostics with `offset`; remaining references are explicit, never silently omitted.
Metadata derives from the current file, not a second index. Suppression, scope
exclusions and forgotten dependencies fence visibility. Unavailable is not empty.

`profile {action:"read"}` reads the index. `profile {action:"read",path:"engineering"}`
reads that path and descendants; `inferred` and `prior` are readable too. Native
lists and record pages retain kind, creation-time, then ID order. Pages contain at
most sixteen notes and 32 KiB, including exact IDs, revisions, content and provenance.
Inactive content requires `includeInactive:true`. Oversized records return their
canonical Profile reference and byte count, not truncated content.

`profile {action:"read",id,revisionId}` returns at most 4,096 UTF-16 characters,
checking surrogate boundaries. Continue with `contentOffset:nextOffset` and the
same identity. Only the current head or an exact claim linked by a current
Correction is readable. All other explicit revisions, including missing identities,
refuse with `conflict` and `details.kind = "profile_revision_unavailable"`; there is
no archive fallback. Ordinary absent current-ID lookup returns no note. Exact
identities cannot be mixed with index selectors. `nextCursor` binds the query and
snapshot; changed snapshots refuse rather than mix pages.

Invalid kinds and Prior metadata produce exact diagnostic references. Gateway
never invents a kind or destination. The native unclassified count remains kind-only.
Retired and superseded notes stay readable, never active by placement alone.

## Home proposals and maintainer decisions

New Home statements are unconfirmed, default to `inferred/review`, and cite the
triggering maintainer message. Destinations require explicit operations, not
classifier suggestions. Home must not infer sensitive health, relationship,
financial or location information. For deliberately stated sensitive notes,
`learn` requires `sensitive:true` and text verbatim in the current maintainer message;
the owner refuses personal placement or correction capture. Canonical
`privacyScope:"private"` survives organization. Classification remains Home's
responsibility, not a keyword detector. Corrections require an exact wrong-claim
ID/revision relation and stay in `corrections`.

Explicit organization applies, logs and is undoable without another native tap.
It preserves text, confirmation, provenance, status, relations and timestamps.
Home may retire its own unconfirmed proposals with a reason. Retiring another
author's or confirmed note, and content refinements, require the shared native
`change` card (`SemanticUIBroker.requestChange` via `nativeChangeConfirmer`).
Originals stay unchanged until its exact tap. Cards expire after 24 hours; their
digest binds source revisions and exact before/after values. Supersede previews
include the old note's status and replacement text, kind, confirmation, placement
and source. Stale/expired cards refuse, never become publication retries.

The maintainer's `home.profileChange` supports migrate/reorganize/retry. Its tap
already supplies authority, so no second card opens. Retry names the original
operation inside a fresh RPC receipt and retains exact-revision fencing and Undo.

Home offers sorting at a maintainer turn when eight notes are unsorted, at most
eight per batch. “Not now” suppresses offers until a **new note**, not an edit,
move, elapsed time or Forget. `profile {action:"defer",version}` binds the index's
opaque arrival version. The same file publication owns the decision and consumes
it when a new readable record arrives. Receipt replay returns only its original
acknowledgement. No copied identity list, clock or background trigger is added.
Cold restart and visibility changes retain the decision. Activation kind suppresses
offers during worker-completion wakes and refuses deferral from an old user message.
External AGENTS.md, skills/prompts and Settings destinations remain drafts until safe Undo.

## Atomic publication and shared Changes

Active limits remain 256 personal notes, 128 unsorted notes, 128 subareas and 32
notes per subarea. The serialized file owner checks the entire after-state before
publication. Overflow refuses, never evicts. Exact Undo may restore an over-bound
original state; subsequent writes cannot grow an exceeded dimension.

`migrate` requires exactly the active Prior Core/Home members; inactive and scoped
originals stay unchanged. `reorganize` names selected notes. Explicit destinations,
visibility, expected revisions and bounds are checked without dropping members.
Only placement and old `home-file-*` labels change; other labels retain order.

Before effects, the file records a body-free intent with original context/time,
request, prepared revision identities and Undo links. Shared Changes prepares the
immutable before/after facts in its existing journal using deterministic `started`
identities, distinct from final `applied` facts. Profile then publishes all current
heads and their shared-audit reference in one bounded, durable atomic replacement.
Preparation does not acquire the Home stripe while Profile holds its file mutex.
Final publication takes the Home stripe first, then rechecks the current proof
under the file mutex across the journal append. This fences concurrent Forget;
observers run only after releasing the file mutex.

A precommit crash leaves old heads authoritative; explicit same-command retry
reuses the prepared identities and context. Postcommit retry checks the committed
proof against the prepared shared group and repairs only those original facts.
Later edits are neither replayed nor overwritten. The result is `retry_required`
with the original command ID until publication is acknowledged. Shared Changes
Undo fences the whole current group and restores exact placement/label positions
in one publication; only the maintainer resumes an uncommitted Undo.

Command fences retain their operation/request-digest identity, not old bodies.
Replay of an acknowledgement whose record revision is no longer retained refuses
the historical read rather than recreating it. Forget invalidates every affected
pending/committed proof as a whole and scrubs current dependent evidence. It cannot
resume canceled effects. The owner discards only its own abandoned publication
stages at the next serialized mutation; stages are never alternate read inputs.
Files are private, bounded to 64 MiB, and checked for unsafe paths. This is owned
storage, not a sandbox against concurrent same-user filesystem modification.

## Offline cutover boundary

Runtime refuses existing `state/profile`, `state/knowledge` or
`state/knowledge.retiring`; it never converts them on open. A missing initialized
current file also refuses instead of creating an empty replacement. Reads perform
no conversion, domain replay or archive access.

A dedicated maintainer-approved offline cutover must stop writers, preserve the
old namespace/receipts and inventories, build and validate the current hierarchy
with every exact current Correction anchor, and reconstruct required shared-audit
references without changing facts. Archive all other old revisions outside runtime
storage, verify the candidate and receipt fences, then publish it and remove the
retired namespace from the runtime path. No archive path enters Profile control.
The runtime replacement alone is not cutover admission proof or permission to run it.

Before resuming writers, rollback restores the preserved namespace and matching
old runtime together. After new writes, do not overwrite the file with an older
snapshot: stop and plan an explicit forward reconciliation. Offline conversion,
archive writes, rollback and live activation each remain maintainer actions.
