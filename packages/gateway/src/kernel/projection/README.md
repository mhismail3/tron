# Projection

Owns disposable session transcript/tree, activity, history and attention projections.
Pi session entries remain canonical; projection never creates a second transcript
or history store. Runtime mutations and activity producers remain with their run
and delegation owners.

Transcript page cursors fence the runtime generation, leaf and adjacent anchor.
`SnapshotProjection` owns only the disposable revision/model-derived scan cache;
its synchronous source port reads live facts in the original call order. Snapshot
assembly retains one branch cut for bounded transcript and canonical tool-result
ownership. `session-pages` owns runtime/leaf/anchor fencing and canonical history
reads; `activity` bounds delivery-time wire views. Archive, recency, stream identity,
queue and lifecycle facts remain with their authoritative owners.

`ToolResultProjection` is the display module's single policy hook, including retained-resource
initialization and full-tree reconciliation. The native runtime exposes its one session/leaf
reference cut; authorization and resource I/O stay with display. Canonical, streaming and
cold/tree projectors take an explicit display callback; runtime adapters resolve the current hook for each call. Browser observation stays at
the attributed tool-result boundary with its exact provenance and load token;
the module closes over its live-view owner. No default validator or legacy
projection path bypasses the policy.

The attention lock runs through the real Gateway/Pi boundary. Reconnect,
run-event and delegation locks also protect this owner's wire projections.
Run selected validation with `scripts/tron verify --module gateway/projection`
(or `--changed` for a committed slice).
