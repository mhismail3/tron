# Phase 0 chat performance baseline

A reproducible comparison point for chat opening and preparation, diagnostic rather than a
release budget. Physical-device evidence is authoritative for frame hitches. Never add device
identifiers, profile data or fixture content to this report or to signposts.

## Fixture and method

Seed `401`: 10,000 deterministic mixed transcript entries installed through the hosted
authoritative-snapshot gate (deliberately beyond the production 512-item tail, to characterize
cold assembly; it does not redefine that bound). The boundary mounts the production
`ChatView`/`LazyVStack` and waits for the latest semantic row, first ready frame and tail settle,
with a fresh empty cache per iteration; one discarded warm-up, five measured samples. Metrics:
monotonic time, process CPU, physical and peak memory, malloc-zone live deltas (high-variance,
never a gate) and reserved bytes. Results are `.xcresult` bundles
(`xcresulttool get test-results metrics`).

`DevicePerformance` is the optimized hosted-test configuration (Swift `-O`, whole module,
optimized Clang, with `ENABLE_TESTABILITY` and `HOSTED_TEST`; provisioned identity; no archive)
behind `scripts/tron-profile ios`. Release-like normal-use profiling uses the `Tron Device` /
`LocalDevice` Profile action; `Release` is the `Tron Release` scheme's.

## Results

Five-sample averages; simulator iPhone 17 Pro, iOS 26.4.1, `Test`, 60 Hz; pinned `iPhone18,2`,
iOS 27.0, `DevicePerformance` (recorded while it was still unoptimized), 120 Hz; nominal thermal,
Low Power off.

| Metric | Simulator | Pinned device |
|---|---:|---:|
| Fixture boundary time | 1.037 s | 0.692 s |
| Scroll-command settle | 0.350 s | 0.477 s |
| Peak physical memory | 107,082 kB | 110,027 kB |
| Allocator reserved | 85,691,597 B | 91,324,416 B |
| Animation hitches | not emitted | 0 (0 ms/s) |

The device's XCTest frame-rate estimate was internally inconsistent and is not a cadence gate;
simulator cadence evidence is the hosted `CADisplayLink` recorder. A real scrolling cadence
threshold still needs calibration on the pinned device.

| Simulator workload (five samples) | Clock | Peak physical | Allocator reserved |
|---|---:|---:|---:|
| 180 Markdown revisions, one max-size source cold/warm, one thinking segment | 0.044 s | 33,085 kB | 65,945,600 B |
| Sixteen 2,048 × 1,536 thumbnail decodes plus one full preview | 1.317 s | 81,054 kB | 44,613,632 B |

## Provisional ratchets

Safety bounds, not measured release targets; pinned-device displayed-frame, thermal and
peak-memory acceptance is still pending.

- **Text preparation cache:** 4 MiB shared by Markdown sources and presentation, 512 Markdown
  revisions (the Gateway page ceiling), 4,096 thinking segments; each source ≤ 320,000 bytes
  (the projected-content wire ceiling, so at most 13 maximum sources); preparation concurrency
  two with newest-only admission per identity; one projection eagerly prepares at most 32
  Markdown and 128 thinking values from its newest 512 entries; older uncached pages use the
  cold path.
- **Media:** 192-pixel thumbnails (64-point chip at 3×), 4 MiB decoded (28 full squares) and 64
  items; one fetch/decode per identity; 25 MiB encoded admission; full previews downsampled by
  ImageIO to ≤ 4,096 px and 64 MiB of rows, never inserted in the thumbnail LRU, one at a time
  with priority on the single shared preparation slot; ≤ 32 thumbnail flights; memory pressure
  cancels. Inline display cards keep one flight per artifact (≤ 4) and retain ≤ 8 prepared
  documents or 4 MiB (values over 1 MiB are not retained).

## Reproduction

The baseline tests skip unless the test process sees `TRON_PERFORMANCE_BASELINE=1`; xcodebuild
forwards a caller variable only with the `TEST_RUNNER_` prefix. `scripts/tron-ios-test` builds only
UI-validation products, so the pinned device run is the baseline of record (from
`packages/ios-app`, under the device's host-wide lease; exit 73 names the holder):

```bash
DEVICE_ID=<pinned-device-coredevice-id>
TEST_RUNNER_TRON_PERFORMANCE_BASELINE=1 python3 ../../scripts/ios-test-lock.py \
  --lock "$HOME/.tron/internal/run/ios-device-$DEVICE_ID.lease.lock" \
  --resource "physical iOS device $DEVICE_ID" --worktree "$(git rev-parse --show-toplevel)" -- \
  xcodebuild test-without-building \
  -project TronMobile.xcodeproj -scheme 'Tron Device Performance' \
  -configuration DevicePerformance -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath /tmp/tron-perf-device-derived \
  -only-testing:TronMobileProfiling/ChatPerformanceBaselineTests \
  -resultBundlePath /tmp/tron-perf-device.xcresult
```

## Multi-surface workload

A manual release-validation contract: one and five concurrent active sessions with dashboard →
chat → sheet → nested sheet while streams and summaries continue; record hitches, MainActor
latency, CPU/GPU, active animations, suppressed covered-surface work and uncover-to-reconciled
latency. Gates: zero covered-surface animation clocks and transcript/dashboard installations, one
bounded catch-up before live updates resume, no authority event loss, settled screenshots,
accessibility and scroll anchors equivalent to the active baseline. Coordinator and projection
tests prove admission invariants only, never device evidence.
