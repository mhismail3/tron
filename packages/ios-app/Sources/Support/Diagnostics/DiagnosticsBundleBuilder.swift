import Foundation
import UIKit

struct DiagnosticsBundleAttachment: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let fileName: String
    let logSummary: DiagnosticsBundleLogSummary
}

struct DiagnosticsBundleLogSummary: Equatable, Sendable {
    let iosLogCount: Int
    let serverLogCount: Int
    let earliestLogTimestamp: Date?
    let latestLogTimestamp: Date?

    init(
        iosLogCount: Int,
        serverLogCount: Int,
        earliestLogTimestamp: Date?,
        latestLogTimestamp: Date?
    ) {
        self.iosLogCount = iosLogCount
        self.serverLogCount = serverLogCount
        self.earliestLogTimestamp = earliestLogTimestamp
        self.latestLogTimestamp = latestLogTimestamp
    }

    init(iosLogCount: Int, serverLogCount: Int, timestamps: [Date]) {
        self.iosLogCount = iosLogCount
        self.serverLogCount = serverLogCount
        self.earliestLogTimestamp = timestamps.min()
        self.latestLogTimestamp = timestamps.max()
    }
}

typealias DiagnosticsIOSLogsProvider = () -> [(Date, LogCategory, LogLevel, String)]

struct DiagnosticsServerLogRecord: Sendable {
    let id: String
    let timestamp: String
    let level: String
    let component: String
    let message: String
    let origin: String
    let sessionId: String?
    let errorMessage: String?
}

struct DiagnosticsEngineEndpoint {
    let isConnected: @MainActor () -> Bool
    let connectionStateName: @MainActor () -> String
    let currentSessionId: @MainActor () -> String?
    let recentServerLogs: @MainActor (_ limit: Int) async throws -> [DiagnosticsServerLogRecord]
}

@MainActor
struct DiagnosticsBundleBuilder {
    private static let maxIOSLogs = 1_000
    private static let maxServerLogs = 1_000
    private static let maxSessions = 12
    private static let maxEvents = 5_000
    private static let maxEventBytes = 5_000_000
    private static let redactionVersion = "diagnostics-redactor-v1"

    let eventDatabase: EventDatabase
    let eventStoreManager: EventStoreManager
    let engineEndpoint: DiagnosticsEngineEndpoint
    let activeServer: PairedServer?
    let metricKitStore: MetricKitDiagnosticsStore
    let now: () -> Date
    let iosLogsProvider: DiagnosticsIOSLogsProvider

    init(
        dependencies: DependencyContainer,
        metricKitStore: MetricKitDiagnosticsStore = .shared,
        now: @escaping () -> Date = { Date() },
        iosLogsProvider: DiagnosticsIOSLogsProvider? = nil
    ) {
        self.eventDatabase = dependencies.eventDatabase
        self.eventStoreManager = dependencies.eventStoreManager
        self.engineEndpoint = dependencies.diagnosticsEngineEndpoint
        self.activeServer = dependencies.pairedServerStore.activeServer
        self.metricKitStore = metricKitStore
        self.now = now
        self.iosLogsProvider = iosLogsProvider ?? {
            TronLogger.shared.getRecentLogs(count: Self.maxIOSLogs, level: nil, category: nil)
        }
    }

    init(
        eventDatabase: EventDatabase,
        eventStoreManager: EventStoreManager,
        engineEndpoint: DiagnosticsEngineEndpoint,
        activeServer: PairedServer?,
        metricKitStore: MetricKitDiagnosticsStore,
        now: @escaping () -> Date = { Date() },
        iosLogsProvider: DiagnosticsIOSLogsProvider? = nil
    ) {
        self.eventDatabase = eventDatabase
        self.eventStoreManager = eventStoreManager
        self.engineEndpoint = engineEndpoint
        self.activeServer = activeServer
        self.metricKitStore = metricKitStore
        self.now = now
        self.iosLogsProvider = iosLogsProvider ?? {
            TronLogger.shared.getRecentLogs(count: Self.maxIOSLogs, level: nil, category: nil)
        }
    }

