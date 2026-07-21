import Foundation

extension ToolInvocationDisplayModel {
    static func actionRows(
        data: ToolInvocationData,
        arguments: [String: Any],
        target: String?,
        toolName: String,
        statusText: String,
        resultPreview: String?
    ) -> [ToolDisplayRow] {
        var rows: [ToolDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(ToolDisplayRow(label: label, value: value))
        }

        append("What happened", toolName)
        append("Why", actionWhyText(from: arguments, identity: data.identity))
        append("Trace", data.identity.traceId.map { String($0.prefix(12)) })
        append("Status", statusText)
        append("Result", actionResultText(data: data, resultPreview: resultPreview))
        return rows
    }

    private static func actionWhyText(from arguments: [String: Any], identity: ToolIdentity) -> String {
        if let why = presentationString(["why", "reason", "intent"], for: identity) {
            return why.truncated(to: 180)
        }
        if let reason = firstString(["reason", "intent", "why"], in: arguments)?.nilIfEmpty {
            return reason.truncated(to: 180)
        }
        if let nested = targetArguments(from: arguments),
           let reason = firstString(["reason", "intent", "why"], in: nested)?.nilIfEmpty {
            return reason.truncated(to: 180)
        }
        return "Agent selected the next action."
    }

    private static func actionResultText(data: ToolInvocationData, resultPreview: String?) -> String {
        switch data.status {
        case .generating:
            return "Preparing"
        case .running:
            return data.progressMessage?.nilIfEmpty?.truncated(to: 160) ?? "In progress"
        case .unavailable:
            return "Unavailable"
        case .error:
            return data.errorClassification?.message?.nilIfEmpty?.truncated(to: 160)
                ?? resultPreview?.firstMeaningfulLine.truncated(to: 160)
                ?? "Failed"
        case .success:
            return resultPreview?.firstMeaningfulLine.truncated(to: 160)
                ?? data.result?.nilIfEmpty?.firstMeaningfulLine.truncated(to: 160)
                ?? "Completed"
        }
    }
}

private extension String {
    var firstMeaningfulLine: String {
        lines
            .map(\.trimmed)
            .first { !$0.isEmpty } ?? trimmed
    }
}
