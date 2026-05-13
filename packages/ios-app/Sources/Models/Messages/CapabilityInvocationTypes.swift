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
        display.primitiveTitle
    }

    var subtitle: String {
        display.commandText
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

    var display: CapabilityInvocationDisplayModel {
        CapabilityInvocationDisplayModel(data: self)
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

struct CapabilityDisplayRow: Equatable, Identifiable {
    let label: String
    let value: String
    var isTechnical: Bool = false

    var id: String { "\(label)|\(value)" }
}

struct CapabilityInvocationDisplayModel: Equatable {
    let primitiveTitle: String
    let commandText: String
    let statusText: String
    let statusWithDuration: String
    let targetId: String?
    let payloadSummary: String?
    let requestRows: [CapabilityDisplayRow]
    let technicalRows: [CapabilityDisplayRow]
    let prettyArguments: String?

    init(data: CapabilityInvocationData) {
        let argumentObject = Self.argumentObject(from: data)
        let primitive = Self.normalizedPrimitive(from: data.identity)
        let target = Self.targetId(for: primitive, identity: data.identity, arguments: argumentObject)
        let payload = argumentObject["payload"] as? [String: Any]
        let payloadSummary = Self.payloadSummary(from: payload ?? argumentObject)
        let query = Self.firstString(["query", "q", "searchQuery"], in: argumentObject)
            ?? Self.firstString(["query"], in: data.details?.rawValues ?? [:])

        self.primitiveTitle = Self.primitiveTitle(primitive)
        self.targetId = target
        self.payloadSummary = payloadSummary
        self.statusText = Self.statusText(data.status)
        self.statusWithDuration = [Self.statusText(data.status), data.formattedDuration]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
        self.commandText = Self.commandText(
            primitive: primitive,
            query: query,
            target: target,
            payloadSummary: payloadSummary,
            identity: data.identity
        )
        self.requestRows = Self.requestRows(
            primitive: primitive,
            query: query,
            target: target,
            payloadSummary: payloadSummary,
            arguments: argumentObject
        )
        self.technicalRows = Self.technicalRows(identity: data.identity)
        self.prettyArguments = Self.prettyJSONString(data.arguments) ?? data.arguments.nilIfEmpty
    }

    private static func normalizedPrimitive(from identity: CapabilityIdentity) -> String {
        if let modelPrimitiveName = identity.modelPrimitiveName?.lowercased(),
           ["search", "inspect", "execute"].contains(modelPrimitiveName) {
            return modelPrimitiveName
        }
        let id = identity.contractId ?? identity.functionId ?? ""
        if id == "capability::search" { return "search" }
        if id == "capability::inspect" { return "inspect" }
        return "execute"
    }

    private static func primitiveTitle(_ primitive: String) -> String {
        switch primitive {
        case "search": return "Search"
        case "inspect": return "Inspect"
        default: return "Execute"
        }
    }

    private static func statusText(_ status: CapabilityInvocationStatus) -> String {
        switch status {
        case .generating: return "Preparing"
        case .running: return "Running"
        case .approvalRequired: return "Approval required"
        case .success: return "Completed"
        case .error: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }

    private static func commandText(
        primitive: String,
        query: String?,
        target: String?,
        payloadSummary: String?,
        identity: CapabilityIdentity
    ) -> String {
        switch primitive {
        case "search":
            if let query = query?.nilIfEmpty {
                return "“\(query.truncated(to: 96))”"
            }
            return "Capability catalog"
        case "inspect":
            return (target ?? identity.contractId ?? identity.functionId ?? "Capability metadata")
                .truncated(to: 120)
        default:
            if let target, let payloadSummary {
                return "\(target) · \(payloadSummary)".truncated(to: 140)
            }
            if let target {
                return target.truncated(to: 120)
            }
            if let payloadSummary {
                return payloadSummary.truncated(to: 120)
            }
            return "Capability invocation"
        }
    }

    private static func targetId(
        for primitive: String,
        identity: CapabilityIdentity,
        arguments: [String: Any]
    ) -> String? {
        let argumentTarget = firstString(
            ["capabilityId", "contractId", "implementationId", "functionId", "capability", "contract", "function"],
            in: arguments
        )
        if let argumentTarget = argumentTarget?.nilIfEmpty {
            return argumentTarget
        }

        switch primitive {
        case "search":
            return nil
        case "inspect":
            return identity.contractId ?? identity.functionId ?? identity.implementationId
        default:
            if let contractId = identity.contractId, !contractId.hasPrefix("capability::") {
                return contractId
            }
            if let functionId = identity.functionId, !functionId.hasPrefix("capability::") {
                return functionId
            }
            return identity.implementationId
        }
    }

    private static func payloadSummary(from object: [String: Any]) -> String? {
        if let command = firstString(["command", "cmd", "shellCommand"], in: object)?.nilIfEmpty {
            return command.truncated(to: 96)
        }
        if let path = firstString(["path", "filePath", "cwd"], in: object)?.nilIfEmpty {
            return path.abbreviatingHomeDirectory.truncated(to: 96)
        }
        if let query = firstString(["query", "q", "searchQuery"], in: object)?.nilIfEmpty {
            return "query: \(query.truncated(to: 80))"
        }
        if let url = firstString(["url", "apiUrl", "endpoint"], in: object)?.nilIfEmpty {
            return url.truncated(to: 96)
        }
        if let code = firstString(["code"], in: object)?.nilIfEmpty {
            let firstLine = code.lines.first?.trimmed.nilIfEmpty ?? "program"
            return firstLine.truncated(to: 96)
        }

        let simplePairs = object
            .filter { key, value in
                !["payload", "allowedContracts", "allowedImplementations"].contains(key)
                    && Self.simpleDisplayValue(value) != nil
            }
            .sorted { $0.key < $1.key }
            .prefix(2)
            .compactMap { key, value in
                simpleDisplayValue(value).map { "\(key)=\($0)" }
            }
        guard !simplePairs.isEmpty else { return nil }
        return simplePairs.joined(separator: ", ").truncated(to: 96)
    }

    private static func requestRows(
        primitive: String,
        query: String?,
        target: String?,
        payloadSummary: String?,
        arguments: [String: Any]
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value))
        }

        switch primitive {
        case "search":
            append("Query", query)
            append("Kind", firstString(["kind"], in: arguments))
            append("Namespace", firstString(["namespace"], in: arguments))
            append("Contract", firstString(["contractId"], in: arguments))
            append("Plugin", firstString(["pluginId"], in: arguments))
            append("Risk ceiling", firstString(["riskMax"], in: arguments))
            append("Trust floor", firstString(["trustTierMin"], in: arguments))
        case "inspect":
            append("Target", target)
            append("Contract", firstString(["contractId"], in: arguments))
            append("Implementation", firstString(["implementationId"], in: arguments))
            append("Function", firstString(["functionId"], in: arguments))
        default:
            append("Target", target)
            append("Mode", firstString(["mode"], in: arguments))
            append("Payload", payloadSummary)
            append("Reason", firstString(["reason"], in: arguments))
            append("Idempotency", firstString(["idempotencyKey"], in: arguments))
        }

        if rows.isEmpty, let payloadSummary {
            rows.append(CapabilityDisplayRow(label: "Request", value: payloadSummary))
        }
        return rows
    }

    private static func technicalRows(identity: CapabilityIdentity) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: true))
        }
        append("Primitive", identity.modelPrimitiveName)
        append("Contract", identity.contractId)
        append("Implementation", identity.implementationId)
        append("Function", identity.functionId)
        append("Plugin", identity.pluginId)
        append("Worker", identity.workerId)
        append("Catalog", identity.catalogRevision.map(String.init))
        append("Schema", identity.schemaDigest)
        append("Trust", identity.trustTier)
        append("Risk", identity.riskLevel)
        append("Effect", identity.effectClass)
        append("Trace", identity.traceId)
        append("Root invocation", identity.rootInvocationId)
        append("Binding", identity.bindingDecisionId)
        return rows
    }

    private static func argumentObject(from data: CapabilityInvocationData) -> [String: Any] {
        if let payloadJSON = data.payloadJSON {
            return payloadJSON.rawValues
        }
        return objectFromJSONString(data.arguments) ?? [:]
    }

    private static func objectFromJSONString(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func prettyJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private static func firstString(_ keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let value = object[key], let string = simpleDisplayValue(value)?.nilIfEmpty {
                return string
            }
        }
        return nil
    }

    private static func simpleDisplayValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
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

private extension Dictionary where Key == String, Value == AnyCodable {
    var rawValues: [String: Any] {
        mapValues(\.value)
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
