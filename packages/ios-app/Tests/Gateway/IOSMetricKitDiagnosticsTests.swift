import Foundation
import MetricKit
import Testing
@testable import TronMobile

struct IOSMetricKitDiagnosticsTests {
    private final class FakeManager: IOSMetricKitDiagnostics.Manager {
        var added: [MXMetricManagerSubscriber] = []
        var removed: [MXMetricManagerSubscriber] = []

        func add(_ subscriber: MXMetricManagerSubscriber) {
            added.append(subscriber)
        }

        func remove(_ subscriber: MXMetricManagerSubscriber) {
            removed.append(subscriber)
        }
    }

    @Test("MetricKit registration is app-lifetime and explicitly reversible")
    func registrationLifecycle() throws {
        let manager = FakeManager()
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

    @Test("MetricKit summaries use the bounded client diagnostic contract")
    func summaryRecordsAreRetainedByTheExistingStore() async throws {
        let suite = "TronMetricKit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = IOSClientDiagnosticStore(defaults: defaults)
        let value = GatewayProfileLogRecord(
            profileID: "ios-metrickit:ios-client",
            profileLabel: "iOS MetricKit",
            record: GatewayLogRecord(
                timestamp: GatewayTimestamp.preciseString(from: .now),
                level: "warning",
                message: "kind=diagnostic hang=1",
                event: "ios.metrickit",
                source: "ios-client"
            ),
            incidentID: "diagnostic-fixture"
        )
        store.record(value)
        await store.flush()
        let retained = await store.load()
        #expect(retained.contains { $0.record.event == "ios.metrickit" })
        #expect(retained.contains { $0.record.message == "kind=diagnostic hang=1" })
    }
}
