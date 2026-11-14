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

**Declarations.** `swift_source.py` reads Xcode's `swiftc -frontend -dump-parse` output from stdin,
shared by method shards and real-UI journey selection. Only no-argument, non-private instance
`test` methods in the named class or its top-level extensions qualify. Strings, comments and
nested types cannot introduce methods. Parse errors, conditional/macro declarations, source-location
directives, unsupported attributes or compiler output keep the class whole rather than dropping tests. This is source
parsing only; selection does not build an app or use a simulator.

**Packing.** Shards are consecutive runs of the selected methods, in selection order, whose
estimates fit 570 s: twice that plus 60 s of process launch is the runner's unchanged 1200 s
focused deadline, so a shard keeps it even if every method takes twice its estimate. A method's
estimate is the longest clean, uncontended passed or failed case duration in the D2 test ledger.
The caller sends one immutable duration snapshot and selector multiset to the mini; the executor
checks native, boundary, journey and selected-file equality before any build or test starts.
The mini's nonce-local artifact directory is not a history source. Missing ledger history is an
empty estimate set, never permission to omit a selector. A method with no record counts 190 s, so unmeasured
methods run three to a process. A method estimated above 570 s runs alone; a class run whole counts
the full 570 s. Estimates only pack processes: they never select, skip, order within a process or
judge a test. `--plan` prints each shard's `estimatedSeconds`, its command as it runs alone, and the
lanes shards may use beside each other (`iosLanes`), plus the concurrency limit (`iosJobs`).

Each native run retains `stages.json` with epoch and monotonic observations for lease admission,
provision/boot, build, test-process execution, extraction and shutdown. A started stage without a
finish remains interrupted/unknown. Install is explicitly delegated to xcodebuild at test-process
start: no separate install duration is inferred from that envelope. Build/test `process.json` also
retains process start/end clocks. These receipts describe lifecycle costs, not another history store.

**Lanes.** `--ios-jobs 1|2|3` limits concurrent native shards and real-UI journey lanes
(default 1); phone and iPad shards run one at a time unless the caller explicitly widens it.
Home plans heavy work within the three-slot ceiling; follow the brief's "Heavy work" paragraph.
The option changes neither selection nor packing nor the runner's three host-wide slots.
Shards run longest estimate first on up to that many phone lanes: the worktree's own lane, then
this worktree's `verify-iphone2-<hash>` and `verify-iphone3-<hash>` lanes (the canonical iPhone;
one per further slot of `scripts/ios-test-lock.py`'s `HOST_SLOTS`), with iPad-only shards on the
iPad lane, never more shards than the selected job limit. Each lane is the runner's own leased
lane with its own simulator; the lanes share this worktree's test products, and the sweep reclaims
them with the worktree. Every shard waits for a slot, printing its holders, then runs to its
outcome. SIGINT/SIGTERM stops and joins every lane's process group.

The existing runner owns lanes, leases, cleanup and the three host-wide slots; run one verify
per worktree. Build, shards and scenario profiling use unbounded slot acquisition in ordinary
runs and `--all` alike. No iOS acquisition result is deferred to batch. Build/test errors,
unexpected acquisition refusals and zero-test runs fail. `verify --batch` explicitly requests
three lanes for its full verifier and real-UI journeys.

## Verify

The [verify CLI tests](README.md#verify) drive this lane through a stand-in runner
(`IosLaneTests`): selection, build reuse, extensions, iPad lanes, packing by recorded times,
default serial ordering and unchanged selection/counts at each job limit, explicit concurrent lanes, failed acquisition, interrupts, and short or empty runs.
