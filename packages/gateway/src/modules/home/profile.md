# Personal profile

## Authority and organization

Personal Profile notes in `workspace/state/profile` are canonical. Runtime accepts only
storage version 1; only the offline retirement converter reads old Knowledge. `home-profile` marks membership; one
`kind-*` label retains preference, standing decision, delegation default, fact or
correction. Placement is `content.profile = {version: 2, path: string[]}`. The seven
roots are `life`, `routines`, `communication`, `engineering`, `resources` (machines,
devices and services together), `projects` (owned projects and pointers only), and
`corrections`. `inferred/{review,needs-split,project-rules,procedures,uncertain}`
is separate holding space, not an eighth personal area. Inactive originals stay unchanged.
Depth is at most four segments including the root. Segments are lowercase slugs.

Placement, kind and confirmation are distinct. Sorting cannot grant execution
permission, promote confirmation, split a note, revoke explicit standing authority
or rewrite provenance. Home chooses relevance and worker brief content; Gateway
performs no semantic selection, automatic content insertion or inferred routing.
Existing explicit safety and standing rules retain their force.

Historical `home-file-*` labels and unlabelled legacy members are read as **Prior
organization**, never inferred into a v2 destination. Ordinary Home content edits
refuse until an exact placement is reviewed. Only internal Changes Undo can write
historical placement; new Home curation writes v2. Reads never migrate data.

## Discovery and exact reads

Each activation receives a metadata-only index: seven roots, active/total counts,
revision fingerprints, separate Unsorted and historical counts, and diagnostic
ID/revision references. It contains no note titles or bodies. The index is at most
8 KiB and pages diagnostics with `offset`; remaining references are explicit, not
silently omitted. A fingerprint changes with canonical note revisions.

Discovery reads the SQL heads' required mechanical profile projection, written
with the owning immutable note and head in the same transaction. A missing projection
refuses; no historical-body metadata fallback or startup upgrade exists.
Suppression, scope exclusions and forgotten dependencies retain the existing head
visibility fence. Unavailable Profile is not an empty successful profile.

`profile {action:"read"}` reads the index. `profile {action:"read", path:"engineering"}`
reads an explicit path and descendants; `inferred` and `prior` are readable too.
Record pages and the native list retain the canonical kind, creation-time, then ID
order; SQL storage-key order is not presentation order. Record pages contain at
most sixteen notes and 32 KiB, including exact IDs,
revisions, state, content and provenance. Inactive content requires `includeInactive:true`. An oversized record returns its canonical
Profile reference and byte count, never truncated content. The reference names
`profile {action:"read",id,revisionId}`. Exact reads return at most 4,096 UTF-16
characters with `nextOffset`; pass it as `contentOffset` with the same identity.
Surrogate boundaries are checked. Missing revisions refuse, and exact identities
cannot be mixed with index selectors. `nextCursor` binds
the query and revision snapshot; changed snapshots refuse and require a new read.
Raw offsets are only for metadata, not continuation of record pages.

Invalid kinds and legacy partition metadata produce exact diagnostic references;
Gateway never invents a kind or destination. The native list's unclassified count
remains kind-only. Retired and superseded notes remain readable, never active by
placement alone.

## Home proposals and maintainer decisions

New Home statements are unconfirmed, default to `inferred/review`, and cite the
triggering maintainer message. An explicit destination is accepted only as an
explicit operation, not a classifier's suggestion. Home's instructions prohibit
inferring sensitive health, relationship, financial or location information;
deliberately stated sensitive notes wait unsorted for review. For `learn`, Home
must declare `sensitive:true`: the tool requires the text verbatim in the current
maintainer message, and the owner refuses a personal destination or correction
capture. These notes use canonical `privacyScope:"private"`; an explicit organization
changes only placement, never their private content. Classification remains Home's responsibility, not a keyword detector:
unmarked prose is not claimed to have a semantic privacy guarantee. Corrections
require an exact wrong-claim ID/revision relation and stay in `corrections`.