    func build() async throws -> DiagnosticsBundleAttachment {
        let generatedAt = now()
        let redactor = DiagnosticsRedactor()
        let iosLogSnapshot = buildIOSLogs(redactor: redactor)
        let serverLogSnapshot = await buildServerLogs(redactor: redactor)
        let iosLogs = iosLogSnapshot.entries
        let serverLogs = serverLogSnapshot.entries
        let logSummary = DiagnosticsBundleLogSummary(
            iosLogCount: iosLogs.count,
            serverLogCount: serverLogs.count,
            timestamps: iosLogSnapshot.timestamps + serverLogSnapshot.timestamps
        )
        let sessions = await selectedSessions()
        let sessionSummaries = sessions.map(DiagnosticsSessionSummary.init(session:))
        let eventSnapshot = await buildEventSummaries(for: sessions, redactor: redactor)
        let metricKitSnapshot = (try? metricKitStore.loadPayloads(
            maxFiles: 50,
            maxBytes: 2_000_000
        )) ?? MetricKitDiagnosticsSnapshot(
            files: [],
            truncated: false,
            availableFileCount: 0,
            includedFileCount: 0,
            availableBytes: 0,
            includedBytes: 0
        )

        let bundle = DiagnosticsBundle(
            manifest: DiagnosticsBundleManifest(
                generatedAt: Self.isoFormatter.string(from: generatedAt),
                redactionVersion: Self.redactionVersion,
                counts: DiagnosticsBundleCounts(
                    iosLogEntries: iosLogs.count,
                    serverLogEntries: serverLogs.count,
                    sessions: sessionSummaries.count,
                    events: eventSnapshot.events.count,
                    metricKitPayloadFiles: metricKitSnapshot.includedFileCount
                ),
                truncated: DiagnosticsBundleTruncation(
                    iosLogs: iosLogs.count >= Self.maxIOSLogs,
                    serverLogs: serverLogs.count >= Self.maxServerLogs,
                    sessions: sessions.count >= Self.maxSessions,
                    events: eventSnapshot.truncated,
                    metricKitPayloads: metricKitSnapshot.truncated
                ),
                privacy: "No raw chat text, prompts, capability arguments, capability output, tokens, file paths, workspace paths, full IDs, or raw event payloads are included."
            ),
            environment: DiagnosticsEnvironment(
                generatedOnDevice: true,
                appVersion: VersionDisplay.label(for: AppConstants.canonicalVersion),
                buildNumber: AppConstants.buildNumber,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                platform: "iOS",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModelClass: UIDevice.current.model,
                connectionState: engineEndpoint.connectionStateName(),
                eventDatabaseStorageMode: eventDatabase.storageMode.rawValue,
                activeServer: DiagnosticsActiveServer(server: activeServer)
            ),
            logs: DiagnosticsLogs(ios: iosLogs, server: serverLogs),
            sessions: sessionSummaries,
            events: eventSnapshot.events,
            metricKit: metricKitSnapshot
        )

        let data = try Self.encoder.encode(bundle)
        return DiagnosticsBundleAttachment(
            data: data,
            mimeType: "application/json",
            fileName: "tron-diagnostics-\(Self.fileNameFormatter.string(from: generatedAt)).json",
            logSummary: logSummary
        )
    }

    private func buildIOSLogs(redactor: DiagnosticsRedactor) -> DiagnosticsIOSLogsResult {
        let includedEntries = Array(iosLogsProvider().sorted { $0.0 < $1.0 }.suffix(Self.maxIOSLogs))
        let logs = includedEntries.map { entry in
            DiagnosticsIOSLogEntry(
                timestamp: Self.isoFormatter.string(from: entry.0),
                category: entry.1.rawValue,
                level: Self.levelLabel(entry.2),
                message: redactor.redactMessage(entry.3)
            )
        }
        return DiagnosticsIOSLogsResult(
            entries: logs,
            timestamps: includedEntries.map(\.0)
        )
    }

