# UIValidation tests

`TronMobileUITests` runs both user-visible app journeys and real Core kernel
contracts through the supported `scripts/tron-ios-test` lane. Kernel contracts
execute in the separate XCTest runner process with its own embedded Core
framework; the app's framework image remains owned by the app process. These are
not isolated hub/unit tests: only the named byte peer is synthetic.

`GatewayEventDeliveryContractTests` crosses `GatewaySocketConnection` with real
serialized hello/event/response envelopes, the production GatewayClient decoder
and receive loop, admission, epoch retirement and AsyncSequence. It observes
delivered frames, connection outcomes and bounded transport diagnostics, never
private Hub state. A peer response queued after events fences receive-loop
progress; peer close gates expose overlapping predecessor retirement. Cancellation
and lifetime completion must settle their consumers and retain no orphan waiter.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/GatewayEventDeliveryContractTests
```

Each batch uses one build and the lane's ordinary bounded native test runner. No
Gateway process, new runtime or alternate runner is needed. Existing
[PNG/accessibility locks](Locks/README.md) remain unchanged and run separately.
