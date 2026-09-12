import Foundation
import MetricKit

/// The small, local MetricKit adapter. It keeps bounded, typed summaries of
/// system reports; raw MetricKit payloads and call stacks never enter the
/// diagnostic mailbox or the user-visible log export.
final class IOSMetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    protocol Manager: AnyObject {
        func add(_ subscriber: MXMetricManagerSubscriber)
        func remove(_ subscriber: MXMetricManagerSubscriber)
    }

    private final class SystemManager: Manager {
        func add(_ subscriber: MXMetricManagerSubscriber) { MXMetricManager.shared.add(subscriber) }
        func remove(_ subscriber: MXMetricManagerSubscriber) { MXMetricManager.shared.remove(subscriber) }
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

    /// Registration is explicit so tests and the owning app can retire the
    /// subscriber without changing MetricKit collection semantics.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRegistered else { return }
        // Serialize the manager call with retirement. MetricKit can deliver a
        // callback as registration changes, so publishing the state only after
        // add/remove completes avoids a late callback observing a retired owner.
        manager.add(self)
        isRegistered = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRegistered else { return }
        manager.remove(self)
        isRegistered = false
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
        var values: [String] = [
            "kind=daily",
            "intervalStart=\(GatewayTimestamp.preciseString(from: payload.timeStampBegin))",
            "intervalEnd=\(GatewayTimestamp.preciseString(from: payload.timeStampEnd))",
            "build=\(safe(payload.metaData?.applicationBuildVersion))",
            "appVersion=\(safe(payload.latestApplicationVersion))"
        ]
        if let cpu = payload.cpuMetrics {
            values.append("cpuSeconds=\(number(cpu.cumulativeCPUTime.converted(to: .seconds).value))")
        }
        if let memory = payload.memoryMetrics {
            values.append("peakMemoryBytes=\(number(memory.peakMemoryUsage.converted(to: .bytes).value))")
            values.append("suspendedMemoryBytes=\(number(memory.averageSuspendedMemory.averageMeasurement.converted(to: .bytes).value))")
        }
        if let runtime = payload.applicationTimeMetrics {
            values.append("foregroundSeconds=\(number(runtime.cumulativeForegroundTime.converted(to: .seconds).value))")
            values.append("backgroundSeconds=\(number(runtime.cumulativeBackgroundTime.converted(to: .seconds).value))")
        }
        if let launch = payload.applicationLaunchMetrics {
            values.append("launchBuckets=\(launch.histogrammedTimeToFirstDraw.totalBucketCount)")
            values.append("resumeBuckets=\(launch.histogrammedApplicationResumeTime.totalBucketCount)")
            values.append("extendedLaunchBuckets=\(launch.histogrammedExtendedLaunch.totalBucketCount)")
        }
        if let responsiveness = payload.applicationResponsivenessMetrics {
            values.append("hangBuckets=\(responsiveness.histogrammedApplicationHangTime.totalBucketCount)")
        }
        if let disk = payload.diskIOMetrics {
            values.append("diskWriteBuckets=\(disk.cumulativeLogicalWrites.converted(to: .bytes).value)")
        }
        let begin = GatewayTimestamp.preciseString(from: payload.timeStampBegin)
        let end = GatewayTimestamp.preciseString(from: payload.timeStampEnd)
        return record(
            timestamp: payload.timeStampEnd,
            level: "info",
            message: values.joined(separator: " "),
            incidentID: "metric-\(begin)-\(end)"
        )
    }

    static func diagnosticRecord(_ payload: MXDiagnosticPayload) -> GatewayProfileLogRecord? {
        let provenance = [
            "build=\(safe(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String))",
            "bundle=\(safe(Bundle.main.bundleIdentifier))",
            "os=\(safe(ProcessInfo.processInfo.operatingSystemVersionString))"
        ].joined(separator: " ")
        var values = ["kind=diagnostic", provenance]
        var total = 0
        var level = "warning"
        if let crash = payload.crashDiagnostics, !crash.isEmpty {
            total += crash.count
            level = "error"
            let first = crash[0]
            values.append("crash=\(crash.count)")
            if let value = first.exceptionType { values.append("exceptionType=\(value)") }
            if let value = first.exceptionCode { values.append("exceptionCode=\(value)") }
            if let value = first.signal { values.append("signal=\(value)") }
            if let value = first.terminationReason { values.append("termination=\(safe(value))") }
            values.append("callstack=present")
        }
        if let hang = payload.hangDiagnostics, !hang.isEmpty {
            total += hang.count
            values.append("hang=\(hang.count)")
            values.append("hangSeconds=\(number(hang.reduce(0) { $0 + $1.hangDuration.converted(to: .seconds).value }))")
            values.append("callstack=present")
        }
        if let launch = payload.appLaunchDiagnostics, !launch.isEmpty {
            total += launch.count
            values.append("launch=\(launch.count)")
        }
        if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty {
            total += cpu.count
            level = "error"
            values.append("cpu=\(cpu.count)")
            values.append("cpuSeconds=\(number(cpu.reduce(0) { $0 + $1.totalCPUTime.converted(to: .seconds).value }))")
            values.append("sampledSeconds=\(number(cpu.reduce(0) { $0 + $1.totalSampledTime.converted(to: .seconds).value }))")
            values.append("callstack=present")
        }
        if let disk = payload.diskWriteExceptionDiagnostics, !disk.isEmpty {
            total += disk.count
            values.append("disk=\(disk.count)")
            values.append("diskBytes=\(number(disk.reduce(0) { $0 + $1.totalWritesCaused.converted(to: .bytes).value }))")
            values.append("callstack=present")
        }
        guard total > 0 else { return nil }
        let end = payload.timeStampEnd
        return record(
            timestamp: end,
            level: level,
            message: values.joined(separator: " "),
            incidentID: "diagnostic-\(GatewayTimestamp.preciseString(from: end))"
        )
    }

    private static func safe(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return IOSClientDiagnosticBuffer.redactedMessage(value)
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "unknown" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
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
                message: IOSClientDiagnosticBuffer.redactedMessage(message),
                event: "ios.metrickit",
                source: "ios-client"
            ),
            incidentID: incidentID
        )
    }

    deinit { stop() }
}