    private func buildServerLogs(redactor: DiagnosticsRedactor) async -> DiagnosticsServerLogsResult {
        guard engineEndpoint.isConnected() else {
            return DiagnosticsServerLogsResult(entries: [], timestamps: [])
        }
        do {
            let includedEntries = try await engineEndpoint.recentServerLogs(Self.maxServerLogs)
            return DiagnosticsServerLogsResult(
                entries: includedEntries.map { entry in
                    DiagnosticsServerLogEntry(
                        idHash: DiagnosticsHash.hash(entry.id),
                        timestamp: entry.timestamp,
                        level: entry.level,
                        component: entry.component,
                        message: redactor.redactMessage(entry.message),
                        originHash: DiagnosticsHash.hash(entry.origin),
                        sessionIdHash: DiagnosticsHash.hash(entry.sessionId),
                        errorMessage: entry.errorMessage.map(redactor.redactMessage)
                    )
                },
                timestamps: includedEntries.compactMap { Self.parseLogTimestamp($0.timestamp) }
            )
        } catch {
            return DiagnosticsServerLogsResult(
                entries: [
                    DiagnosticsServerLogEntry(
                        idHash: nil,
                        timestamp: Self.isoFormatter.string(from: now()),
                        level: "warning",
                        component: "ios.diagnostics",
                        message: "logs::recent failed: \(redactor.redactMessage(error.localizedDescription))",
                        originHash: nil,
                        sessionIdHash: nil,
                        errorMessage: nil
                    )
                ],
                timestamps: []
            )
        }
    }

    private static func parseLogTimestamp(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? fractionalISOFormatter.date(from: value)
    }

    private struct DiagnosticsIOSLogsResult {
        let entries: [DiagnosticsIOSLogEntry]
        let timestamps: [Date]
    }

    private struct DiagnosticsServerLogsResult {
        let entries: [DiagnosticsServerLogEntry]
        let timestamps: [Date]
    }

    private static func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .verbose: return "verbose"
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        case .none: return "none"
        }
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    nonisolated(unsafe) private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private func selectedSessions() async -> [CachedSession] {
        let sessions = (try? await eventDatabase.sessions.getAll()) ?? eventStoreManager.sessions
        let activeId = eventStoreManager.activeSessionId ?? engineEndpoint.currentSessionId()
        var selected: [CachedSession] = []
        var seen: Set<String> = []

        if let activeId, let active = sessions.first(where: { $0.id == activeId }) {
            selected.append(active)
            seen.insert(active.id)
        }

        for session in sessions where selected.count < Self.maxSessions {
            guard !seen.contains(session.id) else { continue }
            selected.append(session)
            seen.insert(session.id)
        }

        return selected
    }

    private func buildEventSummaries(
        for sessions: [CachedSession],
        redactor: DiagnosticsRedactor
    ) async -> DiagnosticsEventSnapshot {
        var summaries: [DiagnosticsEventSummary] = []
        var estimatedBytes = 0
        var truncated = false

        sessionLoop: for session in sessions {
            let events = (try? await eventDatabase.events.getBySession(session.id)) ?? []
            for event in events {
                let summary = DiagnosticsEventSanitizer.summarize(event, redactor: redactor)
                let encodedSize = (try? Self.encoder.encode(summary))?.count ?? 0
                guard summaries.count < Self.maxEvents,
                      estimatedBytes + encodedSize <= Self.maxEventBytes
                else {
                    truncated = true
                    break sessionLoop
                }
                summaries.append(summary)
                estimatedBytes += encodedSize
            }
        }

        return DiagnosticsEventSnapshot(events: summaries, truncated: truncated)
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