Explicit organization applies, logs and is undoable without another native tap.
It preserves text, confirmation, provenance, status and history, including private
and standing notes. Home can retire its own unconfirmed proposals with a reason.
Retiring another author's or confirmed note, and content refinements still require
an exact maintainer decision through the shared native `change` card
(`SemanticUIBroker.requestChange` via `nativeChangeConfirmer`). Home's tool waits
in the asking chat; original notes remain unchanged until the tap. Unanswered
cards expire after 24 hours. The review's digest binds exact before/after values
and source revisions behind the sheet's technical disclosure. Supersede
previews show both the old note becoming superseded and the replacement's text,
kind, confirmation, placement and source link. Stale or expired cards are refused,
not advertised as publication retries. Accepted changes retain Changes and Undo.

Organization keeps the original operation command ID through the backup and
audit. If publication fails after placement commits, Home's returned `retry_required`
command repairs that operation's audit without applying placement again. The
maintainer's `home.profileChange` supports the same migrate/reorganize/retry path;
its own tap is authority, so it does not open another card. Retry names the original
operation inside a fresh RPC receipt. Both paths retain exact-revision fencing and Undo.

Home's model-visible policy offers sorting at the start of a maintainer turn when
eight notes are unsorted, at most eight per batch. “Not now” suppresses offers until
a **new note**, not an edit, move or elapsed time. `profile {action:"defer",version}`
binds the index's opaque arrival version. Profile's existing command receipt and
SQL control own that decision. Creating a new readable profile record consumes
it in that same transaction; later Forget cannot reinstate it. Old command replay
returns only its original acknowledgement. No body, copied identity list, clock,
counter, timer or background trigger is added. Edits, visibility changes and cold
restart retain the decision. The canonical activation kind suppresses automatic
offers during worker-completion wakes and refuses deferral from an old user message.
The operation boundary independently refuses sorting batches above eight. External
AGENTS.md, skills/prompts and Settings destinations remain drafts until safe Undo.

## Capacity and atomic placement

Active v2 limits are 256 personal notes, 128 unsorted notes, 128 subareas and 32
notes per subarea. Profile checks ordinary native writes in its SQL transaction;
partition publication checks its whole after-state before backup or body writes.
Overflow is an explicit error, never eviction or truncation. Exact Undo may restore
an original over-bound state; subsequent writes cannot grow an exceeded dimension.

`profile {action:"migrate", assignments:[{id,expectedRevision,path}], reason}`
requires exactly the active legacy Core/Home members. Inactive and named-scope
originals stay unchanged. `reorganize` names only selected notes. Every destination is explicit. Excluded members, stale/incomplete mappings
and invalid bounds refuse without silently dropping members. Placement changes only
v2 metadata and removes old `home-file-*` labels; all other labels retain order.

Committed revision membership comes from each record head; Profile maintains no
second reverse-revision index. `ProfileStore.partitionProfile` owns one SQL publication commit. An owner-only
bounded backup durably holds original heads, historical bodies and prepared
identities before writing replacement bodies. Text, IDs, authority, provenance,
confirmation, relations, retirement, timestamps and historical bodies are preserved.
Backups are recovery artifacts, not another canonical store or migration trigger.

A precommit crash leaves old heads authoritative. Explicit same-command retry
reuses prepared identities; postcommit retry proves committed identities before
repairing only the original Changes facts. The backup's versioned audit envelope
binds original actor/reason/time, ordered writes and Undo links. Later edits never
get replayed or overwritten by audit repair. Merely opening Profile does nothing.
An unacknowledged result returns `retry_required` with the original command ID.

Maintainer Changes Undo fences the whole current group, restores exact old
placement and label positions in one backed-up commit, and displays legacy results
as Prior organization. Only the maintainer can resume an uncommitted Undo.
Ordinary content Undo retains the existing path. Store-only success is not
end-to-end curation success.

Profile storage's explicit forget remains the privacy exception: the existing cleanup
owner removes canceled prepared bodies and forgotten/dependent backup snapshots,
retains unrelated recovery snapshots, and clears the whole quoting audit envelope.
Its invalidated atomic plan cannot replay. Unknown backup fields refuse cleanup
rather than silently retaining extra copies; no parallel cleanup journal exists.
