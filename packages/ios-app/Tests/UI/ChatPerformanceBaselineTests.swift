import Darwin
import UIKit
import XCTest
@testable import TronMobile

final class ChatPerformanceBaselineTests: XCTestCase {
    @MainActor
    func testMaximumPagedSessionOpeningBaseline() throws {
        guard ProcessInfo.processInfo.environment["TRON_PERFORMANCE_BASELINE"] == "1" else {
            throw XCTSkip("Run explicitly to collect the pinned performance baseline.")
        }

        let snapshot = try Self.maximumPagedSnapshot()
        print(
            "TRON_PERFORMANCE_CONTEXT thermal=\(Self.thermalStateCode) "
                + "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) "
                + "maxFPS=\(Self.maximumFramesPerSecond)"
        )
        let options = XCTMeasureOptions()
        // XCTest adds one discarded warm-up invocation to this measured count.
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStop]
        let metrics: [any XCTMetric] = [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric(),
            ProcessAllocationMetric(),
            XCTOSSignpostMetric(
                subsystem: "com.tron.mobile",
                category: "Chat",
                name: "Scroll Command Settle"
            ),
        ]

        measure(metrics: metrics, options: options) {
            let harness: ChatViewScrollHarness
            do {
                harness = try ChatViewScrollHarness(
                    snapshot: snapshot,
                    displayFrameScheduler: .displayLink,
                    performanceSignposts: SystemPerformanceSignposts.shared
                )
            } catch {
                stopMeasuring()
                XCTFail("Unable to install hosted performance fixture: \(error)")
                return
            }

            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if let observation = harness.recorder.samples.last?.observation,
                   observation.isReady,
                   observation.scrollSettledDistance != nil,
                   observation.visibleRowIDs.contains(harness.lastTranscriptID) {
                    break
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            stopMeasuring()

            let observation = harness.recorder.samples.last?.observation
            XCTAssertEqual(observation?.isReady, true)
            XCTAssertNotNil(observation?.scrollSettledDistance)
            XCTAssertTrue(observation?.visibleRowIDs.contains(harness.lastTranscriptID) == true)
            harness.cleanup()
        }
    }

    @MainActor
    private static var maximumFramesPerSecond: Int {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.maximumFramesPerSecond ?? 0
    }

    private static var thermalStateCode: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 4
        }
    }

    private static func maximumPagedSnapshot() throws -> SessionSnapshot {
        let builder = SessionScenarioBuilder(seed: 401)
        var snapshot = try builder.openingTail(targetEncodedBytes: 10_000)
        let totalEntries = 10_000
        snapshot.transcript = builder.pagedMixedSession(totalEntries: totalEntries).page(
            before: totalEntries,
            count: totalEntries
        )
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = totalEntries
        return snapshot
    }
}

private final class ProcessAllocationMetric: NSObject, XCTMetric {
    private var start = malloc_statistics_t()
    private var end = malloc_statistics_t()

    func copy(with zone: NSZone? = nil) -> Any {
        ProcessAllocationMetric()
    }

    func willBeginMeasuring() {
        malloc_zone_statistics(malloc_default_zone(), &start)
    }

    func didStopMeasuring() {
        malloc_zone_statistics(malloc_default_zone(), &end)
    }

    func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp,
        to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        [
            measurement(
                identifier: "com.tron.mobile.tests.allocations.live-block-delta",
                name: "Live Allocation Block Delta",
                value: Double(Int64(end.blocks_in_use) - Int64(start.blocks_in_use)),
                unit: "blocks"
            ),
            measurement(
                identifier: "com.tron.mobile.tests.allocations.live-byte-delta",
                name: "Live Allocation Byte Delta",
                value: Double(Int64(end.size_in_use) - Int64(start.size_in_use)),
                unit: "B"
            ),
            measurement(
                identifier: "com.tron.mobile.tests.allocations.reserved-bytes",
                name: "Allocator Reserved Bytes",
                value: Double(end.size_allocated),
                unit: "B"
            ),
        ]
    }

    private func measurement(
        identifier: String,
        name: String,
        value: Double,
        unit: String
    ) -> XCTPerformanceMeasurement {
        XCTPerformanceMeasurement(
            identifier: identifier,
            displayName: name,
            doubleValue: value,
            unitSymbol: unit,
            polarity: .prefersSmaller
        )
    }
}
