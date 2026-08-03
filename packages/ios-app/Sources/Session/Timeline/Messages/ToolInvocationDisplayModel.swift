import Foundation

struct ToolDisplayRow: Equatable, Identifiable {
    let label: String
    let value: String
    var isTechnical: Bool = false

    var id: String { "\(label)|\(value)" }
}

struct ToolDisplayGroup: Equatable, Identifiable {
    let title: String
    let rows: [ToolDisplayRow]

    var id: String { title }
}

struct ToolInvocationDisplayModel: Equatable {
    let primitiveTitle: String
    let sheetTitle: String
    let chipTitle: String
    let toolName: String
    let commandText: String
    let summaryText: String
    let statusText: String
    let statusWithDuration: String
    let targetId: String?
    let payloadSummary: String?
    let actionRows: [ToolDisplayRow]
    let progressSteps: [ToolProgressStep]
    let requestRows: [ToolDisplayRow]
    let executionGroups: [ToolDisplayGroup]
    let resultRows: [ToolDisplayRow]
    let resultPreview: String?
    let technicalRows: [ToolDisplayRow]
    let prettyArguments: String?
    let prettyResult: String?

    init(data: ToolInvocationData) {
        let argumentObject = Self.argumentObject(from: data)
        let primitive = ToolPresentation.primitiveName(for: data.identity)
        let target = Self.targetId(for: primitive, identity: data.identity, arguments: argumentObject)
        let targetArguments = Self.targetArguments(from: argumentObject)
        let payloadSummary = Self.payloadSummary(target: target, from: targetArguments ?? argumentObject)
        let toolName = ToolPresentation.title(for: data.identity, targetId: target)
        let query = Self.firstString(["query", "q", "searchQuery"], in: argumentObject)
            ?? Self.firstString(["query"], in: data.details?.rawValues ?? [:])
        let details = data.details?.rawValues ?? [:]
        let outputObject = Self.outputObject(from: data)

        self.primitiveTitle = Self.primitiveTitle(primitive)
        self.chipTitle = Self.chipTitle(
            primitive: primitive,
            toolName: toolName,
            identity: data.identity
        )
        self.sheetTitle = Self.sheetTitle(
            primitive: primitive,
            chipTitle: self.chipTitle,
            toolName: toolName,
            target: target
        )
        self.toolName = toolName
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
            toolName: toolName,
            identity: data.identity
        )
        self.summaryText = Self.summaryText(
            primitive: primitive,
            target: target,
            identity: data.identity,
            toolName: toolName,
            payloadSummary: payloadSummary
        )
        self.progressSteps = Self.progressSteps(
            primitive: primitive,
            data: data,
            target: target,
            toolName: toolName,
            payloadSummary: payloadSummary,
            details: details
        )
        self.requestRows = Self.requestRows(
            primitive: primitive,
            query: query,
            target: target,
            toolName: toolName,
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
        let resultRows = Self.resultRows(
            data: data,
            details: details,
            output: outputObject
        )
        let resultPreview = Self.resultPreview(
            primitive: primitive,
            result: data.result,
            output: outputObject
        )
        self.actionRows = Self.actionRows(
            data: data,
            arguments: argumentObject,
            target: target,
            toolName: toolName,
            statusText: self.statusWithDuration,
            resultPreview: resultPreview
        )
        self.resultRows = resultRows
        self.resultPreview = resultPreview
        self.technicalRows = Self.technicalRows(data: data)
        self.prettyArguments = Self.prettyJSONString(data.arguments) ?? data.arguments.nilIfEmpty
        self.prettyResult = data.result.flatMap(Self.prettyJSONString) ?? data.result?.nilIfEmpty
    }

    private static func primitiveTitle(_ primitive: String) -> String {
        ToolPresentation.humanizeToolId(primitive)
    }

    private static func chipTitle(
        primitive: String,
        toolName: String,
        identity: ToolIdentity
    ) -> String {
        if let chipTitle = ToolPresentation.presentationString("chipTitle", for: identity) {
            return chipTitle
        }
        return toolName.nilIfEmpty ?? primitiveTitle(primitive)
    }

