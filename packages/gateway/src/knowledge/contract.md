# Active Profile note contract

The [module owner](README.md) describes storage and public web primitives.
Research sources have no runtime record API.

## Notes and revisions

A note keeps its original ID, committed revision IDs, scope, content, provenance,
evidence and relations. Reads require a committed revision and recheck exclusions
after I/O. Lists are bounded, seek by update time and ID, and return a continuation
cursor. Exact reads and the read-only note tool do not mutate or migrate.

Profile writes remain agent-authored unless the native exact-content decision
marks them confirmed. Note marks survive unrelated edits. Profile placement,
capacity, sensitive inference and corrections stay with the existing
[Profile owner](../modules/home/profile.md), not a source-curation API.

## Publication and recovery

Immutable bodies precede a single SQLite commit of heads, revision ownership,
controls and the command receipt. Repeated command IDs require the same request
hash. Historical reads require exact ownership; receipts do not resurrect forgotten
records. The existing catalog and immutable note files are active storage, not a
compatibility reader.

Profile organization freezes original histories and the opaque Changes audit in
owner-only backups before publication. Explicit recovery checks exact committed
identities. Forget invalidates the whole affected recovery envelope and redacts
derivative references; durable cleanup survives a crash.

## Plain-file research

The offline converter exports every committed source revision to
`sources/<id>/<revision>/{source.md,original.json}` and referenced objects to
`attachments/<sha256>`. `MANIFEST.json` maps original identities/revisions and
exact payload, Markdown and attachment hashes. Markdown includes the original
source URI, readable body and complete metadata/provenance. No index, sync owner
or runtime reader interprets this manifest.

A complete independently hashed archive precedes export and the first catalog
deletion. Current immutable bytes must match that archive before retirement;
verification demands the exact expected remaining file set. Unknown orphan
objects are preserved, not silently deleted. Suppressed sources or active scope
exclusions refuse conversion pending an explicit privacy disposition.
Normal file tools consume the exported content; ordinary filesystem ownership
and explicit user-authorized file deletion apply thereafter.
