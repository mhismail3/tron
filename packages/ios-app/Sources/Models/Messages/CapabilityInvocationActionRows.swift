import Foundation

extension CapabilityInvocationDisplayModel {
    static func actionRows(
        data: CapabilityInvocationData,
        arguments: [String: Any],
        target: String?,
        capabilityName: String,
        statusText: String,
        resultPreview: String?
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value))
        }

        let actionTitle = target == nil && CapabilityPresentation.primitiveName(for: data.identity) == "execute"
            ? "Preparing action"
            : capabilityName
        append("What happened", actionTitle)
        append("Why", actionWhyText(from: arguments, identity: data.identity))
        append("Executor", CapabilityPresentation.workerLabel(for: data.identity, targetId: target) ?? "Runtime")
        append("Status", statusText)
        append("Result", actionResultText(data: data, resultPreview: resultPreview))
        return rows
    }

    private static func actionWhyText(from arguments: [String: Any], identity: CapabilityIdentity) -> String {
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

    private static func actionResultText(data: CapabilityInvocationData, resultPreview: String?) -> String {
        switch data.status {
        case .generating:
            return "Preparing"
        case .running:
            return data.progressMessage?.nilIfEmpty?.truncated(to: 160) ?? "In progress"
        case .paused:
            return "Paused"
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
