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
    var identity: CapabilityIdentity
    var approvalState: [String: AnyCodable]?
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
        identity: CapabilityIdentity,
        approvalState: [String: AnyCodable]? = nil,
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
        self.identity = identity
        self.approvalState = approvalState
        self.artifacts = artifacts
        self.logs = logs
        self.errorClassification = errorClassification
    }

    var displayName: String {
        CapabilityPresentation.title(for: identity)
    }

    var subtitle: String {
        if let progressMessage, !progressMessage.isEmpty {
            return progressMessage
        }
        if let contractId = identity.contractId, identity.modelPrimitiveName == "execute" {
            return contractId
        }
        if let implementationId = identity.implementationId {
            return implementationId
        }
        return identity.modelPrimitiveName ?? "Capability"
    }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    var truncatedArguments: String {
        arguments.truncated(to: 203)
    }
}

enum CapabilityInvocationStatus: Equatable, Sendable {
    case generating
    case running
    case approvalRequired
    case success
    case error
    case unavailable

    var iconName: String {
        switch self {
        case .generating, .running:
            return "arrow.triangle.2.circlepath"
        case .approvalRequired:
            return "hand.raised.fill"
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

enum CapabilityPresentation {
    static func title(for identity: CapabilityIdentity) -> String {
        if let contractId = identity.contractId, identity.modelPrimitiveName != contractId {
            return humanizeCapabilityId(contractId)
        }
        if let functionId = identity.functionId {
            return humanizeCapabilityId(functionId)
        }
        if let modelPrimitiveName = identity.modelPrimitiveName {
            switch modelPrimitiveName {
            case "search": return "Search capabilities"
            case "inspect": return "Inspect capability"
            case "execute": return "Resolve capability"
            default: return humanizeCapabilityId(modelPrimitiveName)
            }
        }
        return "Capability"
    }

    static func symbol(for identity: CapabilityIdentity) -> String {
        let id = identity.contractId ?? identity.functionId ?? identity.modelPrimitiveName ?? ""
        if id.hasPrefix("filesystem::") { return "doc.text.magnifyingglass" }
        if id.hasPrefix("process::") { return "terminal" }
        if id.hasPrefix("web::") { return "globe" }
        if id.hasPrefix("agent::") { return "person.crop.circle.badge.plus" }
        if id.hasPrefix("sandbox::") { return "shippingbox" }
        if id.hasPrefix("capability::search") || identity.modelPrimitiveName == "search" { return "magnifyingglass" }
        if id.hasPrefix("capability::inspect") || identity.modelPrimitiveName == "inspect" { return "info.circle" }
        if id.hasPrefix("capability::execute") || identity.modelPrimitiveName == "execute" { return "play.circle" }
        return "puzzlepiece.extension"
    }

    static func color(for identity: CapabilityIdentity) -> Color {
        switch identity.riskLevel?.lowercased() {
        case "critical", "high":
            return .tronError
        case "medium":
            return .tronAmber
        default:
            return .tronBlue
        }
    }

    static func humanizeCapabilityId(_ id: String) -> String {
        let tail = id.split(separator: "::").last.map(String.init) ?? id
        return tail
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

extension CapabilityIdentity {
    init(payload: [String: Any]) {
        self.init(
            modelPrimitiveName: payload["modelPrimitiveName"] as? String,
            contractId: payload["contractId"] as? String,
            implementationId: payload["implementationId"] as? String,
            functionId: payload["functionId"] as? String,
            pluginId: payload["pluginId"] as? String,
            workerId: payload["workerId"] as? String,
            schemaDigest: payload["schemaDigest"] as? String,
            catalogRevision: CapabilityIdentity.uint64Value(payload["catalogRevision"]),
            trustTier: payload["trustTier"] as? String,
            riskLevel: payload["riskLevel"] as? String,
            effectClass: payload["effectClass"] as? String,
            traceId: payload["traceId"] as? String,
            rootInvocationId: payload["rootInvocationId"] as? String,
            bindingDecisionId: payload["bindingDecisionId"] as? String
        )
    }

    var isUserInteractionCapability: Bool {
        contractId == "agent::ask_user" || functionId == "agent::ask_user"
    }

    var stableCapabilityId: String {
        implementationId ?? contractId ?? functionId ?? modelPrimitiveName ?? "capability"
    }

    var isEmpty: Bool {
        modelPrimitiveName == nil &&
        contractId == nil &&
        implementationId == nil &&
        functionId == nil &&
        pluginId == nil &&
        workerId == nil &&
        schemaDigest == nil &&
        catalogRevision == nil &&
        trustTier == nil &&
        riskLevel == nil &&
        effectClass == nil &&
        traceId == nil &&
        rootInvocationId == nil &&
            bindingDecisionId == nil
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            return value
        case let value as UInt:
            return UInt64(value)
        case let value as Int where value >= 0:
            return UInt64(value)
        case let value as NSNumber:
            return value.uint64Value
        case let value as String:
            return UInt64(value)
        default:
            return nil
        }
    }
}
