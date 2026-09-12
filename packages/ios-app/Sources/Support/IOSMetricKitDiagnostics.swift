import Foundation
import MetricKit

/// The small, local MetricKit adapter. It keeps only bounded summaries of
/// system reports; raw MetricKit payloads never enter the diagnostic mailbox or
/// the user-visible log export.
final class IOSMetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    protocol Manager: AnyObject {
        func add(_ subscriber: MXMetricManagerSubscriber)
        func remove(_ subscriber: MXMetricManagerSubscriber)
    }

    private final class SystemManager: Manager {
        func add(_ subscriber: MXMetricManagerSubscriber) {
            MXMetricManager.shared.add(subscriber)
        }

        func remove(_ subscriber: MXMetricManagerSubscriber) {
            MXMetricManager.shared.remove(subscriber)
        }
    }

    private let store: IOSClientDiagnosticStore
    private let manager: Manager
    private let lock = NSLock()
    private var isRegistered = false

    init(store: IOSClientDiagnosticStore, manager: Manager = SystemManager()) {
        self.store = store
        self.manager = manager
        super.init()
        start()
    }

    /// Registration is explicit so tests and a future owner can retire the
    /// subscriber without changing MetricKit collection semantics.
    func start() {
        lock.lock()
        guard !isRegistered else {
            lock.unlock()
            return
        }
        isRegistered = true
        lock.unlock()
        manager.add(self)
    }

    func stop() {
        lock.lock()
        guard isRegistered else {
            lock.unlock()
            return
        }
        isRegistered = false
        lock.unlock()
        manager.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let records = payloads.compactMap(Self.metricRecord)
        guard !records.isEmpty else { return }
        store.record(records)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let records = payloads.compactMap(Self.diagnosticRecord)
        guard !records.isEmpty else { return }
        store.record(records)
    }

    static func metricRecord(_ payload: MXMetricPayload) -> GatewayProfileLogRecord? {
        let groups = metricGroupNames(payload.dictionaryRepresentation())
        let begin = GatewayTimestamp.preciseString(from: payload.timeStampBegin)
        let end = GatewayTimestamp.preciseString(from: payload.timeStampEnd)
        let groupSummary = groups.isEmpty ? "none" : groups.joined(separator: ",")
        let message = "kind=daily intervalStart=\(begin) intervalEnd=\(end) groups=\(groupSummary)"
        return record(
            timestamp: payload.timeStampEnd,
            level: "info",
            message: message,
            incidentID: "metric-\(begin)-\(end)"
        )
    }

    static func diagnosticRecord(_ payload: MXDiagnosticPayload) -> GatewayProfileLogRecord? {
        let crash = payload.crashDiagnostics?.count ?? 0
        let hang = payload.hangDiagnostics?.count ?? 0
        let launch = payload.appLaunchDiagnostics?.count ?? 0
        let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
        let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
        let total = crash + hang + launch + cpu + disk
        guard total > 0 else { return nil }
        let level = crash > 0 || cpu > 0 ? "error" : "warning"
        let categories = [
            ("crash", crash), ("hang", hang), ("launch", launch),
            ("cpu", cpu), ("disk", disk)
        ].compactMap { $0.1 > 0 ? "\($0.0)=\($0.1)" : nil }
        let end = payload.timeStampEnd
        return record(
            timestamp: end,
            level: level,
            message: "kind=diagnostic \(categories.joined(separator: " "))",
            incidentID: "diagnostic-\(GatewayTimestamp.preciseString(from: end))"
        )
    }

    private static func metricGroupNames(_ dictionary: [AnyHashable: Any]) -> [String] {
        let known = Set([
            "applicationLaunchMetrics", "applicationResponsivenessMetrics", "cpuMetrics",
            "diskIOMetrics", "memoryMetrics", "networkTransferMetrics", "displayMetrics",
            "gpuMetrics", "applicationTimeMetrics", "cellularConditionMetrics"
        ])
        return dictionary.keys
            .compactMap { $0 as? String }
            .filter { known.contains($0) }
            .sorted()
    }

    private static func record(
        timestamp: Date,
        level: String,
        message: String,
        incidentID: String
    ) -> GatewayProfileLogRecord {
        GatewayProfileLogRecord(
            profileID: "ios-metrickit:ios-client",
            profileLabel: "iOS MetricKit",
            record: GatewayLogRecord(
                timestamp: GatewayTimestamp.preciseString(from: timestamp),
                level: level,
                message: message,
                event: "ios.metrickit",
                source: "ios-client"
            ),
            incidentID: incidentID
        )
    }

    deinit { stop() }
}
