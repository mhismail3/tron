# Phase 0 chat performance baseline

This report freezes a reproducible Phase 0 comparison point. It is diagnostic,
not an approved release budget. Physical-device evidence remains authoritative
for frame hitches.

## Fixture and method

- Seed: `401`.
- Fixture: 10,000 deterministic mixed transcript entries installed through the
  hosted authoritative-snapshot gate. This intentionally exceeds the production
  512-item authoritative tail to characterize cold linear assembly and explicitly
  retained history; it does not redefine or prove the production admission bound.
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
| Pinned `iPhone18,2` | iOS 27.0 | `DevicePerformance` | 120 Hz maximum | nominal | off |

`DevicePerformance` is a debug, `HOSTED_TEST` configuration using the provisioned app
identity. It exists only to run the same deterministic hosted fixture on the
pinned phone; it is not a distribution configuration, and the scheme's archive
scheme has no archive action; Release is reserved for the separate `Tron Release`
archive/analyze/profile scheme.

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

## Phase 6 provisional ratchets

These later decisions do not rewrite or reinterpret the historical measurements
above. Checkpoints 6.0/6.1 characterize cumulative Markdown/media fixtures and
extract the existing cold Markdown presentation. Phase 6.2 now adds the bounded
text-preparation cache described below without adding truncation, placeholders, a
parser dialect, or an incremental-prefix production path. Phase 6.3 now implements the bounded media owner described below.

The implemented Phase 6.2 text cache retains the Phase 6.0 provisional 4 MiB
(4,194,304 bytes) shared across accounted source and presentation storage, 512
Markdown revisions, and 4,096 thinking
segments. The 512 count aligns with the Gateway page item ceiling and bounds a
page of tiny entries; if all 512 slots are occupied, the byte ratchet permits an
8 KiB average. The 4,096 thinking count bounds tiny animated segments; if thinking
alone fills the byte ratchet, its average is 1 KiB. The limits are conjunctive,
not additive: Markdown and thinking compete for the same 4 MiB.

An individual cached source may not exceed the exact 320,000-byte Gateway
projected-content wire ceiling. Consequently the byte ratchet can hold at most 13
maximum-size sources (13 × 320,000 = 4,160,000 bytes; 14 × 320,000 = 4,480,000
bytes, over budget), regardless of the 512 count. Preparation concurrency two
limits simultaneous maximum source inputs to 640,000 bytes; newest-only admission
per identity prevents both completed revisions from becoming retained state. One
projection eagerly prepares at most 32 new Markdown and 128 new thinking values
from its newest bounded 512-entry tail; exact older cache hits remain usable while
uncached explicitly paged history uses the cold fallback. The
4 MiB admitted cache plus up to 640,000 bytes of source work is only a provisional
working-set floor: attributed-string construction and framework allocations still
require peak-memory calibration.

The implemented Phase 6.3 media owner retains the Phase 6.0 provisional limits and derives
192 pixels from the existing 64-point chip at a 3× display scale. One square
192-pixel RGBA thumbnail is 192 × 192 × 4 =
147,456 decoded bytes. Thus the 4 MiB decoded ratchet admits at most 28 full-square
thumbnails (4,128,768 bytes; a 29th would reach 4,276,224 bytes), while the
64-item ratchet separately bounds small/aspect-ratio-thin images. If all 64 slots
are occupied, their decoded average is 65,536 bytes, equal to a 128 × 128 RGBA
image. One fetch/decode per identity is a single-flight rule that prevents
concurrent duplicate wire, decode, and peak allocations.

The encoded admission ceiling is 25 MiB (26,214,400 bytes). One uncached full
preview bounds preview multiplicity and keeps it out of the thumbnail LRU; it does
not claim that a full decoded preview fits the 4 MiB thumbnail budget. Full-preview
ImageIO preparation applies orientation and downsamples before publication to at
most 4,096 pixels on either axis and 64 MiB (67,108,864 bytes) of decoded rows.
Worst-case peak reasoning must therefore include the 4 MiB decoded thumbnail budget,
one admitted encoded payload up to 25 MiB, and one decoded preview up to 64 MiB,
plus framework/transient decode overhead still requiring physical calibration.
None of these cache/media owners exists at the 6.1 source checkpoint.

