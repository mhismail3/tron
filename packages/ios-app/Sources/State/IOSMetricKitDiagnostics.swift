import Foundation
import MetricKit

/// The local MetricKit adapter retains only bounded, typed summaries. Raw
/// payloads, symbols, paths, and call-stack text never enter the mailbox.
final class IOSMetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    protocol Manager: AnyObject {
        func add(_ subscriber: MXMetricManagerSubscriber)
        func remove(_ subscriber: MXMetricManagerSubscriber)
    }

    private final class SystemManager: Manager {
        func add(_ subscriber: MXMetricManagerSubscriber) { MXMetricManager.shared.add(subscriber) }
        func remove(_ subscriber: MXMetricManagerSubscriber) { MXMetricManager.shared.remove(subscriber) }
    }

    struct HistogramBucketProjection: Equatable, Sendable {
        let lower: Double
        let upper: Double
        let count: Int
    }

    private enum RegistrationState {
        case stopped
        case starting
        case registered
        case stopping
    }

    private let store: IOSClientDiagnosticStore
    private let manager: Manager
    private let lock = NSLock()
    private var registrationState = RegistrationState.stopped

    init(store: IOSClientDiagnosticStore, manager: Manager = SystemManager()) {
        self.store = store
        self.manager = manager
        super.init()
        start()
    }

    /// State is admitted before callbacks are accepted, while manager calls are
    /// made outside the lock. This handles synchronous test-manager callbacks,
    /// concurrent stop, and callbacks racing with remove without deadlocking.
    func start() {
        lock.lock()
        guard registrationState == .stopped else {
            lock.unlock()
            return
        }
        registrationState = .starting
        lock.unlock()

        manager.add(self)

        var removeAfterAdd = false
        lock.lock()
        if registrationState == .starting {
            registrationState = .registered
        } else if registrationState == .stopping {
            registrationState = .stopped
            removeAfterAdd = true
        }
        lock.unlock()
        if removeAfterAdd { manager.remove(self) }
    }

    func stop() {
        lock.lock()
        switch registrationState {
        case .stopped, .stopping:
            lock.unlock()
            return
        case .starting:
            // start() owns the in-flight add and will pair it with remove.
            registrationState = .stopping
            lock.unlock()
        case .registered:
            registrationState = .stopping
            lock.unlock()
            manager.remove(self)
            lock.lock()
            if registrationState == .stopping { registrationState = .stopped }
            lock.unlock()
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard acceptsCallback() else { return }
        let records = payloads.compactMap(Self.metricRecord)
        guard !records.isEmpty else { return }
        store.record(records)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard acceptsCallback() else { return }
        let records = payloads.compactMap(Self.diagnosticRecord)
        guard !records.isEmpty else { return }
        store.record(records)
    }

    private func acceptsCallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registrationState == .registered
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
            values.append("cpuSeconds=\(formattedMeasurement(cpu.cumulativeCPUTime, unit: .seconds))")
        }
        if let memory = payload.memoryMetrics {
            values.append("peakMemoryBytes=\(formattedMeasurement(memory.peakMemoryUsage, unit: .bytes))")
            values.append("suspendedMemoryBytes=\(formattedMeasurement(memory.averageSuspendedMemory.averageMeasurement, unit: .bytes))")
        }
        if let runtime = payload.applicationTimeMetrics {
            values.append("foregroundSeconds=\(formattedMeasurement(runtime.cumulativeForegroundTime, unit: .seconds))")
            values.append("backgroundSeconds=\(formattedMeasurement(runtime.cumulativeBackgroundTime, unit: .seconds))")
        }
        if let launch = payload.applicationLaunchMetrics {
            values.append(durationHistogram(launch.histogrammedTimeToFirstDraw, label: "launchLatency"))
            values.append(durationHistogram(launch.histogrammedApplicationResumeTime, label: "resumeLatency"))
            values.append(durationHistogram(launch.histogrammedExtendedLaunch, label: "extendedLaunchLatency"))
        }
        if let responsiveness = payload.applicationResponsivenessMetrics {
            values.append(durationHistogram(responsiveness.histogrammedApplicationHangTime, label: "hangLatency"))
        }
        if let disk = payload.diskIOMetrics {
            values.append("diskWriteBytes=\(formattedMeasurement(disk.cumulativeLogicalWrites, unit: .bytes))")
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
        var diagnostics: [MXDiagnostic] = []
        var trees: [MXCallStackTree] = []
        var values = [
            "kind=diagnostic",
            "intervalStart=\(GatewayTimestamp.preciseString(from: payload.timeStampBegin))",
            "intervalEnd=\(GatewayTimestamp.preciseString(from: payload.timeStampEnd))"
        ]
        var total = 0
        var level = "warning"

        if let crash = payload.crashDiagnostics, !crash.isEmpty {
            diagnostics.append(contentsOf: crash)
            trees.append(contentsOf: crash.map(\.callStackTree))
            total += crash.count
            level = "error"
            let first = crash[0]
            values.append("crash=\(crash.count)")
            values.append("exceptionType=\(first.exceptionType.map(String.init) ?? "unknown")")
            values.append("exceptionCode=\(first.exceptionCode.map(String.init) ?? "unknown")")
            values.append("signal=\(first.signal.map(String.init) ?? "unknown")")
            values.append("termination=\(safe(first.terminationReason))")
        }
        if let hang = payload.hangDiagnostics, !hang.isEmpty {
            diagnostics.append(contentsOf: hang)
            trees.append(contentsOf: hang.map(\.callStackTree))
            total += hang.count
            values.append("hang=\(hang.count)")
            values.append("hangSeconds=\(formattedNumber(hang.reduce(0) { $0 + $1.hangDuration.converted(to: .seconds).value }))")
        }
        if let launch = payload.appLaunchDiagnostics, !launch.isEmpty {
            diagnostics.append(contentsOf: launch)
            trees.append(contentsOf: launch.map(\.callStackTree))
            total += launch.count
            values.append("launch=\(launch.count)")
            values.append("launchSeconds=\(formattedNumber(launch.reduce(0) { $0 + $1.launchDuration.converted(to: .seconds).value }))")
        }
        if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty {
            diagnostics.append(contentsOf: cpu)
            trees.append(contentsOf: cpu.map(\.callStackTree))
            total += cpu.count
            level = "error"
            values.append("cpu=\(cpu.count)")
            values.append("cpuSeconds=\(formattedNumber(cpu.reduce(0) { $0 + $1.totalCPUTime.converted(to: .seconds).value }))")
            values.append("sampledSeconds=\(formattedNumber(cpu.reduce(0) { $0 + $1.totalSampledTime.converted(to: .seconds).value }))")
        }
        if let disk = payload.diskWriteExceptionDiagnostics, !disk.isEmpty {
            diagnostics.append(contentsOf: disk)
            trees.append(contentsOf: disk.map(\.callStackTree))
            total += disk.count
            values.append("disk=\(disk.count)")
            values.append("diskBytes=\(formattedNumber(disk.reduce(0) { $0 + $1.totalWritesCaused.converted(to: .bytes).value }))")
        }
        guard total > 0 else { return nil }

        values.append(diagnosticProvenance(diagnostics))
        values.append(callStackMetadata(trees))
        let end = payload.timeStampEnd
        return record(
            timestamp: end,
            level: level,
            message: values.joined(separator: " "),
            incidentID: "diagnostic-\(GatewayTimestamp.preciseString(from: end))"
        )
    }

    /// Testable conversion boundary used by the typed MetricKit extraction.
    static func formattedMeasurement<UnitType: Dimension>(
        _ measurement: Measurement<UnitType>,
        unit: UnitType
    ) -> String {
        formattedNumber(measurement.converted(to: unit).value)
    }

    /// Keeps only the first bounded buckets and preserves latency units/counts;
    /// this is not a bucket count pretending to be a latency measurement.
    static func formattedHistogram(label: String, buckets: [HistogramBucketProjection], omitted: Bool = false) -> String {
        let bounded = Array(buckets.prefix(8)).filter {
            $0.lower.isFinite && $0.lower >= 0 && $0.upper.isFinite && $0.upper >= $0.lower && $0.count >= 0
        }
        let encoded = bounded.map {
            "\(formattedNumber($0.lower))-\(formattedNumber($0.upper))ms:\($0.count)"
        }.joined(separator: ",")
        let omittedCount = omitted || buckets.count > bounded.count ? 1 : 0
        return "\(label)Buckets=\(encoded.isEmpty ? "none" : encoded) \(label)BucketsOmitted=\(omittedCount)"
    }

    private static func durationHistogram(_ histogram: MXHistogram<UnitDuration>, label: String) -> String {
        var buckets: [HistogramBucketProjection] = []
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            let lower = bucket.bucketStart.converted(to: .milliseconds).value
            let upper = bucket.bucketEnd.converted(to: .milliseconds).value
            buckets.append(HistogramBucketProjection(lower: lower, upper: upper, count: min(Int.max, bucket.bucketCount)))
            if buckets.count >= 64 { break }
        }
        return formattedHistogram(label: label, buckets: buckets, omitted: histogram.totalBucketCount > buckets.count)
    }

    private static func diagnosticProvenance(_ diagnostics: [MXDiagnostic]) -> String {
        var seen = Set<String>()
        var entries: [String] = []
        for diagnostic in diagnostics {
            let entry = diagnosticProvenanceEntry(
                applicationVersion: diagnostic.applicationVersion,
                build: diagnostic.metaData.applicationBuildVersion,
                os: diagnostic.metaData.osVersion
            )
            if seen.insert(entry).inserted { entries.append(entry) }
            if entries.count == 4 { break }
        }
        return "provenance=\(entries.isEmpty ? "unknown" : entries.joined(separator: ","))"
    }

    private static func callStackMetadata(_ trees: [MXCallStackTree]) -> String {
        var frames: [String] = []
        var omitted = false
        for tree in trees.prefix(8) {
            let projection = boundedCallStackProjection(tree)
            frames.append(contentsOf: projection.frames)
            omitted = omitted || projection.omitted
            if frames.count >= 16 { omitted = true; break }
        }
        let unique = Array(NSOrderedSet(array: frames)) as? [String] ?? frames
        return "stackFrames=\(unique.prefix(16).joined(separator: ",")) stackFramesOmitted=\(omitted ? 1 : 0) stackSymbols=omitted"
    }

    private static func boundedCallStackProjection(_ tree: MXCallStackTree) -> (frames: [String], omitted: Bool) {
        boundedCallStackProjection(tree.jsonRepresentation())
    }

    static func boundedCallStackMetadata(_ data: Data) -> String {
        let projection = boundedCallStackProjection(data)
        return "stackFrames=\(projection.frames.prefix(16).joined(separator: ",")) stackFramesOmitted=\(projection.omitted ? 1 : 0) stackSymbols=omitted"
    }

    private static func boundedCallStackProjection(_ data: Data) -> (frames: [String], omitted: Bool) {
        guard data.count <= 64 * 1024 else { return ([], true) }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return ([], true) }
        var pending: [(Any, Int)] = [(root, 0)]
        var frames: [String] = []
        var nodes = 0
        var omitted = false
        let childKeys = Set(["callStacks", "frames", "subFrames", "callStack", "children"])
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= 512, depth <= 16 else { omitted = true; break }
            if let dictionary = value as? [String: Any] {
                if let uuid = dictionary["binaryUUID"] as? String,
                   let offset = numeric((dictionary["offsetIntoBinaryTextSegment"] ?? dictionary["offset"]) as Any) {
                    let admittedUUID = uuid.range(of: "^[A-Fa-f0-9-]{8,64}$", options: .regularExpression) != nil
                    if admittedUUID, offset.isFinite, offset >= 0, offset < Double(UInt64.max) {
                        frames.append("\(uuid.uppercased()):0x\(String(UInt64(offset), radix: 16))")
                        if frames.count >= 16 { omitted = true; break }
                    }
                }
                for key in childKeys {
                    if let child = dictionary[key] {
                        pending.append((child, depth + 1))
                    }
                }
            } else if let array = value as? [Any] {
                for child in array.prefix(512) { pending.append((child, depth + 1)) }
                if array.count > 512 { omitted = true }
            }
        }
        return (frames, omitted)
    }

    private static func numeric(_ value: Any) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func diagnosticProvenanceEntry(applicationVersion: String, build: String, os: String) -> String {
        "app=\(safe(applicationVersion))_build=\(safe(build))_os=\(safe(os))"
    }

    private static func safe(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return IOSClientDiagnosticBuffer.redactedMessage(value).replacingOccurrences(of: " ", with: "_")
    }

    static func formattedNumber(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "unknown" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func record(timestamp: Date, level: String, message: String, incidentID: String) -> GatewayProfileLogRecord {
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
