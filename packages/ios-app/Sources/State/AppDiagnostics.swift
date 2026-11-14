import Foundation
import TronMobileCore

@MainActor
final class AppDiagnostics {
    private let lifecycle: GatewayLifecycleCoordinator
    private let appLog: AppLog
    private let chatInteractionTrace: ChatInteractionTrace
    private let diagnosticStore: IOSClientDiagnosticStore?
    private var iosClientDiagnostics = IOSClientDiagnosticBuffer()
    private var eventConsumerDiagnostics: [String: GatewayEventConsumerDiagnostic] = [:]

    private var client: GatewayClient { lifecycle.client }
    private var profiles: GatewayProfileStore { lifecycle.profiles }
    init(
        lifecycle: GatewayLifecycleCoordinator,
        appLog: AppLog,
        chatInteractionTrace: ChatInteractionTrace,
        diagnosticStore: IOSClientDiagnosticStore?
    ) {
        self.lifecycle = lifecycle
        self.appLog = appLog
        self.chatInteractionTrace = chatInteractionTrace
        self.diagnosticStore = diagnosticStore
    }

    func restorePersistedRecords() {
        if let diagnosticStore {
            Task { @MainActor [weak self, diagnosticStore] in
                let records = await diagnosticStore.load()
                guard let self else { return }
                self.iosClientDiagnostics.mergePersisted(records)
            }
        }
    }

    func recordFailure(_ failure: GatewayFailure) {
        iosClientDiagnostics.record(failure, profileID: profiles.selected?.id, profileLabel: profiles.selected?.label)
        scheduleDiagnosticPersistence()
    }

    func flushPersistence() async {
        scheduleDiagnosticPersistence()
        await diagnosticStore?.flush()
    }

    func recordLifecycle(event: String, message: String) {
        let recordedEvents = ["reconnect.scheduled", "reconnect.attempt", "reconnect.failure", "reconnect.delay", "reconnect.connected", "reconnect.exhausted", "reconnect.stopped", "reconnect.parked", "reconnect.parked-resume", "reconnect.skipped", "path.changed", "detail.tap", "detail.preparation"]
        guard recordedEvents.contains(event) else { return }
        iosClientDiagnostics.recordLifecycle(
            event: "gateway.lifecycle",
            message: "kind=\(event) clientID=\(client.diagnosticOwnerID) \(message)",
            profileID: profiles.selected?.id,
            profileLabel: profiles.selected?.label
        )
        if let record = iosClientDiagnostics.records.first { diagnosticStore?.record(record) }
    }

    func recordCatalogDiagnostic(
        key: SessionCatalogLoadKey,
        trigger: String,
        outcome: String,
        requestGeneration: Int,
        durationMilliseconds: Int? = nil,
        code: String? = nil,
        reason: String? = nil,
        level: String = "info",
        incidentID: String? = nil,
        requestID: String? = nil,
        pageCount: Int? = nil,
        revision: Int? = nil,
        retryAttempt: Int? = nil
    ) {
        iosClientDiagnostics.recordCatalog(
            trigger: trigger,
            outcome: outcome,
            profileID: key.profileID,
            profileLabel: profiles.selected?.label,
            connectionID: key.connectionID,
            lifecycleGeneration: key.lifecycleGeneration,
            requestGeneration: requestGeneration,
            durationMilliseconds: durationMilliseconds,
            code: code,
            reason: reason,
            level: level,
            incidentID: incidentID,
            requestID: requestID,
            pageCount: pageCount,
            revision: revision,
            retryAttempt: retryAttempt,
            retryBudget: DashboardCatalogRetryPolicy.unavailableNoticeAfterFailures
        )
        if let record = iosClientDiagnostics.records.first { diagnosticStore?.record(record) }
    }

    func scheduleDiagnosticPersistence() {
        guard let diagnosticStore else { return }
        diagnosticStore.record(iosClientDiagnostics.records + eventConsumerDiagnostics.values.map(IOSClientDiagnosticBuffer.logRecord))
    }

    func recordEventConsumer(
        category: String,
        phase: GatewayEventConsumerPhase,
        duration: Duration
    ) {
        let key = "\(category):\(phase.rawValue)"
        guard eventConsumerDiagnostics[key] != nil || eventConsumerDiagnostics.count < 128 else { return }
        let observedAt = Date.now
        let prior: GatewayEventConsumerDiagnostic
        if let current = eventConsumerDiagnostics[key],
           (0..<60).contains(observedAt.timeIntervalSince(current.firstObservedAt)) {
            prior = current
        } else {
            if let completedWindow = eventConsumerDiagnostics[key] {
                diagnosticStore?.record(IOSClientDiagnosticBuffer.logRecord(completedWindow))
            }
            prior = GatewayEventConsumerDiagnostic(
                category: category, phase: phase, count: 0, slowCount: 0,
                maximumDuration: .zero, totalDuration: .zero,
                firstObservedAt: observedAt, lastObservedAt: observedAt
            )
        }
        let duration = max(.zero, duration)
        let slow = duration >= .milliseconds(100)
        let updated = GatewayEventConsumerDiagnostic(
            category: prior.category,
            phase: prior.phase,
            count: prior.count == Int.max ? Int.max : prior.count + 1,
            slowCount: prior.slowCount == Int.max ? Int.max : prior.slowCount + (slow ? 1 : 0),
            maximumDuration: max(prior.maximumDuration, duration),
            totalDuration: prior.totalDuration + duration,
            firstObservedAt: prior.firstObservedAt,
            lastObservedAt: observedAt
        )
        eventConsumerDiagnostics[key] = updated
        if slow, prior.slowCount == 0 { diagnosticStore?.record(IOSClientDiagnosticBuffer.logRecord(updated)) }
    }

    func offlineLogText() async -> String {
        var records = await appLog.snapshot()
        records += iosClientDiagnostics.records.map(Self.appLogRecord)
        records += (await client.diagnostics()).map(IOSClientDiagnosticBuffer.logRecord).map(Self.appLogRecord)
        records += eventConsumerDiagnostics.values.map(IOSClientDiagnosticBuffer.logRecord).map(Self.appLogRecord)
        records += chatInteractionTrace.diagnosticRecords(limit: Self.maximumOfflineLines).map(Self.appLogRecord)
        var kept: [String] = []
        var bytes = 0
        let encoder = JSONEncoder()
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }).suffix(Self.maximumOfflineLines).reversed() {
            guard let line = try? encoder.encode(record) else { continue }
            bytes += line.count + 1
            guard bytes <= Self.maximumOfflineBytes else { break }
            kept.append(String(decoding: line, as: UTF8.self))
        }
        return kept.reversed().joined(separator: "\n")
    }

    private static let maximumOfflineLines = 1_000
    private static let maximumOfflineBytes = 512 * 1_024

    private static func appLogRecord(_ value: GatewayProfileLogRecord) -> AppLogRecord {
        let record = value.record
        return AppLogRecord(
            timestamp: record.timestamp, level: record.level,
            event: IOSClientDiagnosticBuffer.redactedMessage(record.event ?? "incident"),
            source: IOSClientDiagnosticBuffer.redactedMessage(record.source ?? "incident"),
            message: IOSClientDiagnosticBuffer.redactedMessage(record.message), process: "ios",
            requestID: record.requestID.map(IOSClientDiagnosticBuffer.redactedMessage),
            durationMs: record.durationMs,
            outcome: record.outcome.map(IOSClientDiagnosticBuffer.redactedMessage),
            code: record.code.map(IOSClientDiagnosticBuffer.redactedMessage),
            profileID: value.profileID, connectionID: nil, lifecycleGeneration: nil
        )
    }
}
