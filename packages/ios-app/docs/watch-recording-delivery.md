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

## First local device test

Run the focused simulator checks before installing:

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run \
  --only-testing TronMobileTests/WatchRecordingDeliveryTests \
  --only-testing TronMobileTests/WatchRecordingStoreTests
```

For an end-to-end recording, first install and verify the **source-built local
Mac Release app** using the manual sequence in
[`macOS local reinstall`](../../../packages/mac-app/docs/development.md#reinstall-a-local-release-build).
That app bundles the Gateway recording routes and retained-file owner. Gateway
protocol v5 is already shared with the current iOS build: protocol parity alone
does not mean an already-running v5 Gateway has the recording feature. Do not
install iOS first and assume uploads will work against the old payload.

After the user completes Mac replacement, helper enablement, Resume, and
`scripts/tron mac verify`:

1. On iPhone, open **Tron → Settings → Watch Recordings** and select an enabled
   paired Mac profile. This sets the destination for future Watch recordings.
2. Install/launch from the feature checkout using
   `scripts/tron-ios-device install`. Wireless pairing is supported; keep the
   unlocked iPhone reachable and the paired Watch nearby. The helper builds the
   canonical `Tron Device` + `LocalDevice` pair and checks Mac/iOS protocol parity.
3. Wait for Tron to appear in **Watch → My Watch → Available Apps**, install it
   if needed, then on the Watch use Record, Pause, Resume, and Stop. Keep the
   devices near one another while WatchConnectivity transfers the originals.
4. On iPhone, the Watch Recordings delivery status reports transfer/upload
   progress. A **verified Mac receipt** is the only saved confirmation. Check
   `<tronHome>/workspace/files/recordings/<recording-uuid>/commit.json` on the Mac
   if independently checking the retained receipt.

For an offline capture made before destination setup, explicitly assign that
recording to an enabled paired Mac on the same iPhone screen, then retry pending
recordings. Never treat a Watch transfer or segment acknowledgement as a Mac
save, and do not delete Watch/iPhone originals during this test. The Watch
currently admits at most 512 one-minute segments (about 8.5 hours per recording).

These simulator tests cover local store recovery, immutable delivery planning,
fixture-shaped finalization, and receipt validation. They do not prove microphone
capture, WatchConnectivity, background URLSession behavior, signed installation,
or physical Watch → iPhone → Mac delivery; those require the user-owned device
run above.
