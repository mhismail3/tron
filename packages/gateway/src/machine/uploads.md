# Uploads, blobs and exports

Byte stores behind the authenticated HTTP routes ([protocol](../transport/protocol.md)).
`UploadStore` (`upload-store.ts`) owns staged bytes, prompt claims and reader leases;
`transport/upload-http.ts` owns the exchanges; session archives belong to
`sessions/session-export.ts`.

## Uploads

- **Limits.** 25 MiB per request and per prompt. Unclaimed staging: 1,024 entries and
  eight times the per-upload limit (200 MiB). Retained ownership: 16,384 logical
  entries and 400 GiB, checked only when a prompt claims staging, so old history never
  starves a draft. At most half the staging ratio streams concurrently (four bodies).
  Every body reservation and import copy keeps a 1 GiB free-space floor; import copies
  are owned by a release lease.
- **Storage.** Chunks stream into protected staging while hashing; commit adopts one
  immutable sharded content-addressed object and hard-links the logical UUID path to
  it, so duplicate bytes are stored once while name, MIME type, ownership and the
  public `upload:<uuid>` stay logical. Version-2 metadata is the only accepted shape
  (64 KiB canonical document). Publication fsyncs files and parent directories.
- **Integrity.** Inventory checks inode and size without rehashing; a logical path that
  lost its object is rehashed, re-adopted and fsynced. The first read verifies a digest
  once per process; each maintenance pass audits one more object. A failed digest
  marks the object unavailable and fails reads explicitly. An operational filesystem
  error is never treated as corruption: the artifact is kept and reads stay
  unavailable until validation succeeds; quota-affecting ingest and reconciliation
  fail closed meanwhile; sweeps preserve unknown references. Only confirmed absence,
  symlink escape or malformed evidence self-cleans.
- **Lifecycle.** Every rejection, overflow or disconnect removes staging and its
  reservation. Clients may discard an unclaimed upload (claimed ones refuse);
  unclaimed uploads expire after 24 hours. Prompt attachment IDs are unique. Startup
  does the one physical inventory, migration, reconciliation and orphan sweep; the
  ten-minute maintenance slice (background scheduler) expires indexed unclaimed files,
  retries cleanup and drops claimed references only when the catalog proves their
  owner gone. The in-memory index is rebuildable from metadata. Imports remove their
  staging; session deletion removes claimed folders; a cleanup failure never turns a
  completed import or deletion into an ambiguous receipt and is retried after restart.
- **Projection.** `uploads.status` v2 reports counts, bytes, deduplication, headroom,
  pressure, active admissions, unavailable objects and cleanup backlog — never IDs,
  names, paths, digests or MIME data. Capacity errors name `staging_entries`,
  `staging_bytes`, `retained_entries` or `disk`. Mobile transcripts expose an upload
  only as an authenticated preview route derived from the canonical path; unclaimed
  staging is never readable; a prompt-owned file streams from its open descriptor
  with its declared size and type. Remote cold offload is deliberately not built.

## Blobs

Transient projected images: 25 MiB per item, 128 items, 200 MiB total, deduplicated,
30-minute idle expiry refreshed by access. Admission never evicts a published ID;
excess images become omission text. Control-bearing MIME metadata is rejected; one
byte range is supported, malformed multi-ranges fail closed.

## Session exports

A separate protected file-backed store: one disk-reserved generation, four readers,
eight artifacts, 2 GiB each, 4 GiB total, a 64 MiB floor checked before copy. An
export captures a newline-terminated descriptor/byte-length cut while serialized with
the runtime (a first-turn session without JSONL uses the runtime's header/entry
projection), then copies that prefix outside the lane, so later appends are excluded.
JSONL is the complete tree verbatim; HTML renders the active branch with Pi's
standalone export command in a child process (15-minute kill bound).
`session-export.v2` returns the exact size; streaming is backpressured with one
`bytes=start-end` range and never buffers the archive. Active downloads survive
pruning; capacity frees after the last reader. Both disposable stores are scavenged
only after the Gateway binds.

Verify: `scripts/tron test gateway src/transport/server-upload.integration.test.ts`.
