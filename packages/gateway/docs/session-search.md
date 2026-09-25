# Session search

Gateway capability `session-search.v1`, advertised only while the search
service is available, provides disposable, read-only search over canonical
session JSONL. `session.search` combines immediate catalog filtering with
bounded content postings; `session.search.anchor` validates the returned
entry/file/branch revision and returns a page containing the exact canonical
entry.

Lexical index initialization is bounded and recoverable: an oversized or
malformed session is omitted with partial coverage rather than preventing
Gateway listen. Local semantic qualification/indexing runs as an owned,
abortable background task with aggregate work, vector-count, and vector-byte
limits; lexical search remains usable while it is indexing.

The SQLite database under Gateway cache is an acceleration only: it stores
bounded postings and passage identity, never canonical message bodies. Each
process discards the previous index before rebuilding it from canonical JSONL,
which remains the only transcript authority; warm-up starts after
session-registry recovery and before automation recovery, and startup never
integrity-checks an index it will discard. Open sessions are read through their
existing `RuntimeSlot`; cold sessions are complete-file reads after catalog
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
disposable search index; existing-ledger schema/authority rows are validated
before any mutation, and corruption fails closed for Jev only without blocking
core Gateway startup.
Cancellation after dispatch retains a pending reservation because provider
settlement is uncertain; pending and historical rows have bounded retention.
Lexical posting admission uses UTF-8 byte estimates with storage headroom and
reports actual owned SQLite file bytes. An actual over-bound disposable SQLite
file is quarantined and recreated at the index owner boundary, so a later small
replacement can recover. Initial semantic indexing and per-session vector
refreshes remain serialized, while lexical dirty replacement is independent of
helper I/O; per-session dirty generations retain invalidations that arrive
during a refresh. Policy updates
advance the durable owner-assigned revision monotonically. Neither path changes
canonical transcript ownership.
