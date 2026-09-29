# Session search

Gateway capability `session-search.v1`, advertised only while the search
service is available, provides disposable, read-only search over canonical
session JSONL. `session.search` combines immediate catalog filtering with
bounded content postings; `session.search.anchor` validates the returned
entry/file/branch revision and returns a page containing the exact canonical
entry.

Every result carries `archived`, the Gateway archive projection read from its
owning store when the response is built. Archive state is never part of the
index or canonical file, so archiving or unarchiving changes no indexed text
and needs no reindex, and an archived session stays searchable and anchorable
while its dashboard row is hidden. The archive store stays the only owner of that
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
is retained. Hidden, delegated, tool, thinking, and abandoned-branch entries are
not indexed. Malformed, oversized, or interrupted files report partial coverage
rather than an empty corpus. Fork anchors retain the selected-branch gap ordinal
rather than a fabricated zero.

Semantic and Jev ranking states are explicit: neither is silently represented
as lexical success. Semantic readiness requires the signed NaturalLanguage
helper qualification and one matching model revision,
language, and dimension for qualification, every vector, and every query;
unsupported languages remain unavailable with a reason. The helper must be the
regular, non-symlink, signed bundled artifact (development overrides are only
admitted under explicit development mode). Jev reranking is disabled without
user consent, a per-Gateway allowance, and durable bounded reservation. Policy
allowances named `microCents` are one-millionth of a cent (1e-6 cents); the
qualified 64,000-token request ceiling reserves 268,800 microCents. Spending
reservations live in a separate durable SQLite ledger
(`session-search-jev-allowance.sqlite`) with idempotent settlement, not the
search index; existing-ledger schema/authority rows are validated
before any mutation, and corruption fails closed for Jev only without blocking
core Gateway startup.
Cancellation after dispatch retains a pending reservation because provider
settlement is uncertain; pending and historical rows have bounded retention.
Lexical posting admission uses UTF-8 byte estimates with storage headroom and
reports actual owned SQLite file bytes. An actual over-bound SQLite
file is quarantined and recreated at the index owner boundary, so a later small
replacement can recover. One document's postings are inserted in slices that
hand the event loop back, and a summary publication marks its session dirty
instead of deleting index rows inline, so neither a reindex nor another owner's
publication holds the loop. Initial semantic indexing and per-session vector
refreshes remain serialized, while lexical dirty replacement is independent of
helper I/O; per-session dirty generations retain invalidations that arrive
during a refresh. Policy updates
advance the durable owner-assigned revision monotonically. Neither path changes
canonical transcript ownership.
