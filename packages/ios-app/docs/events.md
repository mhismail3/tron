# Gateway events

Tron events are transient presentation and invalidation signals delivered by
`GatewayClient`. They are not a durable journal and are not reconstructed into a
local database.

`AppModel.handle(_:)` owns routing:

- session snapshot/change topics replace the corresponding authoritative
  snapshot or trigger a paginated list refresh;
- provider/package/settings topics refresh their owning projections;
- authentication prompts drive the generic secure prompt sheet;
- extension interaction topics drive select, confirm, input, or editor sheets;
- terminal output/exit topics update the bounded SwiftTerm adapter;
- stopping/restart topics move connection state into reconnect mode.

A reconnect always opens the selected session and receives complete current
runtime state with a bounded authoritative transcript tail. Earlier canonical
entries are fetched through `session.transcript` pages when requested. Correctness
must not depend on receiving every event while disconnected.
