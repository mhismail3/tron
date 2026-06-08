import Foundation
import SwiftUI

// MARK: - Capability Invocation Data

struct CapabilityInvocationData: Equatable, Identifiable {
    let id: String
    var status: CapabilityInvocationStatus
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
    var identity: CapabilityIdentity
    var artifacts: [CapabilityArtifactData]
    var logs: [String]
    var errorClassification: CapabilityErrorClassification?

    init(
        id: String,
        status: CapabilityInvocationStatus,
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
        identity: CapabilityIdentity,
        artifacts: [CapabilityArtifactData] = [],
        logs: [String] = [],
        errorClassification: CapabilityErrorClassification? = nil
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

    var display: CapabilityInvocationDisplayModel {
        CapabilityInvocationDisplayModel(data: self)
    }
}

enum CapabilityInvocationStatus: Equatable, Sendable {
    case generating
    case running
    case paused
    case success
    case error
    case unavailable

    var iconName: String {
        switch self {
        case .generating, .running:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.circle.fill"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct CapabilityInvocationResultData: Equatable {
    let id: String
    let content: String
    let isError: Bool
    let identity: CapabilityIdentity
    let arguments: String?
    let durationMs: Int?
    let details: [String: AnyCodable]?

    var truncatedContent: String {
        content.truncated(to: 503)
    }
}

struct CapabilityArtifactData: Equatable, Sendable {
    var id: String
    var label: String?
    var mimeType: String?
    var url: String?
}

struct CapabilityErrorClassification: Equatable, Sendable {
    var code: String?
    var category: String?
    var message: String?
    var recoverable: Bool?
}

extension CapabilityIdentity {
    init(payload: [String: Any]) {
        self.init(
            modelPrimitiveName: payload["modelPrimitiveName"] as? String,
            operationName: payload["operationName"] as? String ?? payload["operation"] as? String,
            traceId: payload["traceId"] as? String,
            rootInvocationId: payload["rootInvocationId"] as? String,
            themeColor: payload["themeColor"] as? String,
            presentationHints: (payload["presentationHints"] as? [String: Any])?.mapValues { AnyCodable($0) }
        )
    }

    var stableCapabilityId: String {
        operationName ?? modelPrimitiveName ?? "execute"
    }

    var isEmpty: Bool {
        modelPrimitiveName == nil &&
            operationName == nil &&
            traceId == nil &&
            rootInvocationId == nil &&
            themeColor == nil &&
            presentationHints == nil
    }
}
