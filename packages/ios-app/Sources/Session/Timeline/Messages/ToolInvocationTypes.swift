import Foundation
import SwiftUI

// MARK: - Tool Invocation Data

struct ToolInvocationData: Equatable, Identifiable {
    let id: String
    var status: ToolInvocationStatus
    var arguments: String
    var payloadJSON: [String: AnyCodable]?
    var result: String?
    var details: [String: AnyCodable]?
    var progressMessage: String?
    var progressPercent: Double?
    var durationMs: Int?
    var generatedAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var identity: ToolIdentity
    var artifacts: [ToolArtifactData]
    var logs: [String]
    var errorClassification: ToolErrorClassification?

    init(
        id: String,
        status: ToolInvocationStatus,
        arguments: String = "",
        payloadJSON: [String: AnyCodable]? = nil,
        result: String? = nil,
        details: [String: AnyCodable]? = nil,
        progressMessage: String? = nil,
        progressPercent: Double? = nil,
        durationMs: Int? = nil,
        generatedAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        identity: ToolIdentity,
        artifacts: [ToolArtifactData] = [],
        logs: [String] = [],
        errorClassification: ToolErrorClassification? = nil
    ) {
        self.id = id
        self.status = status
        self.arguments = arguments
        self.payloadJSON = payloadJSON
        self.result = result
        self.details = details
        self.progressMessage = progressMessage
        self.progressPercent = progressPercent
        self.durationMs = durationMs
        self.generatedAt = generatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.identity = identity
        self.artifacts = artifacts
        self.logs = logs
        self.errorClassification = errorClassification
    }

    var displayName: String {
        display.primitiveTitle
    }

    var subtitle: String {
        display.commandText
    }

    var formattedDuration: String? {
        guard let ms = displayDurationMs else { return nil }
        return Self.formatDuration(ms)
    }

    var serverFormattedDuration: String? {
        guard let ms = durationMs else { return nil }
        return Self.formatDuration(ms)
    }

    var displayDurationMs: Int? {
        let observed = observedDurationMs
        switch (durationMs, observed) {
        case let (server?, observed?):
            return max(server, observed)
        case let (server?, nil):
            return server
        case let (nil, observed?):
            return observed
        case (nil, nil):
            return nil
        }
    }

    var observedDurationMs: Int? {
        let anchor = startedAt ?? generatedAt
        guard let anchor, let completedAt else { return nil }
        return max(0, Int((completedAt.timeIntervalSince(anchor) * 1000).rounded()))
    }

    func formattedElapsed(at date: Date = Date()) -> String? {
        let anchor = startedAt ?? generatedAt
        guard let anchor else { return formattedDuration }
        let elapsed = max(0, Int(date.timeIntervalSince(anchor) * 1000))
        return Self.formatDuration(elapsed)
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    var truncatedArguments: String {
        arguments.truncated(to: 203)
    }

    var display: ToolInvocationDisplayModel {
        ToolInvocationDisplayModel(data: self)
    }
}

enum ToolInvocationStatus: Equatable, Sendable {
    case generating
    case running
    case success
    case error
    case unavailable

    var iconName: String {
        switch self {
        case .generating, .running:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.circle.fill"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct ToolInvocationResultData: Equatable {
    let id: String
    let content: String
    let isError: Bool
    let identity: ToolIdentity
    let arguments: String?
    let durationMs: Int?
    let details: [String: AnyCodable]?

    var truncatedContent: String {
        content.truncated(to: 503)
    }
}

struct ToolArtifactData: Equatable, Sendable {
    var id: String
    var label: String?
    var mimeType: String?
    var url: String?
}

struct ToolErrorClassification: Equatable, Sendable {
    var code: String?
    var category: String?
    var message: String?
    var recoverable: Bool?

    init(
        code: String? = nil,
        category: String? = nil,
        message: String? = nil,
        recoverable: Bool? = nil
    ) {
        self.code = code
        self.category = category
        self.message = message
        self.recoverable = recoverable
    }

    init(failure: CanonicalFailurePayload) {
        self.init(
            code: failure.code,
            category: failure.category,
            message: failure.message,
            recoverable: failure.recoverable
        )
    }
}

extension ToolIdentity {
    init(payload: [String: Any]) {
        self.init(
            toolName: payload["toolName"] as? String,
            traceId: payload["traceId"] as? String,
            rootInvocationId: payload["rootInvocationId"] as? String,
            themeColor: payload["themeColor"] as? String,
            presentationHints: (payload["presentationHints"] as? [String: Any])?.mapValues { AnyCodable($0) }
        )
    }

    var isEmpty: Bool {
        toolName == nil &&
            traceId == nil &&
            rootInvocationId == nil &&
            themeColor == nil &&
            presentationHints == nil
    }
}
