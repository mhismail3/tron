# Exact session-search navigation plan

## Contract seam

`session.search.anchor` remains the canonical admission point and keeps its
existing session, entry, branch/file revision, runtime, and leaf checks. The
request gains an optional bounded `windowEnd` ordinal boundary (the exact
canonical target remains the anchor entry, while the Gateway chooses the
bounded page start under its existing projection byte/item limits). The
response continues to carry canonical `items`, `start`, `end`, and `total`, and
adds the exact window identity (`runtimeGeneration`, `leafEntryId`, target
ordinal in the projected transcript, and earlier/later cursor boundaries). The
Gateway obtains this window
from the owning RuntimeSlot canonical projection; it never returns the full
bridge between a deep target and the live tail.

## Presentation ownership

`SessionPresentationStore` gains one ephemeral historical-window projection,
not a second transcript cache. It validates session/runtime/leaf/structure
identity, total and contiguous global ordinals before publishing the bounded
window. The live SessionSnapshot remains authoritative for tail, streaming,
composer, reconnect, and mutation state. Historical mode is explicitly
return-to-latest; branch/leaf/runtime/reconnect invalidation expires the window
and surfaces retry rather than mixing rows from different cuts.

Window paging uses the owning `session.transcript` seam with atomic `before`
(backward) and `after` (forward) cursors; each response echoes the adjacent
canonical projected identity and is bounded by byte/node/item limits. The
historical toolbar owns those commands and never changes the live tail. Search navigation installs the exact window
containing the target in one request, independent of target distance from the
tail. Render scroll is admitted only after the presentation projection exposes
the target semantic ID; the existing layout/render owner emits the success or
bounded retry outcome.

## Policy restoration

The selected profile's `session.search.policy.get` follows active dashboard
presentation demand, including uncover, after captured lifecycle admission.
Secondary profiles refresh once on an admitted connection transition. Dashboard
summaries trigger neither read. Loaded consent is valid only for its exact
profile/connection; a replacement client's local epoch number alone is not an
identity. Missing/offline/error reads cannot authorize remote disclosure.

Reads fence cancellation, connection identity and the latest request before
publishing values or errors. Per-profile policy mutations serialize user intent
and retain their original connection admission while queued; a cancelled view
cannot cancel an accepted write or move it to a replacement connection.
Programmatic toggle restoration never issues a write. Unknown direct-RPC
outcomes are not replayed or treated as definite rejection.

`SessionSearchTransportTests` exercises summary-trigger suppression, read versus
write ordering, serialized mutations, and consent invalidation on reconnect.