The loader enforces these values with profile/lifecycle/connection/blob single-flight identity,
one shared preparation slot, a 32-thumbnail-flight admission ceiling, transport-level declared and
streamed response limits, off-main ImageIO downsampling, deterministic LRU eviction, exact
late-publication rejection, and app-lifetime memory-pressure cancellation. Full previews are never
inserted into the thumbnail LRU, receive priority at the shared slot, are decoded through the bounded
ImageIO path, and only one full-preview flight is owned at a time. Consequently only one admitted
encoded response/decode working set exists at once.

### Phase 6 simulator workload checkpoint

The opt-in baseline suite now measures previously unrepresented preparation throughput and decode boundaries in addition to opening. A five-sample iPhone 17 Pro simulator run on the committed Test configuration consumed 180 cumulative adversarial Markdown revisions derived from the 30/60 Hz source fixtures as a parser/cache throughput workload, one exact maximum-source cold/warm preparation, one thinking segment, sixteen 2,048 × 1,536 oriented thumbnail decodes, and one full-preview decode. Arrival cadence, projection coalescing, single-flight ownership, caching, and eviction remain covered by their deterministic owner tests and require separate displayed-frame/physical calibration; these two microbenchmarks do not claim to measure them.

| Workload | Clock | CPU | Peak physical | Allocator reserved |
|---|---:|---:|---:|---:|
| Streaming text/thinking preparation throughput | 0.044 s | 0.045 s | 33,085 kB | 65,945,600 B |
| Thumbnail/full-preview decode boundary | 1.317 s | 1.325 s | 81,054 kB | 44,613,632 B |

Live allocation deltas remain high-variance diagnostics, matching the original baseline policy. These simulator measurements prove reproducible workload ownership and provide comparison points; they do not replace pinned-device displayed-frame, thermal, or peak-memory acceptance.

These values are provisional safety ratchets rather than measured release targets.
Pinned-device cold/warm 30/60 Hz Markdown, maximum-source, thinking-segment, image
page, memory-pressure, preview, pixel/accessibility equivalence, displayed frames,
and peak-memory evidence is still required. Phase 6.0 source characterization and
budgets, Phase 6.1 pure presentation, Phase 6.2 bounded text preparation, and Phase 6.3
bounded media loading are complete; physical acceptance and the Phase 6 exit gate remain pending.

## Reproduction

Generate and build before either run. The performance test skips unless the
explicit environment value is enabled, so normal focused/full suites remain fast.

```bash
# Exact repository-owned simulator; unique log/result paths are automatic.
TRON_PERFORMANCE_BASELINE_VALUE=1 scripts/tron-ios-test run \
  --only-testing TronMobileTests/ChatPerformanceBaselineTests

# Provisioned pinned device
TRON_PERFORMANCE_BASELINE_VALUE=1 xcodebuild test-without-building \
  -project TronMobile.xcodeproj -scheme 'Tron Device Performance' \
  -configuration DevicePerformance -destination 'platform=iOS,id=<pinned-device-udid>' \
  -derivedDataPath /tmp/tron-perf-device-derived \
  -only-testing:TronMobileTests/ChatPerformanceBaselineTests \
  -resultBundlePath /tmp/tron-perf-device.xcresult
```

Do not add device identifiers, profile data, fixture content, or other personal
values to this report or performance signposts.

## Multi-surface workload

Performance validation must include one and five concurrent active sessions,
with dashboard → chat → sheet → nested-sheet presentation while streams and
summary updates continue. Record frame hitches, MainActor latency, CPU/GPU
activity, active animation count, suppressed covered-surface work, and
uncover-to-reconciled-frame latency. Functional gates are zero covered-surface
animation clocks, zero covered transcript/dashboard installations, one bounded
aggregate catch-up before ordinary live updates resume, and no authority event
loss. Settled screenshots, accessibility trees, and scroll-anchor behavior must
remain equivalent to the active-surface baseline. Simulator measurements are
diagnostic; physical-device evidence is authoritative. This workload is a
manual release-validation contract today: the repository does not yet automate
five simultaneous nested presentation flows or collect the physical-device
frame/CPU/GPU trace. The focused coordinator, projection, and clock tests prove
admission invariants only and must not be reported as measured device evidence.
