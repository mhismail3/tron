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

`session.search.policy.get` is issued only after a captured lifecycle or pool
admission, with per-profile request generations. A late read cannot overwrite a
newer toggle receipt or another profile. Missing/offline/error reads fail safe
to false and remain visible through the existing notice owner.
