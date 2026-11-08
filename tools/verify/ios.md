# Verify: iOS lane

The iOS part of [`scripts/tron verify`](README.md): build, index check and the selected
UIValidation tests.

`--all`, `ios` tests, or a changed `ios-app/` module runs this lane unless `--skip ios`:
1. **`ios source policy`** runs `packages/ios-app/scripts/test-source-policy.sh` (about 1 s);
   a violation fails the run before anything builds.
2. **`ios build`** reuses clean, current-commit stamped products/index; otherwise builds
   with `scripts/tron-ios-test build`. Subsequent runs reuse that build.
3. **`layers ios`** reads that index. Stale/missing indexes fail; no symbol-scan fallback.
4. **`tests: ios`** uses the same products. Each selected class (named or extended by the
   file) runs as its `test` methods in runner processes (`tests: ios 1/N`); a class whose methods
   cannot be read or that holds test-shaped methods the reader cannot place runs whole. Each
   method shard must pass exactly its named tests. A method that skips unless on an iPad (in
   itself, its class's `setUp` or a helper it calls directly) runs in its own shards on this
   worktree's iPad lane (`verify-ipad-<hash>`, `iPad Pro 13-inch (M5)`), on the same products.
   Every admitted shard runs before a failure is reported. Harnessed journeys use their own lanes. A file naming
   neither fails unless iOS is skipped. Counts/failures come from XCTest `summary.json`
   (`passedTests`); `--update-locks` passes `TEST_RUNNER_TRON_UPDATE_LOCKS`. Goldens are
   source: commit and rebuild before comparing.

**Packing.** Shards are consecutive runs of the selected methods, in selection order, whose
estimates fit 570 s: twice that plus 60 s of process launch is the runner's unchanged 1200 s
focused deadline, so a shard keeps it even if every method takes twice its estimate. A method's
estimate is the longest time any runner log the runner retains on this Mac (`test.log` under
`TRON_IOS_TEST_RESULTS_DIR`, default `~/Library/Developer/Tron/ios/test-runs`, every worktree and
lane, failed cases included) records for it; a method with no record counts 190 s, so unmeasured
methods run three to a process. A method estimated above 570 s runs alone; a class run whole counts
the full 570 s. Estimates only pack processes: they never select, skip, order within a process or
judge a test. `--plan` prints each shard's `estimatedSeconds`, its command as it runs alone, and the
lanes shards may use beside each other (`iosLanes`).

**Lanes.** Shards run at once, longest estimate first, on one lane per host slot: the
worktree's own lane, then this worktree's `verify-iphone2-<hash>` and `verify-iphone3-<hash>`
lanes (the canonical iPhone; one per further slot of `scripts/ios-test-lock.py`'s `HOST_SLOTS`),
with iPad-only shards on the iPad lane, never more shards than slots. Each lane is the runner's own
leased lane with its own simulator; the lanes share this worktree's test products, and the sweep
reclaims them with the worktree. A shard started while none of the run's other shards is in flight
acquires its slot exactly as a serial run did (below). A shard started beside one in flight takes a
slot only if one is free at once (`--host-slot-wait-seconds 0`), so the run never queues behind its
own work or holds a waiter against another worktree's job. Refused, it admitted no work: its attempt
is withdrawn (`requeued`), its lane goes last for the retry, and no further lane starts until one of
the run's shards ends. A refusal while nothing else of the run is in flight is the busy exit 73:
that shard and every unstarted one are `deferred`, never passed; admitted shards keep their
outcomes. SIGINT/SIGTERM stops and joins every lane's process group.

The existing runner owns lanes, leases, cleanup and the three host-wide slots; run
one verify per worktree. Pre-land build/run passes `--host-slot-wait-seconds 30`, bounding
only acquisition, never admitted work. No option retains unbounded waiting (including
batch `--all`). Busy exit 73 records named checks/tests as `deferred`, exit 0, never
passed. A deferred build also defers its index/tests; other affected checks still run.
The batch covers those files. Genuine build/test errors and zero-test runs still fail.

## Verify

The [verify CLI tests](README.md#verify) drive this lane through a stand-in runner
(`IosLaneTests`): selection, build reuse, extensions, iPad lanes, packing by recorded times,
concurrent lanes, requeued and deferred admission, interrupts, and short or empty runs.
