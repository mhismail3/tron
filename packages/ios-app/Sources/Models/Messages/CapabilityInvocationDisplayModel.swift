import Foundation
import SwiftUI

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
    let sheetTitle: String
    let chipTitle: String
    let capabilityName: String
    let commandText: String
    let summaryText: String
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
        self.sheetTitle = Self.sheetTitle(
            primitive: primitive,
            chipTitle: self.chipTitle,
            capabilityName: capabilityName,
            target: target
        )
        self.capabilityName = capabilityName
        self.targetId = target
        self.payloadSummary = payloadSummary
        self.statusText = Self.statusText(data.status, identity: data.identity)
        self.statusWithDuration = [self.statusText, data.formattedDuration]
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
        self.summaryText = Self.summaryText(
            primitive: primitive,
            target: target,
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

    private static func sheetTitle(
        primitive: String,
        chipTitle: String,
        capabilityName: String,
        target: String?
    ) -> String {
        guard primitive == "execute", target != nil else {
            return primitiveTitle(primitive)
        }
        return chipTitle.nilIfEmpty ?? capabilityName.nilIfEmpty ?? "Execute"
    }

    private static func statusText(
        _ status: CapabilityInvocationStatus,
        identity: CapabilityIdentity
    ) -> String {
        if let label = presentationString(statusHintKeys(for: status), for: identity) {
            return label
        }
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

    private static func statusHintKeys(for status: CapabilityInvocationStatus) -> [String] {
        switch status {
        case .generating:
            return ["generatingLabel", "progressLabel", "statusLabel"]
        case .running:
            return ["runningLabel", "progressLabel", "statusLabel"]
        case .paused:
            return ["pausedLabel", "statusLabel"]
        case .approvalRequired:
            return ["approvalLabel", "statusLabel"]
        case .success:
            return ["successLabel", "statusLabel"]
        case .error:
            return ["failureLabel", "errorLabel", "statusLabel"]
        case .unavailable:
            return ["unavailableLabel", "statusLabel"]
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
        if let summary = presentationString(["summary", "subtitle", "commandText"], for: identity) {
            return summary.truncated(to: 140)
        }
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

    private static func summaryText(
        primitive: String,
        target: String?,
        identity: CapabilityIdentity
    ) -> String {
        if let summary = presentationString(["summary", "subtitle"], for: identity) {
            return summary.truncated(to: 160)
        }

        var parts = [primitiveTitle(primitive)]
        if let target = target?.nilIfEmpty {
            parts.append(target)
        }
        return parts.joined(separator: " via ")
    }

    private static func presentationString(_ keys: [String], for identity: CapabilityIdentity) -> String? {
        for key in keys {
            if let value = CapabilityPresentation.presentationString(key, for: identity) {
                return value
            }
        }
        return nil
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
        appendRow("Status", statusText(data.status, identity: data.identity), to: &run)
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

private extension Dictionary where Key == String, Value == AnyCodable {
    var rawValues: [String: Any] {
        mapValues(\.value)
    }
}
