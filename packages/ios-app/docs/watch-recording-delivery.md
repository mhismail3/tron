# Watch recording delivery

`WatchRecordingDeliveryCoordinator` owns iPhone background delivery. It sends
segment source files through a background `URLSession` upload task and finalizes
with an atomically written JSON request file. Background task descriptions bind
tasks to recording/segment identity; confirmed segment numbers are persisted so
launch/task reconciliation can safely retry idempotently. A recording is always
sent to the profile and machine stored with its custody metadata, with its token
resolved from `GatewayProfileStore`/Keychain at send time. Local source files
remain retained; only a verified exact Gateway receipt is persisted and relayed.

The visible delivery screen configures the future Watch destination and offers
an explicit assignment for unbound existing recordings. Existing assignment is
stored in a phone-owned per-recording sidecar, separate from immutable capture
metadata; it is never changed by the future-recording destination picker. Exact
assignment and verified receipt messages are relayed to Watch so saved status
can be recovered for a recording that had no original destination.

Delegate callbacks are serialized on the main operation queue and handled
synchronously on MainActor, so the background URLSession completion runs only
after `urlSessionDidFinishEvents` and all earlier callbacks have persisted.
At most two upload tasks are outstanding; transient failures use bounded
exponential opportunities while authorization failures request user attention.
Profiles are reloaded from their authoritative store for each drain.
