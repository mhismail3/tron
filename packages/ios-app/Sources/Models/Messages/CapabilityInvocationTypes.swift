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
        generatedAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
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
        self.generatedAt = generatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
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
    case approvalRequired
    case success
    case error
    case unavailable

    var iconName: String {
        switch self {
        case .generating, .running:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.circle.fill"
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

struct CapabilityDisplayGroup: Equatable, Identifiable {
    let title: String
    let rows: [CapabilityDisplayRow]

    var id: String { title }
}

struct CapabilityInvocationDisplayModel: Equatable {
    let primitiveTitle: String
    let chipTitle: String
    let capabilityName: String
    let commandText: String
    let statusText: String
    let statusWithDuration: String
    let targetId: String?
    let payloadSummary: String?
    let capabilityRows: [CapabilityDisplayRow]
    let requestRows: [CapabilityDisplayRow]
    let executionGroups: [CapabilityDisplayGroup]
    let resultRows: [CapabilityDisplayRow]
    let resultPreview: String?
    let technicalRows: [CapabilityDisplayRow]
    let prettyArguments: String?
    let prettyResult: String?

    init(data: CapabilityInvocationData) {
        let argumentObject = Self.argumentObject(from: data)
        let primitive = CapabilityPresentation.primitiveName(for: data.identity)
        let target = Self.targetId(for: primitive, identity: data.identity, arguments: argumentObject)
        let targetArguments = Self.targetArguments(from: argumentObject)
        let payloadSummary = Self.payloadSummary(target: target, from: targetArguments ?? argumentObject)
        let capabilityName = CapabilityPresentation.title(for: data.identity, targetId: target)
        let query = Self.firstString(["query", "q", "searchQuery"], in: argumentObject)
            ?? Self.firstString(["query"], in: data.details?.rawValues ?? [:])
        let details = data.details?.rawValues ?? [:]
        let outputObject = Self.outputObject(from: data)

        self.primitiveTitle = Self.primitiveTitle(primitive)
        self.chipTitle = Self.chipTitle(
            primitive: primitive,
            capabilityName: capabilityName,
            identity: data.identity
        )
        self.capabilityName = capabilityName
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
            capabilityName: capabilityName,
            identity: data.identity
        )
        self.capabilityRows = Self.capabilityRows(
            primitive: primitive,
            identity: data.identity,
            target: target,
            capabilityName: capabilityName,
            status: data.status,
            duration: data.formattedDuration
        )
        self.requestRows = Self.requestRows(
            primitive: primitive,
            query: query,
            target: target,
            capabilityName: capabilityName,
            payloadSummary: payloadSummary,
            arguments: argumentObject
        )
        self.executionGroups = Self.executionGroups(
            primitive: primitive,
            data: data,
            details: details,
            arguments: argumentObject,
            output: outputObject
        )
        self.resultRows = Self.resultRows(
            data: data,
            details: details,
            output: outputObject
        )
        self.resultPreview = Self.resultPreview(
            primitive: primitive,
            result: data.result,
            output: outputObject
        )
        self.technicalRows = Self.technicalRows(data: data)
        self.prettyArguments = Self.prettyJSONString(data.arguments) ?? data.arguments.nilIfEmpty
        self.prettyResult = data.result.flatMap(Self.prettyJSONString) ?? data.result?.nilIfEmpty
    }

    private static func primitiveTitle(_ primitive: String) -> String {
        switch primitive {
        case "search": return "Search"
        case "inspect": return "Inspect"
        default: return "Execute"
        }
    }

    private static func chipTitle(
        primitive: String,
        capabilityName: String,
        identity: CapabilityIdentity
    ) -> String {
        if let chipTitle = CapabilityPresentation.presentationString("chipTitle", for: identity) {
            return chipTitle
        }
        switch primitive {
        case "inspect":
            return "Inspect"
        default:
            return capabilityName
        }
    }

    private static func statusText(_ status: CapabilityInvocationStatus) -> String {
        switch status {
        case .generating: return "Preparing"
        case .running: return "Running"
        case .paused: return "Paused"
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
        capabilityName: String,
        identity: CapabilityIdentity
    ) -> String {
        switch primitive {
        case "search":
            if let query = query?.nilIfEmpty {
                return "“\(query.truncated(to: 96))”"
            }
            return "Capability catalog"
        case "inspect":
            return (target.map(CapabilityPresentation.humanizeCapabilityId)
                ?? identity.contractId.map(CapabilityPresentation.humanizeCapabilityId)
                ?? identity.functionId.map(CapabilityPresentation.humanizeCapabilityId)
                ?? "Capability metadata")
                .truncated(to: 120)
        default:
            if primitive == "execute", target == nil {
                return "Invocation"
            }
            if let payloadSummary {
                return payloadSummary.truncated(to: 140)
            }
            if let target, target != capabilityName {
                return CapabilityPresentation.humanizeCapabilityId(target).truncated(to: 120)
            }
            return "Invocation"
        }
    }

    private static func targetId(
        for primitive: String,
        identity: CapabilityIdentity,
        arguments: [String: Any]
    ) -> String? {
        if let target = targetHint(from: arguments)?.nilIfEmpty {
            return target
        }

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
            if primitive == "execute" {
                return nil
            }
            return identity.implementationId
        }
    }

    private static func targetHint(from object: [String: Any]) -> String? {
        if let target = object["target"] as? String {
            return target
        }
        if let target = object["target"] as? [String: Any] {
            return firstString(
                ["capabilityId", "contractId", "implementationId", "functionId", "capability", "contract", "function"],
                in: target
            )
        }
        return nil
    }

    private static func targetArguments(from object: [String: Any]) -> [String: Any]? {
        if let arguments = object["arguments"] as? [String: Any] {
            return arguments
        }
        if let payload = object["payload"] as? [String: Any] {
            return payload
        }
        return nil
    }

    private static func payloadSummary(target: String?, from object: [String: Any]) -> String? {
        if let command = firstString(["command", "cmd", "shellCommand"], in: object)?.nilIfEmpty {
            return command.truncated(to: 96)
        }
        if let query = firstString(["query", "q", "searchQuery"], in: object)?.nilIfEmpty {
            return query.truncated(to: 80)
        }
        if let pattern = firstString(["pattern", "glob", "name"], in: object)?.nilIfEmpty {
            return pattern.truncated(to: 80)
        }
        if let url = firstString(["url", "apiUrl", "endpoint"], in: object)?.nilIfEmpty {
            return url.truncated(to: 96)
        }
        if let path = firstString(["path", "filePath", "cwd"], in: object)?.nilIfEmpty {
            return compactPathLabel(path).truncated(to: 80)
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

    private static func capabilityRows(
        primitive: String,
        identity: CapabilityIdentity,
        target: String?,
        capabilityName: String,
        status: CapabilityInvocationStatus,
        duration: String?
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }

        append("Capability", target ?? identity.contractId ?? identity.functionId ?? primitive, technical: true)
        append("Name", capabilityName)
        append("Source", CapabilityPresentation.sourceLabel(for: identity))
        append("Duration", duration)
        append("Plugin", CapabilityPresentation.pluginLabel(for: identity))
        return rows
    }

    private static func requestRows(
        primitive: String,
        query: String?,
        target: String?,
        capabilityName: String,
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
            if let targetArguments = targetArguments(from: arguments) {
                appendPayloadRows(targetArguments, into: &rows)
            } else {
                append("Payload", payloadSummary)
            }
            append("Intent", firstString(["intent"], in: arguments))
            append("Reason", firstString(["reason"], in: arguments))
        }

        if rows.isEmpty, let payloadSummary {
            rows.append(CapabilityDisplayRow(label: "Request", value: payloadSummary))
        }
        return rows
    }

    private static func appendPayloadRows(_ payload: [String: Any], into rows: inout [CapabilityDisplayRow]) {
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value))
        }
        append("Command", firstString(["command", "cmd", "shellCommand"], in: payload))
        append("Execution mode", firstString(["executionMode", "mode"], in: payload))
        append("Query", firstString(["query", "q", "searchQuery", "pattern", "glob", "name"], in: payload))
        append("URL", firstString(["url", "apiUrl", "endpoint"], in: payload))
        if let path = firstString(["path", "filePath"], in: payload) {
            append("Path", compactPathLabel(path))
        }
        if let cwd = firstString(["cwd"], in: payload) {
            append("Working directory", compactPathLabel(cwd))
        }
        if let code = firstString(["code"], in: payload) {
            append("Code", code.lines.first?.trimmed.nilIfEmpty ?? "program")
        }

        let alreadyShown = Set([
            "command", "cmd", "shellCommand", "executionMode", "mode", "query", "q", "searchQuery", "pattern", "glob",
            "name", "url", "apiUrl", "endpoint", "path", "filePath", "cwd", "code"
        ])
        let extraRows = payload
            .filter { key, value in
                !alreadyShown.contains(key) && simplePayloadExtraValue(value) != nil
            }
            .sorted { $0.key < $1.key }
            .prefix(3)
            .compactMap { key, value -> CapabilityDisplayRow? in
                simplePayloadExtraValue(value).map { CapabilityDisplayRow(label: humanizeKey(key), value: $0) }
            }
        rows.append(contentsOf: extraRows)
    }

    private static func executionGroups(
        primitive: String,
        data: CapabilityInvocationData,
        details: [String: Any],
        arguments: [String: Any],
        output: [String: Any]
    ) -> [CapabilityDisplayGroup] {
        guard primitive == "execute" else { return [] }

        let orchestration = dictionary(details["orchestration"])
        let phaseDetails = dictionary(orchestration?["phaseDetails"])
        let selectedTarget = dictionary(phaseDetails?["selectedTarget"])
        let preparedRequest = dictionary(phaseDetails?["preparedRequest"])
        let binding = dictionary(details["bindingDecision"])
        let correctedRequest = dictionary(details["correctedRequest"]) ?? dictionary(orchestration?["correctedRequest"])
        let childInvocations = stringArray(details["childInvocations"])
            ?? stringArray(orchestration?["childInvocationIds"])
            ?? []
        let corrections = array(details["correctionsApplied"])
            ?? array(orchestration?["correctionsApplied"])
            ?? []

        var groups: [CapabilityDisplayGroup] = []

        var resolution: [CapabilityDisplayRow] = []
        appendRow("Mode", humanizeToken(string(phaseDetails?["resolveMode"])), to: &resolution)
        appendRow("Target", string(selectedTarget?["contractId"]) ?? string(selectedTarget?["functionId"]) ?? targetHint(from: arguments), to: &resolution, technical: true)
        appendRow("Implementation", string(selectedTarget?["implementationId"]) ?? string(binding?["selectedImplementation"]), to: &resolution, technical: true)
        appendRow("Selection", humanizeToken(string(binding?["selectionPolicy"])), to: &resolution)
        appendRow("Catalog", string(selectedTarget?["catalogRevision"]) ?? string(details["catalogRevision"]), to: &resolution, technical: true)
        if let rejected = array(phaseDetails?["rejectedCandidates"]), !rejected.isEmpty {
            appendRow("Rejected candidates", String(rejected.count), to: &resolution)
        }
        if !resolution.isEmpty {
            groups.append(CapabilityDisplayGroup(title: "Resolution", rows: resolution))
        }

        var preparation: [CapabilityDisplayRow] = []
        appendRow("Capability risk", humanizeToken(string(selectedTarget?["riskLevel"]) ?? data.identity.riskLevel), to: &preparation)
        appendRow("Effect class", humanizeToken(string(selectedTarget?["effectClass"]) ?? data.identity.effectClass), to: &preparation)
        appendRow("Schema", string(selectedTarget?["schemaDigest"]) ?? data.identity.schemaDigest, to: &preparation, technical: true)
        appendRow("Payload", bool(preparedRequest?["hasPayload"]).map { $0 ? "Validated" : "Not provided" }, to: &preparation)
        appendRow("Fresh handle", bool(preparedRequest?["hasInspectionHandle"]).map { $0 ? "Prepared" : "Not required" }, to: &preparation)
        appendRow("Approval", approvalSummary(details: details, approvalState: data.approvalState), to: &preparation)
        appendRow("Corrections", correctionSummary(corrections), to: &preparation)
        if !preparation.isEmpty {
            groups.append(CapabilityDisplayGroup(title: "Preparation", rows: preparation))
        }

        var run: [CapabilityDisplayRow] = []
        appendRow("Child invocation", childInvocations.first.map(compactIdentifier), to: &run, technical: true)
        if childInvocations.count > 1 {
            appendRow("Child count", String(childInvocations.count), to: &run)
        }
        appendRow("Function", string(selectedTarget?["functionId"]) ?? data.identity.functionId, to: &run, technical: true)
        appendRow("Worker", data.identity.workerId, to: &run, technical: true)
        appendRow("Status", statusText(data.status), to: &run)
        appendRow("Duration", data.formattedDuration, to: &run)
        if !run.isEmpty {
            groups.append(CapabilityDisplayGroup(title: "Run", rows: run))
        }

        var guardrails: [CapabilityDisplayRow] = []
        if let searchStatus = dictionary(phaseDetails?["searchStatus"]) {
            appendRow("Search", humanizeToken(string(searchStatus["state"])), to: &guardrails)
            appendRow("Vector index", bool(searchStatus["localVector"]).map { $0 ? "Ready" : "Unavailable" }, to: &guardrails)
            appendRow("Lexical", bool(searchStatus["lexical"]).map { $0 ? "Enabled" : "Disabled" }, to: &guardrails)
            appendRow("Degraded reason", string(searchStatus["degradedReason"]), to: &guardrails)
        }
        if !guardrails.isEmpty {
            groups.append(CapabilityDisplayGroup(title: "Discovery", rows: guardrails))
        }

        if correctedRequest != nil, !corrections.isEmpty {
            var corrected: [CapabilityDisplayRow] = []
            appendRow("Confidence", string(details["correctionConfidence"]) ?? string(orchestration?["correctionConfidence"]), to: &corrected)
            appendRow("Applied", correctionSummary(corrections), to: &corrected)
            if !corrected.isEmpty {
                groups.append(CapabilityDisplayGroup(title: "Corrections", rows: corrected))
            }
        }

        return groups
    }

    private static func approvalSummary(
        details: [String: Any],
        approvalState: [String: AnyCodable]?
    ) -> String {
        if bool(details["approvalReplayed"]) == true {
            return "Replayed previous approval"
        }
        if bool(details["approvalRequired"]) == true || approvalState?.isEmpty == false {
            return "Required"
        }
        return "Not required"
    }

    private static func resultRows(
        data: CapabilityInvocationData,
        details _: [String: Any],
        output: [String: Any]
    ) -> [CapabilityDisplayRow] {
        guard CapabilityPresentation.primitiveName(for: data.identity) == "execute" else { return [] }
        let hasProcessOutput = firstString(["exitCode"], in: output) != nil
            || firstString(["timedOut"], in: output) != nil
            || firstString(["stdout"], in: output) != nil
            || firstString(["stderr"], in: output) != nil
        guard hasProcessOutput else { return [] }

        var rows: [CapabilityDisplayRow] = []
        appendRow("Exit code", firstString(["exitCode"], in: output), to: &rows)
        appendRow("Timed out", readableBool(["timedOut"], in: output), to: &rows)
        appendRow("Output truncated", readableBool(["outputTruncated", "truncated"], in: output), to: &rows)
        return rows
    }

    private static func resultPreview(
        primitive: String,
        result: String?,
        output: [String: Any]
    ) -> String? {
        guard primitive == "execute" else {
            return nil
        }
        if let stdout = firstString(["stdout"], in: output)?.nilIfEmpty {
            return stdout.truncated(to: 4_000)
        }
        if let stderr = firstString(["stderr"], in: output)?.nilIfEmpty {
            return stderr.truncated(to: 4_000)
        }
        if let content = firstString(["content"], in: output)?.nilIfEmpty {
            return content.truncated(to: 4_000)
        }
        if let diff = firstString(["diff"], in: output)?.nilIfEmpty {
            return diff.truncated(to: 4_000)
        }
        if let entries = output["entries"] as? [[String: Any]] {
            let names = entries.prefix(12).compactMap { firstString(["name", "path"], in: $0) }
            guard !names.isEmpty else { return nil }
            let more = entries.count > names.count ? "\n… \(entries.count - names.count) more" : ""
            return (names.joined(separator: "\n") + more).truncated(to: 4_000)
        }
        if let matches = output["matches"] as? [[String: Any]] {
            let lines = matches.prefix(8).compactMap { match -> String? in
                let file = firstString(["path"], in: match).map(compactPathLabel)
                let line = firstString(["line"], in: match)
                let text = firstString(["text"], in: match)
                return [file, line, text].compactMap { $0?.nilIfEmpty }.joined(separator: ": ")
            }
            guard !lines.isEmpty else { return nil }
            let more = matches.count > lines.count ? "\n… \(matches.count - lines.count) more" : ""
            return (lines.joined(separator: "\n") + more).truncated(to: 4_000)
        }
        guard let result = result?.nilIfEmpty else { return nil }
        let pretty = prettyJSONString(result) ?? result
        return pretty.count <= 1_200 ? pretty : nil
    }

    private static func technicalRows(data: CapabilityInvocationData) -> [CapabilityDisplayRow] {
        let identity = data.identity
        let details = data.details?.rawValues ?? [:]
        let output = outputObject(from: data)
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: true))
        }
        append("Invocation", data.id)
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
        append("Theme color", identity.themeColor)
        append("Server duration", data.serverFormattedDuration)
        append("Observed duration", data.observedDurationMs.map(CapabilityInvocationData.formatDuration))
        append("Engine status", firstString(["status"], in: details))
        append("Exit code", firstString(["exitCode"], in: output))
        append("Timed out", firstString(["timedOut"], in: output))
        append("Output truncated", firstString(["outputTruncated", "truncated"], in: output))
        if let entries = output["entries"] as? [Any] {
            append("Entry count", String(entries.count))
        }
        if let matches = output["matches"] as? [Any] {
            append("Match count", String(matches.count))
        }
        if let path = firstString(["path"], in: output) {
            append("Result path", compactPathLabel(path))
        }
        if let childInvocations = data.details?.rawValues["childInvocations"] as? [Any], !childInvocations.isEmpty {
            append("Child invocations", String(childInvocations.count))
        }
        return rows
    }

    private static func appendRow(
        _ label: String,
        _ value: String?,
        to rows: inout [CapabilityDisplayRow],
        technical: Bool = false
    ) {
        guard let value = value?.nilIfEmpty else { return }
        rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
    }

    private static func argumentObject(from data: CapabilityInvocationData) -> [String: Any] {
        if let payloadJSON = data.payloadJSON {
            return payloadJSON.rawValues
        }
        return objectFromJSONString(data.arguments) ?? [:]
    }

    private static func outputObject(from data: CapabilityInvocationData) -> [String: Any] {
        if let output = data.details?.anyCodableDict("output")?.rawValues {
            return output
        }
        if let result = data.result, let object = objectFromJSONString(result) {
            return object
        }
        return [:]
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

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [String: AnyCodable] {
            return dictionary.rawValues
        }
        if let value = value as? AnyCodable {
            return value.dictionaryValue
        }
        return nil
    }

    private static func array(_ value: Any?) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        if let value = value as? AnyCodable {
            return value.arrayValue
        }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        array(value)?.compactMap { item in
            if let string = item as? String {
                return string
            }
            return simpleDisplayValue(item)
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value {
            return simpleDisplayValue(value)
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let value = value as? AnyCodable {
            return value.boolValue
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
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

    private static func humanizeToken(_ token: String?) -> String? {
        guard let token = token?.nilIfEmpty else { return nil }
        let withWordBreaks = token
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
        return withWordBreaks
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func readableBool(_ keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let bool = object[key] as? Bool {
                return bool ? "Yes" : "No"
            }
            if let number = object[key] as? NSNumber {
                return number.boolValue ? "Yes" : "No"
            }
            if let string = (object[key] as? String)?.trimmed.lowercased() {
                switch string {
                case "true", "yes", "1":
                    return "Yes"
                case "false", "no", "0":
                    return "No"
                default:
                    continue
                }
            }
        }
        return nil
    }

    private static func correctionSummary(_ corrections: [Any]) -> String {
        guard !corrections.isEmpty else { return "None" }
        let labels = corrections.prefix(3).compactMap { item -> String? in
            if let item = item as? [String: Any] {
                return firstString(["message", "kind"], in: item)
            }
            if let item = item as? [String: AnyCodable] {
                return firstString(["message", "kind"], in: item.rawValues)
            }
            return simpleDisplayValue(item)
        }
        if labels.isEmpty {
            return "\(corrections.count) applied"
        }
        let more = corrections.count > labels.count ? " +\(corrections.count - labels.count) more" : ""
        return labels.joined(separator: "; ") + more
    }

    private static func compactIdentifier(_ id: String) -> String {
        guard id.count > 28 else { return id }
        let prefix = id.prefix(12)
        let suffix = id.suffix(10)
        return "\(prefix)…\(suffix)"
    }

    private static func simplePayloadExtraValue(_ value: Any) -> String? {
        if let bool = value as? Bool {
            return bool ? "true" : nil
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : nil
        }
        return simpleDisplayValue(value)
    }

    private static func compactPathLabel(_ path: String) -> String {
        if path.contains("/.worktrees/session/") || path.contains("\\.worktrees\\session\\") {
            let last = (path as NSString).lastPathComponent
            if last.hasPrefix("sess_") || last.isEmpty {
                return "session worktree"
            }
            return last
        }
        let abbreviated = path.abbreviatingHomeDirectory
        let last = (abbreviated as NSString).lastPathComponent
        if !last.isEmpty, last != "/" {
            return last
        }
        return abbreviated
    }

    private static func humanizeKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

enum CapabilityPresentation {
    static func primitiveName(for identity: CapabilityIdentity) -> String {
        if let modelPrimitiveName = identity.modelPrimitiveName?.lowercased(),
           ["search", "inspect", "execute"].contains(modelPrimitiveName) {
            return modelPrimitiveName
        }
        let id = identity.contractId ?? identity.functionId ?? ""
        if id == "capability::search" { return "search" }
        if id == "capability::inspect" { return "inspect" }
        return "execute"
    }

    static func title(for identity: CapabilityIdentity, targetId: String? = nil) -> String {
        if let displayName = presentationString("displayName", for: identity)
            ?? presentationString("title", for: identity) {
            return displayName
        }
        if let targetId, !targetId.hasPrefix("capability::") {
            return humanizeCapabilityId(targetId)
        }
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
        if let icon = presentationString("sfSymbol", for: identity)
            ?? presentationString("symbol", for: identity)
            ?? presentationString("icon", for: identity),
           let symbol = nativeSymbolName(for: icon) {
            return symbol
        }
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

    static func primitiveColor(for identity: CapabilityIdentity, targetId: String? = nil) -> Color {
        if let color = colorFromTheme(themeColorHex(for: identity, targetId: targetId)) {
            return color
        }
        switch primitiveName(for: identity) {
        case "search":
            return .tronBlue
        case "inspect":
            return .tronPurple
        default:
            return .tronEmerald
        }
    }

    static func statusColor(
        for status: CapabilityInvocationStatus,
        identity: CapabilityIdentity,
        targetId: String? = nil
    ) -> Color {
        switch status {
        case .approvalRequired, .paused:
            return .tronAmber
        case .error, .unavailable:
            return .tronError
        case .generating, .running, .success:
            return primitiveColor(for: identity, targetId: targetId)
        }
    }

    static func sourceColor(for identity: CapabilityIdentity) -> Color {
        let trustTier = identity.trustTier?.lowercased() ?? ""
        let pluginId = identity.pluginId?.lowercased() ?? ""

        if trustTier.contains("external_mcp") || pluginId.contains("mcp") {
            return .tronTeal
        }
        if trustTier.contains("external_openapi") || pluginId.contains("openapi") {
            return .tronCyan
        }
        if trustTier.contains("session_generated") || pluginId.contains("sandbox") {
            return .tronPurple
        }
        if trustTier.contains("user_installed") {
            return .tronAmber
        }
        if trustTier.contains("trusted_signed") {
            return .tronIndigo
        }
        if trustTier.contains("first_party") || pluginId.hasPrefix("first_party") {
            return .tronEmerald
        }
        return .tronSlate
    }

    static func sourceLabel(for identity: CapabilityIdentity) -> String {
        let trustTier = identity.trustTier?.lowercased() ?? ""
        let pluginId = identity.pluginId?.lowercased() ?? ""

        if trustTier.contains("external_mcp") || pluginId.contains("mcp") {
            return "MCP"
        }
        if trustTier.contains("external_openapi") || pluginId.contains("openapi") {
            return "OpenAPI"
        }
        if trustTier.contains("session_generated") || pluginId.contains("sandbox") {
            return "Session"
        }
        if trustTier.contains("user_installed") {
            return "Installed"
        }
        if trustTier.contains("trusted_signed") {
            return "Trusted"
        }
        if trustTier.contains("first_party") || pluginId.hasPrefix("first_party") {
            return "First-party"
        }
        return "Capability"
    }

    static func pluginLabel(for identity: CapabilityIdentity) -> String? {
        guard let pluginId = identity.pluginId?.nilIfEmpty else { return nil }
        let source = sourceLabel(for: identity)
        let display = pluginDisplayName(pluginId)
        if source == "Capability" {
            return display
        }
        return "\(display) (\(source))"
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

    static func themeColorHex(for identity: CapabilityIdentity, targetId: String? = nil) -> String? {
        identity.themeColor?.nilIfEmpty
            ?? presentationString("themeColor", for: identity)
            ?? targetId.flatMap(themeColorForCapabilityId)
            ?? themeColorForCapabilityNamespace(identity)
    }

    static func presentationString(_ key: String, for identity: CapabilityIdentity) -> String? {
        identity.presentationHints?[key]?.stringValue?.nilIfEmpty
    }

    static func humanizeCapabilityId(_ id: String) -> String {
        if let known = friendlyCapabilityNames[id] {
            return known
        }
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

    private static let friendlyCapabilityNames: [String: String] = [
        "agent::ask_user": "Ask User",
        "agent::cancel_subagent": "Cancel Subagent",
        "agent::spawn_subagent": "Spawn Subagent",
        "agent::submit_answers": "Submit Answers",
        "agent::subagent_result": "Subagent Result",
        "agent::subagent_status": "Subagent Status",
        "capability::execute": "Execute",
        "capability::inspect": "Inspect",
        "capability::search": "Search",
        "display::show": "Display",
        "filesystem::apply_patch": "Apply Patch",
        "filesystem::diff": "Diff Files",
        "filesystem::edit_file": "Edit File",
        "filesystem::find": "Find Files",
        "filesystem::glob": "Glob Files",
        "filesystem::list_dir": "List Directory",
        "filesystem::read_file": "Read File",
        "filesystem::search_text": "Search Text",
        "filesystem::write_file": "Write File",
        "job::cancel": "Cancel Job",
        "job::list": "List Jobs",
        "job::stream_output": "Stream Job Output",
        "job::wait": "Wait For Job",
        "notifications::send": "Send Notification",
        "process::cancel": "Cancel Process",
        "process::run": "Run Command",
        "process::start_job": "Start Background Job",
        "process::stream_output": "Stream Process Output",
        "process::wait": "Wait For Process",
        "sandbox::promote_worker": "Promote Worker",
        "worker::spawn": "Spawn Worker",
        "sandbox::stop_spawned_worker": "Stop Worker",
        "web::fetch": "Fetch Web Page",
        "web::scrape": "Scrape Web Page",
        "web::search": "Search Web"
    ]

    private static func pluginDisplayName(_ pluginId: String) -> String {
        let stripped = pluginId
            .replacingOccurrences(of: "first_party.", with: "")
            .replacingOccurrences(of: "external_mcp.", with: "")
            .replacingOccurrences(of: "external_openapi.", with: "")
            .replacingOccurrences(of: "user_installed.", with: "")
            .replacingOccurrences(of: "session_generated.", with: "")
        if let known = friendlyPluginNames[stripped] {
            return known
        }
        return stripped
            .split(separator: ".")
            .last
            .map(String.init)
            .map(humanizeCapabilityId) ?? humanizeCapabilityId(pluginId)
    }

    private static let friendlyPluginNames: [String: String] = [
        "agent": "Agent",
        "browser": "Browser",
        "capability": "Capabilities",
        "display": "Display",
        "filesystem": "File System",
        "github": "GitHub",
        "job": "Jobs",
        "mcp": "MCP",
        "notifications": "Notifications",
        "process": "Process",
        "sandbox": "Sandbox",
        "web": "Web"
    ]

    private static func colorFromTheme(_ themeColor: String?) -> Color? {
        guard let themeColor = themeColor?.nilIfEmpty else { return nil }
        let hex = themeColor.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard [3, 6, 8].contains(hex.count),
              hex.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
        else {
            return nil
        }
        return Color(hex: themeColor)
    }

    private static func nativeSymbolName(for token: String) -> String? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.contains(".") || normalized == "terminal" || normalized == "globe" {
            return normalized
        }
        switch normalized {
        case "question":
            return "questionmark.circle"
        case "subagent":
            return "person.2"
        case "clock", "wait":
            return "clock"
        case "output":
            return "text.alignleft"
        case "search":
            return "magnifyingglass"
        case "inspect":
            return "info.circle"
        case "execute", "run":
            return "play.circle"
        case "file", "document":
            return "doc.text"
        case "terminal", "process":
            return "terminal"
        default:
            return normalized.contains(" ") ? nil : normalized
        }
    }

    private static func themeColorForCapabilityNamespace(_ identity: CapabilityIdentity) -> String? {
        if let color = identity.contractId.flatMap(themeColorForCapabilityId) {
            return color
        }
        if let color = identity.functionId.flatMap(themeColorForCapabilityId) {
            return color
        }
        if let implementationId = identity.implementationId?.nilIfEmpty {
            let stripped = stripKnownSourcePrefix(implementationId)
            if let namespace = stripped.split(separator: ".").first,
               let color = themeColorForNamespace(String(namespace)) {
                return color
            }
        }
        if let pluginId = identity.pluginId?.nilIfEmpty {
            let stripped = stripKnownSourcePrefix(pluginId)
            if let namespace = stripped.split(separator: ".").first,
               let color = themeColorForNamespace(String(namespace)) {
                return color
            }
        }
        return identity.modelPrimitiveName.flatMap(themeColorForCapabilityId)
    }

    private static func themeColorForCapabilityId(_ id: String) -> String? {
        guard let id = id.nilIfEmpty else { return nil }
        if let namespace = id.split(separator: "::").first {
            return themeColorForNamespace(String(namespace))
        }
        let stripped = stripKnownSourcePrefix(id)
        if let namespace = stripped.split(separator: ".").first {
            return themeColorForNamespace(String(namespace))
        }
        return themeColorForNamespace(id)
    }

    private static func themeColorForNamespace(_ namespace: String) -> String? {
        switch String(namespace) {
        case "capability":
            return "#10B981"
        case "filesystem":
            return "#10B981"
        case "process":
            return "#38BDF8"
        case "web":
            return "#3B82F6"
        case "notifications":
            return "#EC4899"
        case "agent":
            return "#8B5CF6"
        case "job":
            return "#F59E0B"
        case "sandbox":
            return "#A97BFF"
        case "display":
            return "#818CF8"
        case "browser":
            return "#06B6D4"
        case "mcp":
            return "#2DD4BF"
        default:
            return nil
        }
    }

    private static func stripKnownSourcePrefix(_ id: String) -> String {
        id
            .replacingOccurrences(of: "first_party.", with: "")
            .replacingOccurrences(of: "external_mcp.", with: "")
            .replacingOccurrences(of: "external_openapi.", with: "")
            .replacingOccurrences(of: "user_installed.", with: "")
            .replacingOccurrences(of: "session_generated.", with: "")
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
            bindingDecisionId: payload["bindingDecisionId"] as? String,
            themeColor: payload["themeColor"] as? String,
            presentationHints: (payload["presentationHints"] as? [String: Any])?.mapValues { AnyCodable($0) }
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
            bindingDecisionId == nil &&
            themeColor == nil &&
            presentationHints == nil
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
