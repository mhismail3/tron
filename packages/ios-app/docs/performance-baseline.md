# Phase 0 chat performance baseline

This report freezes a reproducible Phase 0 comparison point. It is diagnostic,
not an approved release budget. Physical-device evidence remains authoritative
for frame hitches.

## Fixture and method

- Seed: `401`.
- Fixture: 10,000 deterministic mixed transcript entries installed through the
  hosted authoritative-snapshot gate.
- Boundary: mount the production `ChatView`/`LazyVStack`/native scroll view and
  wait for the latest semantic row, first ready frame, and practical-tail settle.
- Cache: cold disposable cache with a unique empty root for every iteration.
- Samples: five measured iterations after one discarded warm-up iteration.
- Metrics: monotonic time, process CPU, physical/peak memory, default malloc-zone
  live block/byte deltas and reserved bytes, plus the animation signpost for
  `Scroll Command Settle`.
- Result artifacts are ordinary `.xcresult` bundles. Extract their machine-readable
  values with `xcresulttool get test-results metrics`.

The malloc-zone deltas are intentionally reported rather than treated as a gate:
cleanup and allocator reuse make them high-variance. Reserved bytes and peak
physical memory are the more stable comparison values.

## Recorded environment

| Target | Runtime | Build | Refresh mode | Thermal | Low Power |
|---|---|---|---:|---|---|
| iPhone 17 Pro simulator | iOS 26.4.1 | `Test` | 60 Hz maximum | nominal | off |
| Pinned `iPhone18,2` | iOS 27.0 | `DeviceTest` | 120 Hz maximum | nominal | off |

`DeviceTest` is a debug, `HOSTED_TEST` configuration using the provisioned app
identity. It exists only to run the same deterministic hosted fixture on the
pinned phone; it is not a distribution configuration, and the scheme's archive
action explicitly uses `Prod` rather than `DeviceTest`.

## Results

Averages below use five samples.

| Metric | Simulator | Pinned device |
|---|---:|---:|
| Fixture boundary monotonic time | 1.037 s | 0.692 s |
| Scroll-command settle duration | 0.350 s | 0.477 s |
| Peak physical memory | 107,082 kB | 110,027 kB |
| Allocator reserved bytes | 85,691,597 B | 91,324,416 B |
| Live allocation block delta | 43,323 | 30,496 |
| Live allocation byte delta | 10,225,872 B | 9,510,221 B |
| Animation hitches | not emitted by simulator XCTest | 0 |
| Animation hitch time ratio | not emitted by simulator XCTest | 0 ms/s |

The physical XCTest report also emitted a frame-rate estimate while reporting
zero animation frame count. That estimate is internally inconsistent and is not
used as a cadence gate. Simulator frame evidence instead remains the hosted
`CADisplayLink` recorder's repeated one-sample-per-presented-frame contract.
Phase 5 must replace the current multiple-geometry-update diagnostics and then
calibrate a real scrolling cadence threshold on the pinned device.

## Reproduction

Generate and build before either run. The performance test skips unless the
explicit environment value is enabled, so normal focused/full suites remain fast.

```bash
# Simulator
TRON_PERFORMANCE_BASELINE_VALUE=1 xcodebuild test-without-building \
  -project TronMobile.xcodeproj -scheme 'Tron Fast' -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/ChatPerformanceBaselineTests/testMaximumPagedSessionOpeningBaseline \
  -resultBundlePath /tmp/tron-perf-simulator.xcresult

# Provisioned pinned device
TRON_PERFORMANCE_BASELINE_VALUE=1 xcodebuild test-without-building \
  -project TronMobile.xcodeproj -scheme 'Tron Device Performance' \
  -configuration DeviceTest -destination 'platform=iOS,id=<pinned-device-udid>' \
  -derivedDataPath /tmp/tron-perf-device-derived \
  -only-testing:TronMobileTests/ChatPerformanceBaselineTests/testMaximumPagedSessionOpeningBaseline \
  -resultBundlePath /tmp/tron-perf-device.xcresult
```

Do not add device identifiers, profile data, fixture content, or other personal
values to this report or performance signposts.
