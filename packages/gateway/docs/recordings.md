# Watch recording ingestion (capability `recordings.v1`)

Recording ingestion is a separate authenticated source-media owner. It does not
create a chat session, use `/v1/uploads`, expire accepted audio, or delete local
copies. `destinationId` is the Gateway's configured `machineId`; every operation
is authorized against the current authenticated paired device ID. The client
never supplies a filesystem path.

The owner publishes under the already-resolved internal workspace:

```
<tronHome>/workspace/files/recordings/<lowercase-recording-uuid>/
  recording.json             # owner/destination binding; not audio metadata
  segments/000001.audio
  segments/000001.json        # durable admission receipt for that segment
  commit.json                # exact final durable receipt; absent until finalize
```

`workspace/files` must already exist and pass `TronWorkspace.filesRoot()`
ownership checks. An unavailable workspace fails closed; Gateway does not
recreate or fall back to a home/repository path. The `recordings` namespace is
created owner-only when needed. Accepted files are immutable and retained; there
is no automatic expiry or eviction. Streaming is capped at 64 MiB per segment,
four simultaneous request bodies, 512 segment identities, and 100 metadata
items per status page. Admission preserves a 1 GiB filesystem free-space floor
and returns retryable HTTP 503 `busy` rather than deleting retained media.

## HTTP contract

All routes require the existing `Authorization: Bearer <paired-device-token>`
authentication. Local wrapper identity is not admitted. Responses are JSON with
`Cache-Control: no-store` using the Gateway's usual `{ error: { code, message,
retryable? } }` failure envelope.

* `PUT /v1/recordings/{recordingId}/segments/{segmentNumber}` streams raw audio
  bytes (no multipart/envelope). Gateway stores opaque source bytes with `.audio`;
  the extension does not select or assert a codec/container. `recordingId` is a lowercase RFC 4122 UUID;
  `segmentNumber` is a decimal integer 1..512. Required headers:
  `X-Recording-Size` (decimal byte count, 1..67108864) and
  `X-Recording-SHA256` (64 lowercase hex characters). Send an accurate
  `Content-Length` when available. Success is HTTP 201 and
  `{ "receipt": { "schemaVersion":1, "recordingId":uuid, "segment":n,
  "size":bytes, "sha256":hex, "acceptedAt":UTC } }`. The owner streams to
  owner-only staging, checks exact length/hash, syncs file, atomically renames,
  then durably publishes the sidecar and directory entries before receipt.
  Retrying an already accepted identity with the same declared size/hash returns
  its stable receipt; a different size/hash conflicts (409). The authenticated
  device that first creates the recording owns it; another device cannot add,
  finalize, or inspect it.
* `POST /v1/recordings/{recordingId}/finalize` has a JSON body at most 256 KiB:
  `{ "schemaVersion":1, "segmentCount":N, "capture": CaptureMetadataV1 }`.
  `CaptureMetadataV1` is the complete shape in
  `test-fixtures/watch-recording-v1.json`: `source` versions/platform,
  canonical UTC `startedAt`/`stoppedAt`, `clockOffsetMilliseconds`,
  `stopReason` (`user` or `recovered-partial`), `recoveryStatus`
  (`complete` or `interrupted`), and an ordered timeline with exactly N records.
  Each timeline record has `segment` equal to one-based position, non-negative
  integer monotonic start, duration, pause-before milliseconds and frame count,
  plus bounded per-segment `codec` and `format` strings. Keeping codec/container
  on each timeline segment preserves later format epochs without fixing a capture
  container at the Gateway contract boundary. Only user +
  complete and recovered-partial + interrupted pairs are accepted. Finalization
  checks the exact contiguous sidecar set and rehashes every durable segment.
  Out-of-order arrival is supported; gaps, extras, corrupt bytes, or invalid
  metadata reject finalization. Success HTTP 200 returns `{ "receipt":
  RecordingReceiptV1 }`, where the durable receipt binds `recordingId`,
  authenticated `sourceDeviceId`, destination `machineId`, exact capture object,
  finalization UTC timestamp, total byte count, segment count, and
  `contentSha256`. Content hash is SHA-256 of the UTF-8 concatenation, ordered by
  segment, of `<n>:<segmentSha256>:<byteLength>\n`. The receipt is atomically
  synchronized and is the only `saved on Mac` authority. Same exact finalize is
  idempotent; changed capture/content conflicts.
* `GET /v1/recordings/{recordingId}/status?offset=0&limit=50` returns only the
  authenticated owner's bounded page: `{ recordingId, finalized, receipt?,
  segments:[SegmentReceiptV1...], nextOffset:number|null }`. `limit` is 1..100;
  offset is a non-negative integer. The page describes admitted sidecar
  receipts, not a single atomic inventory snapshot. Continue using `nextOffset`;
  read `receipt` to recover a lost finalization response. This status is
  recording-scoped and does not list arbitrary recordings or expose paths.

Error map: malformed IDs/headers/body/page bounds => 400 `invalid_request`;
unknown or foreign recording => 404 `not_found`; differing replay, gaps,
corruption, or post-commit mutation => 409 `conflict`; bounded body/disk pressure
=> retryable 503 `busy`. Never infer success from a segment HTTP response as a
completed recording; only a validated final receipt means Gateway commit.

The native client contract example and exact deterministic content digest are
in `../test-fixtures/watch-recording-v1.json`. Swift should share this fixture
rather than mirror a separately invented Codable schema. Preserve original
segment bytes, retain local source files until a verified exact receipt is
stored/relayed, retry segments and lost commit responses idempotently, and
finalize recovered captures distinctly. Do not forward credentials to the Watch.

## Current milestone boundaries

The Gateway owns authenticated ingestion, device and machine binding,
stream/hash/size bounds, per-recording serialization, immutable segment
admissions, disk-floor admission, receipt/status paging, and normal/recovered
exact finalization. Native sources now provide Watch capture/WatchConnectivity
custody and iPhone background URLSession delivery with verified receipt relay;
focused simulator checks cover their local state and validation seams. These
checks are not physical qualification. Recording routes are present only after
the matching source-built Mac payload is manually activated, even though this
feature does not change the shared Gateway protocol version. Preserve source
media and require physical Watch → iPhone → Mac receipt testing before release.
