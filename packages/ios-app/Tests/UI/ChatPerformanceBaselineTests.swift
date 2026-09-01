import Darwin
import UIKit
import XCTest
@testable import TronMobile

final class ChatPerformanceBaselineTests: XCTestCase {
    func testStreamingTextPreparationThroughputBaseline() throws {
        guard ProcessInfo.processInfo.environment["TRON_PERFORMANCE_BASELINE"] == "1" else {
            throw XCTSkip("Run explicitly to collect the pinned performance baseline.")
        }
        let builder = SessionScenarioBuilder(seed: 6_401)
        let updates = builder.markdownStream(updateCount: 60, rate: 30)
            + builder.markdownStream(updateCount: 120, rate: 60)
        let maximumSource = String(repeating: "x", count: ChatTextPreparationPolicy.maximumSourceBytes)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let metrics: [any XCTMetric] = [
            XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), ProcessAllocationMetric(),
        ]

        var retirementFailed = false
        measure(metrics: metrics, options: options) {
            guard !retirementFailed else { return }
            let completed = DispatchSemaphore(value: 0)
            let task = Task {
                defer { completed.signal() }
                let cache = ChatTextPreparationCache(
                    maximumNewMarkdownPreparations: ChatTextPreparationPolicy.maximumMarkdownRevisions,
                    maximumNewThinkingPreparations: ChatTextPreparationPolicy.maximumThinkingSegments
                )
                for update in updates {
                    if Task.isCancelled { return }
                    _ = await cache.prepare([.init(
                        identity: .init(kind: .markdown, value: "streaming"),
                        source: update.text
                    )])
                }
                if Task.isCancelled { return }
                _ = await cache.prepare([
                    .init(identity: .init(kind: .markdown, value: "maximum"), source: maximumSource),
                    .init(identity: .init(kind: .thinking, value: "thinking"), source: "bounded thinking…"),
                ])
                if Task.isCancelled { return }
                _ = await cache.prepare([
                    .init(identity: .init(kind: .markdown, value: "maximum"), source: maximumSource),
                ])
            }
            if completed.wait(timeout: .now() + 30) != .success {
                task.cancel()
                if completed.wait(timeout: .now() + 5) != .success {
                    retirementFailed = true
                    XCTFail("Timed-out preparation work did not retire; remaining measurement iterations are suppressed")
                    return
                }
                XCTFail("Streaming text preparation timed out")
            }
        }
        XCTAssertFalse(retirementFailed)
    }

    func testImageDecodePreparationBaseline() throws {
        guard ProcessInfo.processInfo.environment["TRON_PERFORMANCE_BASELINE"] == "1" else {
            throw XCTSkip("Run explicitly to collect the pinned performance baseline.")
        }
        let fixture = try SessionScenarioBuilder(seed: 6_402).generatedImageFixture(
            format: .jpeg,
            pixelWidth: 2_048,
            pixelHeight: 1_536,
            orientation: .right
        )
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let metrics: [any XCTMetric] = [
            XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), ProcessAllocationMetric(),
        ]

        measure(metrics: metrics, options: options) {
            do {
                for _ in 0..<16 {
                    _ = try ChatMediaLoader.decodeThumbnail(fixture.encodedData)
                }
                _ = try ChatMediaLoader.decodeFullPreview(fixture.encodedData)
            } catch {
                XCTFail("Unable to decode the deterministic media fixture: \(error)")
            }
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
