import Foundation
import MetricKit
import Testing
@testable import TronMobile

struct IOSMetricKitDiagnosticsTests {
    private final class FakeManager: IOSMetricKitDiagnostics.Manager {
        var added: [MXMetricManagerSubscriber] = []
        var removed: [MXMetricManagerSubscriber] = []
        var callbackDuringAdd = false
        var callbackDuringRemove = false

        func add(_ subscriber: MXMetricManagerSubscriber) {
            added.append(subscriber)
            if callbackDuringAdd { subscriber.didReceive?([] as [MXMetricPayload]) }
        }

        func remove(_ subscriber: MXMetricManagerSubscriber) {
            removed.append(subscriber)
            if callbackDuringRemove { subscriber.didReceive?([] as [MXMetricPayload]) }
        }
    }

    @Test("MetricKit registration is app-lifetime and explicitly reversible")
    func registrationLifecycle() throws {
        let manager = FakeManager()
        manager.callbackDuringAdd = true
        manager.callbackDuringRemove = true
        let suite = "TronMetricKit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let collector = IOSMetricKitDiagnostics(store: store, manager: manager)

        #expect(manager.added.count == 1)
        collector.start()
        #expect(manager.added.count == 1)
        collector.stop()
        #expect(manager.removed.count == 1)
        collector.stop()
        #expect(manager.removed.count == 1)
    }

    @Test("typed MetricKit conversion preserves units, histogram buckets, and bounds")
    func typedConversionBoundary() {
        let seconds = Measurement(value: 1.25, unit: UnitDuration.seconds)
        #expect(IOSMetricKitDiagnostics.formattedMeasurement(seconds, unit: .milliseconds) == "1250.000")
        #expect(IOSMetricKitDiagnostics.formattedNumber(.nan) == "unknown")
        #expect(IOSMetricKitDiagnostics.formattedNumber(.infinity) == "unknown")

        let buckets = (0..<10).map {
            IOSMetricKitDiagnostics.HistogramBucketProjection(
                lower: Double($0) * 100,
                upper: Double($0 + 1) * 100,
                count: $0 + 1
            )
        }
        let summary = IOSMetricKitDiagnostics.formattedHistogram(label: "launchLatency", buckets: buckets)
        #expect(summary.contains("launchLatencyBuckets=0.000-100.000ms:1"))
        #expect(summary.contains("launchLatencyBucketsOmitted=1"))
        #expect(!summary.contains("binaryName"))
        #expect(!summary.contains("/Users/"))

        let provenance = IOSMetricKitDiagnostics.diagnosticProvenanceEntry(
            applicationVersion: "2026.09",
            build: "42",
            os: "iOS 26.5"
        )
        #expect(provenance == "app=2026.09_build=42_os=iOS_26.5")
        #expect(IOSMetricKitDiagnostics.diagnosticProvenanceEntry(
            applicationVersion: "/Users/private/version",
            build: "42",
            os: "iOS 26.5"
        ).contains("[REDACTED]"))

        let stackJSON = #"{"callStacks":[{"frames":[{"binaryName":"/Users/private/Tron","binaryUUID":"01234567-89AB-CDEF-0123-456789ABCDEF","offsetIntoBinaryTextSegment":16}]}]}"#.data(using: .utf8)!
        let stack = IOSMetricKitDiagnostics.boundedCallStackMetadata(stackJSON)
        #expect(stack.contains("01234567-89AB-CDEF-0123-456789ABCDEF:0x10"))
        #expect(!stack.contains("binaryName"))
        #expect(!stack.contains("/Users/"))
        #expect(stack.contains("stackSymbols=omitted"))
        let oversizedStack = IOSMetricKitDiagnostics.boundedCallStackMetadata(Data(repeating: 0, count: 65 * 1024))
        #expect(oversizedStack.contains("stackFramesOmitted=1"))
    }

    @Test("bounded MetricKit records retain only safe, deduplicable mailbox data")
    func boundedStoreExportContract() async throws {
        let suite = "TronMetricKit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let value = GatewayProfileLogRecord(
            profileID: "ios-metrickit:ios-client",
            profileLabel: "iOS MetricKit",
            record: GatewayLogRecord(
                timestamp: GatewayTimestamp.preciseString(from: .now),
                level: "warning",
                message: "kind=diagnostic stackFrames=UUID:0x10 stackSymbols=omitted",
                event: "ios.metrickit",
                source: "ios-client"
            ),
            incidentID: "diagnostic-fixture"
        )
        store.record([value, value])
        await store.flush()
        #expect(await store.load().count == 1)

        let boundedValues = (0..<120).map { index in
            GatewayProfileLogRecord(
                profileID: value.profileID,
                profileLabel: value.profileLabel,
                record: value.record,
                incidentID: "diagnostic-fixture-\(index)"
            )
        }
        store.record(boundedValues)
        await store.flush()
        let retained = await store.load()
        #expect(retained.count <= IOSClientDiagnosticStore.maximumRecords)
        #expect(retained.allSatisfy { !$0.record.message.contains("/Users/") })
        #expect(retained.allSatisfy { $0.record.message.contains("stackSymbols=omitted") })
    }
}
