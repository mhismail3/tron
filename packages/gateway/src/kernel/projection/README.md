# Projection

Owns disposable session transcript/tree, activity, history and attention projections.
Pi session entries remain canonical; projection never creates a second transcript
or history store. Runtime mutations and activity producers remain with their run
and delegation owners.

Transcript page cursors fence the runtime generation, leaf and adjacent anchor.
Snapshots retain one synchronous branch cut for both bounded transcript and
canonical tool-result ownership. Archive and live presentation facts are read
from their owners for each projection.

The attention lock runs through the real Gateway/Pi boundary. Reconnect,
run-event and delegation locks also protect this owner's wire projections.
Run selected validation with `scripts/tron verify --module gateway/projection`
(or `--changed` for a committed slice).
