# Structured Home profile

## Authority and exposure

Personal Knowledge notes are canonical. Membership is the `home-profile` label;
`kind-*` retains the existing kind. `home-file-core`, `home-file-home` and
`home-file-scopes-<name>` partition notes into Core, Home and one shallow level of
named scopes. File membership is organization, not relevance or binding authority.
Existing unpartitioned notes remain discoverable under Core before an explicit
complete migration. No existing label, content or historical revision is removed.

Each activation carries a metadata-only discovery index: file names, active/total
classified counts, revision fingerprints and explicit read instructions. The index
pages at most sixteen files and sixteen diagnostic references at a time; `offset`
advances both metadata windows and discloses remaining rows rather than dropping them. It contains no note titles or bodies. A fingerprint changes when a note's
revision changes, not because a classifier reinterpreted its text.

Home reads `profile {action:"read", file:"core"}` (or `home` or `scopes/<name>`)
when it needs the content. Omitting `file` reads the index. `offset` pages the index
or the chosen file. File reads return up to sixteen exact records with IDs,
revisions, kind, status, confirmation, full note content and provenance; `nextOffset`
identifies remaining records. Retired/superseded records stay readable with their
status, never silently active. Invalid kind or partition labels produce exact
ID/revision diagnostic references for explicit Knowledge reads and repair, not an
inferred kind or Core assignment. Malformed metadata never hides healthy records;
only genuinely unlabelled flat notes read under Core. The existing native list's
unclassified count remains kind-only. Unavailable/corrupt Knowledge is not an empty profile.

Home chooses interpretation, relevance and worker brief content. Gateway performs
no semantic selection, inferred scope routing or automatic content insertion, and
requires no copied profile text or mandatory citation section in worker briefs.
Confirmation establishes provenance/status, not new execution permission. Existing
explicitly binding safety/standing instructions retain their authority. Home must
inspect and respect them before acting; moving a note does not revoke its force.

## Incremental curation

The Home-only `profile` tool reads and curates through the existing Home change
subject. Learn takes a kind, exact one-line text and optional explicit file (Core
by default). Refine/supersede/retire retain their existing validation, evidence
citations, immutable history and visible Changes/undo route. No ordinary worker
receives this tool. The maintainer's existing explicit confirmation/undo surface is
unchanged.

Home content writes are inferred. The previous confirmed instruction-kind contract
is conservatively preserved: Home cannot rewrite, supersede or retire an existing
confirmed preference, standing decision or delegation default. It can save an
inferred proposal for review, but cannot promote that proposal or weaken existing
authority. Contextual fact edits retain their existing evidence/confirmation rules.

## Mechanical partition storage

`KnowledgeStore.partitionProfile` owns the admitted SQL transaction. Its caller
supplies every ID, exact expected head and destination; storage never infers a
mapping from text, kind, confirmation or project. Complete migration includes
inactive members. Excluded records, stale/incomplete mappings, invalid destination
labels or bounds refuse before mutation rather than being silently omitted or truncated.
Explicit reorganization can repair malformed stored partition labels: it replaces
only `home-file-*` labels, retaining every other value and the original histories.
No repair destination is inferred, and reads never normalize stored labels.

An owner-only bounded recovery backup contains every original head and immutable
historical revision plus every prepared replacement identity. It is synchronized
before any replacement body. Only the file label and revision identity may change;
text, body, existing labels, kind, provenance, confirmation, relations, retirement,
creation/update times and old bodies remain intact. Canonical heads remain in SQL,
not the backup. All prepared heads publish in one commit.

A process crash before commit leaves old heads authoritative and staged bodies
reachable through the durable backup. Explicit retry of the same assignments
reuses prepared identities, validating original content/history before adoption;
it does not leak additional immutable revisions. Postcommit replay is stable, and
resubmission with freshly read identical destinations is a no-op. Merely opening
Knowledge never migrates. Backups are recovery artifacts, not another profile store
or permission to retire notes. The Home Changes owner remains responsible for
canonical audit publication, replay identity and undo; a store-only result is not
end-to-end curation success.
