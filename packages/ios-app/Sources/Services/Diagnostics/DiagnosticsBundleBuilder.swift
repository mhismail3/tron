import CryptoKit
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
    let engineClient: EngineClient
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
        self.engineClient = dependencies.engineClient
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
        engineClient: EngineClient,
        activeServer: PairedServer?,
        metricKitStore: MetricKitDiagnosticsStore,
        now: @escaping () -> Date = { Date() },
        iosLogsProvider: DiagnosticsIOSLogsProvider? = nil
    ) {
        self.eventDatabase = eventDatabase
        self.eventStoreManager = eventStoreManager
        self.engineClient = engineClient
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
                connectionState: Self.connectionStateName(engineClient.connectionState),
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
        guard engineClient.connectionState.isConnected else {
            return DiagnosticsServerLogsResult(entries: [], timestamps: [])
        }
        do {
            let result = try await engineClient.misc.recentLogs(limit: Self.maxServerLogs)
            let includedEntries = Array(result.entries.prefix(Self.maxServerLogs))
            return DiagnosticsServerLogsResult(
                entries: includedEntries.map { entry in
                    DiagnosticsServerLogEntry(
                        idHash: DiagnosticsHash.hash(String(entry.id)),
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

    private static func connectionStateName(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .deployRestarting: return "deploy_restarting"
        case .failed: return "failed"
        case .unauthorized: return "unauthorized"
        }
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
        let activeId = eventStoreManager.activeSessionId ?? engineClient.currentSessionId
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

struct DiagnosticsBundle: Encodable, Sendable {
    let manifest: DiagnosticsBundleManifest
    let environment: DiagnosticsEnvironment
    let logs: DiagnosticsLogs
    let sessions: [DiagnosticsSessionSummary]
    let events: [DiagnosticsEventSummary]
    let metricKit: MetricKitDiagnosticsSnapshot
}

struct DiagnosticsBundleManifest: Encodable, Sendable {
    let generatedAt: String
    let redactionVersion: String
    let counts: DiagnosticsBundleCounts
    let truncated: DiagnosticsBundleTruncation
    let privacy: String
}

struct DiagnosticsBundleCounts: Encodable, Sendable {
    let iosLogEntries: Int
    let serverLogEntries: Int
    let sessions: Int
    let events: Int
    let metricKitPayloadFiles: Int
}

struct DiagnosticsBundleTruncation: Encodable, Sendable {
    let iosLogs: Bool
    let serverLogs: Bool
    let sessions: Bool
    let events: Bool
    let metricKitPayloads: Bool
}

struct DiagnosticsEnvironment: Encodable, Sendable {
    let generatedOnDevice: Bool
    let appVersion: String
    let buildNumber: String
    let bundleIdentifier: String?
    let platform: String
    let osVersion: String
    let deviceModelClass: String
    let connectionState: String
    let activeServer: DiagnosticsActiveServer?
}

struct DiagnosticsActiveServer: Encodable, Sendable {
    let idHash: String?
    let labelHash: String?
    let originHash: String?
    let originClass: String
    let port: Int
    let lastKnownVersion: String?
    let lastKnownStatus: String?

    init?(server: PairedServer?) {
        guard let server else { return nil }
        idHash = DiagnosticsHash.hash(server.id)
        labelHash = DiagnosticsHash.hash(server.label)
        originHash = DiagnosticsHash.hash(server.origin)
        originClass = DiagnosticsHostClassifier.classify(server.host)
        port = server.port
        lastKnownVersion = server.lastKnownVersion
        lastKnownStatus = server.lastKnownStatus
    }
}

struct DiagnosticsLogs: Encodable, Sendable {
    let ios: [DiagnosticsIOSLogEntry]
    let server: [DiagnosticsServerLogEntry]
}

struct DiagnosticsIOSLogEntry: Encodable, Sendable {
    let timestamp: String
    let category: String
    let level: String
    let message: String
}

struct DiagnosticsServerLogEntry: Encodable, Sendable {
    let idHash: String?
    let timestamp: String
    let level: String
    let component: String
    let message: String
    let originHash: String?
    let sessionIdHash: String?
    let errorMessage: String?
}

struct DiagnosticsSessionSummary: Encodable, Sendable {
    let idHash: String?
    let workspaceIdHash: String?
    let rootEventIdHash: String?
    let headEventIdHash: String?
    let latestModel: String
    let createdAt: String
    let lastActivityAt: String
    let archived: Bool
    let eventCount: Int
    let messageCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cost: Double
    let isFork: Bool?
    let source: String?
    let serverOriginHash: String?

    init(session: CachedSession) {
        idHash = DiagnosticsHash.hash(session.id)
        workspaceIdHash = DiagnosticsHash.hash(session.workspaceId)
        rootEventIdHash = DiagnosticsHash.hash(session.rootEventId)
        headEventIdHash = DiagnosticsHash.hash(session.headEventId)
        latestModel = session.latestModel
        createdAt = session.createdAt
        lastActivityAt = session.lastActivityAt
        archived = session.isArchived
        eventCount = session.eventCount
        messageCount = session.messageCount
        inputTokens = session.inputTokens
        outputTokens = session.outputTokens
        cacheReadTokens = session.cacheReadTokens
        cacheCreationTokens = session.cacheCreationTokens
        cost = session.cost
        isFork = session.isFork
        source = session.source
        serverOriginHash = DiagnosticsHash.hash(session.serverOrigin)
    }
}

struct DiagnosticsEventSnapshot: Sendable {
    let events: [DiagnosticsEventSummary]
    let truncated: Bool
}

struct DiagnosticsEventSummary: Encodable, Sendable {
    let idHash: String?
    let parentIdHash: String?
    let sessionIdHash: String?
    let workspaceIdHash: String?
    let type: String
    let timestamp: String
    let sequence: Int
    let payload: [String: AnyCodable]
}

enum DiagnosticsEventSanitizer {
    private static let allowedScalarKeys: Set<String> = [
        "action",
        "attempt",
        "cacheCreationTokens",
        "cacheReadTokens",
        "code",
        "component",
        "contextWindowTokens",
        "cost",
        "durationMs",
        "errorClass",
        "exitCode",
        "inputTokens",
        "isError",
        "messageCount",
        "model",
        "outputTokens",
        "provider",
        "providerType",
        "source",
        "status",
        "stopReason",
        "modelPrimitiveName",
        "totalCost",
        "turn",
        "useWorktree",
    ]

    private static let redactedErrorKeys: Set<String> = [
        "error",
        "errorMessage",
        "message",
    ]

    static func summarize(
        _ event: SessionEvent,
        redactor: DiagnosticsRedactor = DiagnosticsRedactor()
    ) -> DiagnosticsEventSummary {
        DiagnosticsEventSummary(
            idHash: DiagnosticsHash.hash(event.id),
            parentIdHash: DiagnosticsHash.hash(event.parentId),
            sessionIdHash: DiagnosticsHash.hash(event.sessionId),
            workspaceIdHash: DiagnosticsHash.hash(event.workspaceId),
            type: event.type,
            timestamp: event.timestamp,
            sequence: event.sequence,
            payload: safePayload(from: event, redactor: redactor)
        )
    }

    static func safePayload(
        from event: SessionEvent,
        redactor: DiagnosticsRedactor = DiagnosticsRedactor()
    ) -> [String: AnyCodable] {
        var safe: [String: AnyCodable] = [:]
        let isErrorEvent = event.type.contains("error") || event.type.contains("failed")

        for (key, value) in event.payload {
            if allowedScalarKeys.contains(key), let scalar = scalarValue(value.value) {
                safe[key] = AnyCodable(scalar)
                continue
            }

            guard isErrorEvent, redactedErrorKeys.contains(key), let message = value.stringValue else {
                continue
            }

            let redacted = redactor.redactMessage(message)
            safe[key] = AnyCodable(String(redacted.prefix(240)))
        }

        return safe
    }

    private static func scalarValue(_ value: Any) -> Any? {
        switch value {
        case let string as String:
            return String(string.prefix(160))
        case let int as Int:
            return int
        case let double as Double where double.isFinite:
            return double
        case let bool as Bool:
            return bool
        default:
            return nil
        }
    }
}

enum DiagnosticsHash {
    static func hash(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

enum DiagnosticsHostClassifier {
    static func classify(_ host: String) -> String {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1" {
            return "loopback"
        }
        if let ipv4 = ipv4Octets(lowered) {
            if ipv4[0] == 10
                || (ipv4[0] == 172 && (16...31).contains(ipv4[1]))
                || (ipv4[0] == 192 && ipv4[1] == 168) {
                return "private_ipv4"
            }
            if ipv4[0] == 100 && (64...127).contains(ipv4[1]) {
                return "tailscale_ipv4"
            }
            return "public_ipv4"
        }
        if lowered.contains(":") {
            return "ipv6_or_hostname"
        }
        return "hostname"
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let pieces = host.split(separator: ".")
        guard pieces.count == 4 else { return nil }
        let octets = pieces.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
