import Foundation
import TronMobileCore

enum DiagnosticExportResult {
    case saved(String)
    case share(URL)
}

private struct DiagnosticExportRequest: Encodable {
    let commandId: String
    let content: String
}

private struct DiagnosticExportResponse: Decodable {
    let path: String
    let exportedAt: String
}

@MainActor
final class AppDiagnostics {
    private let lifecycle: GatewayLifecycleCoordinator
    private let dashboardConnections: DashboardGatewayConnectionPool
    private let gatewayDiagnostics: GatewayDiagnosticsService
    private let appLog: AppLog
    private let exportArtifacts: SessionExportArtifactStore
    private let chatInteractionTrace: ChatInteractionTrace
    private let diagnosticStore: IOSClientDiagnosticStore?
    private var iosClientDiagnostics = IOSClientDiagnosticBuffer()
    private var eventConsumerDiagnostics: [String: GatewayEventConsumerDiagnostic] = [:]

    private var client: GatewayClient { lifecycle.client }
    private var profiles: GatewayProfileStore { lifecycle.profiles }
    init(
        lifecycle: GatewayLifecycleCoordinator,
        dashboardConnections: DashboardGatewayConnectionPool,
        gatewayDiagnostics: GatewayDiagnosticsService,
        appLog: AppLog,
        exportArtifacts: SessionExportArtifactStore,
        chatInteractionTrace: ChatInteractionTrace,
        diagnosticStore: IOSClientDiagnosticStore?
    ) {
        self.lifecycle = lifecycle
        self.dashboardConnections = dashboardConnections
        self.gatewayDiagnostics = gatewayDiagnostics
        self.appLog = appLog
        self.exportArtifacts = exportArtifacts
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

    private func gatewayLogs(for profileID: String, limit: Int = 1_000) async throws -> [GatewayLogRecord] {
        guard limit >= 0 else { throw GatewayFailure(code: "invalid_request", message: "Log limit is invalid.", retryable: false, details: nil) }
        if profiles.selected?.id == profileID {
            return try await gatewayDiagnostics.logs(limit: limit)
        }
        guard let diagnostics = dashboardConnections.diagnostics(for: profileID) else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await diagnostics.logs(limit: limit)
    }

    func loadGatewayLogsResult(
        limit: Int,
        includeRemote: Bool,
        diagnosticsAreReady: () -> Bool
    ) async -> GatewayLogsLoadResult {
        let limit = min(1_000, max(0, limit))
        let profileSnapshot = profiles.profiles
        var sourceStatuses = Dictionary(uniqueKeysWithValues: profileSnapshot.map { ($0.id, "pending") })
        sourceStatuses[GatewayLogExport.appLogProfileID] = "current-and-retained-local"
        var loaded = Array(iosClientDiagnostics.records.prefix(limit))
        loaded.append(contentsOf: await appLog.snapshot().map { value in
            GatewayProfileLogRecord(profileID: GatewayLogExport.appLogProfileID, profileLabel: "This iPhone", record: GatewayLogRecord(
                timestamp: value.timestamp, level: value.level, message: value.message,
                event: value.event, source: value.source, requestID: value.requestID,
                code: value.code, outcome: value.outcome, durationMs: value.durationMs
            ))
        })
        loaded.append(contentsOf: (await client.diagnostics()).map(IOSClientDiagnosticBuffer.logRecord))
        loaded.append(contentsOf: eventConsumerDiagnostics.values.map {
            IOSClientDiagnosticBuffer.logRecord($0)
        })
        loaded.append(contentsOf: chatInteractionTrace.diagnosticRecords(limit: limit))
        guard includeRemote, diagnosticsAreReady() else {
            for profile in profileSnapshot { sourceStatuses[profile.id] = "not-requested-retained" }
            return GatewayLogsLoadResult(
                records: Array(loaded.sorted { gatewayLogRecordIsNewer($0, than: $1) }.prefix(limit)),
                failedProfileIDs: Set(profileSnapshot.map(\.id)),
                metadata: logCaptureMetadata(records: loaded, sourceStatuses: sourceStatuses)
            )
        }
        var failedProfileIDs: Set<String> = []
        for profile in profileSnapshot {
            do {
                let records = try await gatewayLogs(for: profile.id, limit: limit)
                loaded.append(contentsOf: records.map {
                    GatewayProfileLogRecord(profileID: profile.id, profileLabel: profile.label, record: $0)
                })
                sourceStatuses[profile.id] = "fresh-remote"
            } catch is CancellationError {
                return GatewayLogsLoadResult(
                    records: Array(loaded.sorted { gatewayLogRecordIsNewer($0, than: $1) }.prefix(limit)),
                    failedProfileIDs: failedProfileIDs,
                    metadata: logCaptureMetadata(records: loaded, sourceStatuses: sourceStatuses)
                )
            } catch {
                failedProfileIDs.insert(profile.id)
                sourceStatuses[profile.id] = "failed-retained"
            }
        }
        return GatewayLogsLoadResult(
            records: Array(loaded.sorted { gatewayLogRecordIsNewer($0, than: $1) }.prefix(limit)),
            failedProfileIDs: failedProfileIDs,
            metadata: logCaptureMetadata(records: loaded, sourceStatuses: sourceStatuses)
        )
    }

    func exportDiagnostics(
        _ text: String,
        destination: KnowledgeDestinationIdentity,
        diagnosticsAreReady: () -> Bool,
        currentDestination: () -> KnowledgeDestinationIdentity
    ) async throws -> DiagnosticExportResult {
        guard currentDestination() == destination else { throw CancellationError() }
        if diagnosticsAreReady(), lifecycle.gatewayInfo?.capabilities.contains("diagnostic-export.v1") == true,
           let connectionID = lifecycle.connectionID {
            do {
                let value: JSONValue = try await client.requestValue(
                    "system.logs.export",
                    DiagnosticExportRequest(commandId: UUID().uuidString, content: text),
                    expectedEpochID: connectionID
                )
                let result = try JSONDecoder().decode(DiagnosticExportResponse.self, from: JSONEncoder().encode(value))
                return .saved(result.path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await appLog.recordCausal(
                    name: "diagnostics.upload-failed", outcome: "failure", level: "warning",
                    details: "code=\(GatewayDiagnosticFailure.code(error))"
                )
            }
        }
        guard currentDestination() == destination else { throw CancellationError() }
        return .share(try await exportLocalDiagnosticArtifact(text, suggestedName: "tron-diagnostics.jsonl"))
    }

    func writeLocalDiagnosticArtifact(_ text: String) async throws -> URL {
        try await exportLocalDiagnosticArtifact(text, suggestedName: "tron-iphone-diagnostics.jsonl")
    }

    private func exportLocalDiagnosticArtifact(_ text: String, suggestedName: String) async throws -> URL {
        try await exportArtifacts.writeText(text, suggestedName: suggestedName)
    }

    private func logCaptureMetadata(
        records: [GatewayProfileLogRecord],
        sourceStatuses: [String: String]
    ) -> GatewayLogCaptureMetadata {
        let timestamps = records.compactMap { GatewayTimestamp.parse($0.record.timestamp) }.sorted()
        let build = [
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        ].compactMap { $0 }.joined(separator: "+")
        return GatewayLogCaptureMetadata(
            capturedAt: GatewayTimestamp.preciseString(from: .now),
            representedFrom: timestamps.first.map(GatewayTimestamp.preciseString(from:)),
            representedThrough: timestamps.last.map(GatewayTimestamp.preciseString(from:)),
            appBuildIdentity: build.isEmpty ? "unknown" : build,
            gatewayIdentities: Dictionary(uniqueKeysWithValues: profiles.profiles.map { profile in
                let info = profile.id == profiles.selected?.id ? lifecycle.gatewayInfo : dashboardConnections.infoSnapshot(for: profile.id)
                return (profile.id, info.map {
                    "version=\($0.gatewayVersion) channel=\($0.gatewayChannel) runtime=\($0.runtimeEpoch ?? "unknown") sourceRevision=\($0.sourceRevision ?? "unknown")"
                } ?? "unknown")
            }),
            sourceStatuses: sourceStatuses,
            appSourceRevision: IOSBuildIdentity.sourceRevision()
        )
    }
}
