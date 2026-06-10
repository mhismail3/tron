import CryptoKit
import Foundation

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
    let workspaceIdHash: String?
    let traceIdHash: String?
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