    private static func sheetTitle(
        primitive: String,
        chipTitle: String,
        toolName: String,
        target: String?
    ) -> String {
        chipTitle.nilIfEmpty ?? toolName.nilIfEmpty ?? primitiveTitle(primitive)
    }

    private static func statusText(
        _ status: ToolInvocationStatus,
        identity: ToolIdentity
    ) -> String {
        if let label = presentationString(statusHintKeys(for: status), for: identity) {
            return label
        }
        switch status {
        case .generating: return "Preparing"
        case .running: return "Running"
        case .success: return "Completed"
        case .error: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }

    private static func statusHintKeys(for status: ToolInvocationStatus) -> [String] {
        switch status {
        case .generating:
            return ["generatingLabel", "progressLabel", "statusLabel"]
        case .running:
            return ["runningLabel", "progressLabel", "statusLabel"]
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
        toolName: String,
        identity: ToolIdentity
    ) -> String {
        if let summary = presentationString(["summary", "subtitle", "commandText"], for: identity) {
            return summary.truncated(to: 140)
        }
        if let payloadSummary {
            return payloadSummary.truncated(to: 140)
        }
        if let query = query?.nilIfEmpty {
            return query.truncated(to: 96)
        }
        if let target, target != toolName {
            return ToolPresentation.humanizeToolId(target).truncated(to: 120)
        }
        return "Invocation"
    }

    private static func summaryText(
        primitive: String,
        target: String?,
        identity: ToolIdentity,
        toolName: String,
        payloadSummary: String?
    ) -> String {
        if let summary = presentationString(["summary", "subtitle"], for: identity) {
            return summary.truncated(to: 160)
        }

        var parts = [payloadSummary ?? toolName]
        if let target = target?.nilIfEmpty {
            parts.append(ToolPresentation.humanizeToolId(target))
        }
        return parts.joined(separator: " · ").truncated(to: 160)
    }

    static func presentationString(_ keys: [String], for identity: ToolIdentity) -> String? {
        for key in keys {
            if let value = ToolPresentation.presentationString(key, for: identity) {
                return value
            }
        }
        return nil
    }

    private static func targetId(
        for primitive: String,
        identity: ToolIdentity,
        arguments: [String: Any]
    ) -> String? {
        if let target = targetHint(from: arguments)?.nilIfEmpty {
            return target
        }

        let argumentTarget = firstString(["operation", "action", "target", "name"], in: arguments)
        if let argumentTarget = argumentTarget?.nilIfEmpty {
            return argumentTarget
        }

        return nil
    }

    private static func targetHint(from object: [String: Any]) -> String? {
        if let target = object["target"] as? String, let value = target.nilIfEmpty {
            return value
        }
        if let target = object["target"] as? [String: Any] {
            return firstString(["operation", "action", "name"], in: target)
        }
        return nil
    }

    static func targetArguments(from object: [String: Any]) -> [String: Any]? {
        if let arguments = object["arguments"] as? [String: Any] {
            return arguments
        }
        if let payload = object["payload"] as? [String: Any] {
            return payload
        }
        return nil
    }

    private static func payloadSummary(target: String?, from object: [String: Any]) -> String? {
        if let command = commandString(["command", "cmd", "shellCommand"], in: object)?.nilIfEmpty {
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
        if let path = firstString(["workspacePath", "path", "filePath", "cwd"], in: object)?.nilIfEmpty {
            return compactPathLabel(path).truncated(to: 80)
        }
        if let code = firstString(["code"], in: object)?.nilIfEmpty {
            let firstLine = code.lines.first?.trimmed.nilIfEmpty ?? "program"
            return firstLine.truncated(to: 96)
        }

        let simplePairs = object
            .filter { key, value in
                !["payload"].contains(key)
                    && !technicalSummaryKeys.contains(key)
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
}
