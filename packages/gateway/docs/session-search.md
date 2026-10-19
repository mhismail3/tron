# Session search

`SessionSearchService` is the Gateway's optional, in-process, read-only search
over canonical session JSONL: bounded content postings plus optional local
semantic ranking. Its only reader is Home's `session_search` research tool
([Home](home.md)); it has no client RPC or capability. (The iPhone's dashboard
search is a local title match over the session catalog it already holds.)

The tool keeps its readable citation text and also persists bounded native-sheet
facts in `details`: query, coverage/ranking states, and ordered hits containing
session/entry IDs, title, role, timestamp and snippet. These are historical
display facts, not a new RPC, session-navigation grant or copy of the index.
Technical details retain the readable output and provenance identifiers.

Every result carries `archived`, the Gateway archive projection read from its
owning store when the response is built. Archive state is never part of the
index or canonical file, so archiving or unarchiving changes no indexed text
and needs no reindex, and an archived session stays searchable while its
dashboard row is hidden. The archive store stays the only owner of that
state (`session.archive.set`, run-admission clears, backstop clears, deletion,
rebind and startup pruning all write it); see
the archive contract in the Gateway README.

Lexical index initialization is bounded and recoverable: an oversized or
malformed session is omitted with partial coverage rather than preventing
Gateway listen. Local semantic qualification/indexing runs as an owned,
abortable background task with aggregate work, vector-count, vector-byte and
per-start time limits; lexical search remains usable while it is indexing, and a
pass that reaches its time budget publishes explicit partial semantic coverage.

The SQLite database under Gateway cache is an acceleration only: it stores
bounded postings, passage identity, and each indexed session's reuse facts
(the catalog's `fileIdentity`, size and mtime), never canonical message bodies.
It is persisted across restarts and reused only while the catalog owner still
reports exactly those facts for that session: an unchanged corpus is warmed
without reading a transcript, and only what the catalog proves changed is
parsed again. A row written without a verified catalog cut (an on-demand
refresh of a session that changed while the Gateway was running) is re-derived
on the next start rather than trusted, and a build that cannot read the rows as
its own discards them and rebuilds from canonical JSONL, which remains the only
transcript authority. Warm-up starts after session-registry recovery and before
automation recovery; it runs in bounded slices that hand the event loop back
between them, and startup never integrity-checks an index it will discard. Open
sessions are read through their existing `RuntimeSlot`; cold sessions are
complete-file reads after catalog
admission. The complete cold graph is validated before the SDK-selected branch
is retained. Search applies the selected branch's last context edit to each
message before extraction; null edits omit it without renumbering later entries.
The shared credential-shaped redactor runs on whole effective text before entry
bounds, postings, optional embeddings or excerpts. Explicit titles are redacted
whole; fallback titles derive from the first effective searchable user message
(or `(untitled)` when none exists), not the catalog's original first message. Ordinary assignments, paths and hashes
remain readable; arbitrary secrets are not universally recognizable. The same
safe title/snippet feeds readable results and persisted native-sheet details.

Ledger-owned Home chapters (enabled or disabled) are excluded from this other-chat
index and its coverage denominator: Home's native memory search/zoom owns that
history, whereas every other-chat hit can be expanded by `session_read`.
Hidden, delegated, tool, thinking, and abandoned-branch entries are not indexed.
The derivation revision invalidates old raw-text postings/titles even for
unchanged files. Normal startup rederives this disposable cache through its
existing bounded owner, with no canonical rewrite, model call or new service.
This does not sanitize previously persisted tool results or legacy records. Malformed, oversized, or interrupted files report partial coverage
rather than an empty corpus. Fork anchors retain the selected-branch gap ordinal
rather than a fabricated zero. A result is re-cut immediately before publication
after optional semantic ranking: unrelated session publications do not
invalidate the search, and changed result sessions are revalidated against the
current branch so stale or removed passages are dropped and surviving lexical
hits carry a fresh branch revision.

The semantic ranking state is explicit and never silently represented as
lexical success. Semantic readiness requires the signed NaturalLanguage
helper qualification and one matching model revision,
language, and dimension for qualification, every vector, and every query;
unsupported languages remain unavailable with a reason. The helper must be the
regular, non-symlink, signed bundled artifact (development overrides are only
admitted under explicit development mode). Search never calls Jev or any
remote provider. Lexical posting admission uses UTF-8 byte estimates with storage headroom and
reports actual owned SQLite file bytes. An actual over-bound SQLite
file is quarantined and recreated at the index owner boundary, so a later small
replacement can recover. One document's postings are inserted in slices that
hand the event loop back, and a summary publication marks its session dirty
instead of deleting index rows inline, so neither a reindex nor another owner's
publication holds the loop. Initial semantic indexing and per-session vector
refreshes remain serialized, while lexical dirty replacement is independent of
helper I/O; per-session dirty generations retain invalidations that arrive
during a refresh. Neither path changes canonical transcript ownership.
