import Foundation

struct CapabilityInvocationBriefPresentation: Equatable {
    enum Tone: Equatable {
        case active
        case success
        case attention
        case neutral
    }

    struct Issue: Equatable {
        let title: String
        let message: String
        let nextStep: String?
        let rows: [CapabilityDisplayRow]
    }

    let title: String
    let subtitle: String?
    let tone: Tone
    let headline: String
    let narrative: String
    let factRows: [CapabilityDisplayRow]
    let requestRows: [CapabilityDisplayRow]
    let resultRows: [CapabilityDisplayRow]
    let resultBody: String?
    let issue: Issue?
    let evidenceRows: [CapabilityDisplayRow]
    let technicalRows: [CapabilityDisplayRow]
    let rawPayload: String?

    init(data: CapabilityInvocationData) {
        let display = data.display
        let evidence = CapabilityEvidencePresentation(data: data)
        let title = evidence.title
        let issue = Self.issue(from: data, display: display, title: title)
        let resultBody = Self.resultBody(from: data, display: display)
        let requestRows = Self.requestRows(from: data, display: display)
        let resultRows = Self.resultRows(from: display)
        let evidenceRows = Self.evidenceRows(from: data, display: display)
        let tone = Self.tone(for: data.status)
        let subtitle = Self.subtitle(from: evidence, issue: issue, resultBody: resultBody)

        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.headline = Self.headline(for: data.status, title: title, issue: issue)
        self.narrative = Self.narrative(for: data, title: title, issue: issue, resultBody: resultBody)
        self.factRows = Self.factRows(from: data, display: display)
        self.requestRows = requestRows
        self.resultRows = resultRows
        self.resultBody = resultBody
        self.issue = issue
        self.evidenceRows = evidenceRows
        self.technicalRows = display.technicalRows
        self.rawPayload = [display.prettyArguments, display.prettyResult]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: "\n\n")
            .nilIfEmpty
    }

    static func redactSensitiveIdentifiers(_ text: String) -> String {
        var output = text
        let patterns = [
            #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
            #"\bcall_[A-Za-z0-9_-]{8,}\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "[id]")
        }
        return output
    }

    static func safeTopLevelText(_ text: String, limit: Int = 260) -> String {
        redactSensitiveIdentifiers(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmed
            .truncated(to: limit)
    }

    static func safeBodyText(_ text: String, limit: Int = 900) -> String {
        redactSensitiveIdentifiers(text)
            .trimmed
            .truncated(to: limit)
    }

    private static func tone(for status: CapabilityInvocationStatus) -> Tone {
        switch status {
        case .generating, .running:
            return .active
        case .success:
            return .success
        case .error, .unavailable:
            return .attention
        case .paused:
            return .neutral
        }
    }

    private static func subtitle(
        from evidence: CapabilityEvidencePresentation,
        issue: Issue?,
        resultBody: String?
    ) -> String? {
        if let issue {
            return issue.message.truncated(to: 96)
        }
        if let qualifier = evidence.qualifier?.nilIfEmpty {
            return safeTopLevelText(qualifier, limit: 96)
        }
        return resultBody?.lines.first?.trimmed.nilIfEmpty.map { safeTopLevelText($0, limit: 96) }
    }

    private static func headline(
        for status: CapabilityInvocationStatus,
        title: String,
        issue: Issue?
    ) -> String {
        switch status {
        case .generating, .running:
            return "\(title) is running"
        case .paused:
            return "\(title) is paused"
        case .success:
            return "\(title) completed"
        case .error, .unavailable:
            return issue?.title ?? "\(title) needs attention"
        }
    }

    private static func narrative(
        for data: CapabilityInvocationData,
        title: String,
        issue: Issue?,
        resultBody: String?
    ) -> String {
        if let issue {
            if let nextStep = issue.nextStep {
                return "\(issue.title). \(nextStep)"
            }
            return issue.title
        }
        switch data.status {
        case .generating, .running:
            return "Tron is using \(title) and will attach the result when the engine finishes."
        case .paused:
            return "Tron paused \(title). Open evidence for the latest recorded state."
        case .success:
            if let result = resultBody?.lines.first?.trimmed.nilIfEmpty {
                return "Tron completed \(title) and returned: \(safeTopLevelText(result, limit: 180))"
            }
            return "Tron completed \(title) and recorded engine evidence for this invocation."
        case .error, .unavailable:
            return "\(title) did not complete. Open the issue and evidence sections for the safe failure details."
        }
    }

    private static func factRows(
        from data: CapabilityInvocationData,
        display: CapabilityInvocationDisplayModel
    ) -> [CapabilityDisplayRow] {
        var rows = [
            CapabilityDisplayRow(label: "Status", value: display.statusText)
        ]
        if let duration = data.formattedDuration {
            rows.append(CapabilityDisplayRow(label: "Duration", value: duration))
        }
        return rows
    }

    private static func requestRows(
        from data: CapabilityInvocationData,
        display: CapabilityInvocationDisplayModel
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        if let operation = data.identity.operationName?.nilIfEmpty ?? display.targetId?.nilIfEmpty {
            rows.append(CapabilityDisplayRow(label: "Operation", value: operation))
        }
        rows.append(contentsOf: display.requestRows.filter { !$0.isTechnical && $0.label != "Operation" })
        return deduplicate(rows)
            .map { row in CapabilityDisplayRow(label: row.label, value: safeTopLevelText(row.value, limit: 180)) }
            .filter { !$0.value.isEmpty }
            .prefixArray(6)
    }

    private static func resultRows(from display: CapabilityInvocationDisplayModel) -> [CapabilityDisplayRow] {
        display.resultRows
            .filter { !$0.isTechnical }
            .map { row in CapabilityDisplayRow(label: row.label, value: safeTopLevelText(row.value, limit: 180)) }
            .prefixArray(5)
    }

    private static func resultBody(
        from data: CapabilityInvocationData,
        display: CapabilityInvocationDisplayModel
    ) -> String? {
        guard data.status != .error, data.errorClassification == nil else { return nil }
        guard let body = (display.resultPreview ?? data.result)?.nilIfEmpty else { return nil }
        return safeBodyText(body, limit: 900).nilIfEmpty
    }

    private static func issue(
        from data: CapabilityInvocationData,
        display: CapabilityInvocationDisplayModel,
        title: String
    ) -> Issue? {
        guard data.status == .error || data.status == .unavailable || data.errorClassification != nil else {
            return nil
        }
        let error = data.errorClassification
        let rawMessage = error?.message?.nilIfEmpty
            ?? display.resultPreview?.lines.first?.trimmed.nilIfEmpty
            ?? data.result?.lines.first?.trimmed.nilIfEmpty
            ?? "\(title) failed."
        let message = safeTopLevelText(rawMessage, limit: 260)
        var rows: [CapabilityDisplayRow] = []
        if let category = error?.category?.nilIfEmpty {
            rows.append(CapabilityDisplayRow(label: "Category", value: safeTopLevelText(category, limit: 80)))
        }
        if let recoverable = error?.recoverable {
            rows.append(CapabilityDisplayRow(label: "Recoverable", value: recoverable ? "Yes" : "No"))
        }
        if let code = error?.code?.nilIfEmpty {
            rows.append(CapabilityDisplayRow(label: "Code", value: safeTopLevelText(code, limit: 96)))
        }
        return Issue(
            title: issueTitle(error: error, message: rawMessage, defaultTitle: title),
            message: message,
            nextStep: nextStep(error: error, message: rawMessage),
            rows: rows
        )
    }

    private static func issueTitle(
        error: CapabilityErrorClassification?,
        message: String,
        defaultTitle: String
    ) -> String {
        let lowered = [error?.code, error?.category, message].compactMap { $0 }.joined(separator: " ").lowercased()
        if lowered.contains("policy") || lowered.contains("authority") || lowered.contains("grant") {
            return "Policy blocked this request"
        }
        if lowered.contains("schema") || lowered.contains("invalid") {
            return "Request shape needs correction"
        }
        return "\(defaultTitle) failed"
    }

    private static func nextStep(error: CapabilityErrorClassification?, message: String) -> String? {
        let lowered = message.lowercased()
        if let selector = explicitSelector(from: message) {
            return "Retry with the explicit \(selector) selector."
        }
        if lowered.contains("authority") || lowered.contains("grant") {
            return "Use the required scoped authority before retrying."
        }
        if error?.recoverable == true {
            return "This is recoverable after correcting the request."
        }
        return nil
    }

    private static func explicitSelector(from message: String) -> String? {
        guard let range = message.range(of: "kind:") else { return nil }
        let suffix = message[range.upperBound...]
        let token = suffix
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." || $0 == ";" })
            .first
            .map(String.init)?
            .replacingOccurrences(of: "selector", with: "")
            .trimmed
        return token?.nilIfEmpty
    }

    private static func evidenceRows(
        from data: CapabilityInvocationData,
        display: CapabilityInvocationDisplayModel
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        if let status = display.technicalRows.first(where: { $0.label == "Engine status" })?.value.nilIfEmpty {
            let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized != "ok" {
                rows.append(CapabilityDisplayRow(label: "Engine status", value: status))
            }
        }
        if let trace = data.identity.traceId?.nilIfEmpty {
            rows.append(CapabilityDisplayRow(label: "Trace ref", value: compactRef(trace), isTechnical: true))
        }
        if let root = data.identity.rootInvocationId?.nilIfEmpty {
            rows.append(CapabilityDisplayRow(label: "Root ref", value: compactRef(root), isTechnical: true))
        }
        return rows
    }

    private static func compactRef(_ ref: String) -> String {
        guard ref.count > 16 else { return ref }
        return "\(ref.prefix(8))…\(ref.suffix(4))"
    }

    private static func deduplicate(_ rows: [CapabilityDisplayRow]) -> [CapabilityDisplayRow] {
        var seen = Set<String>()
        return rows.filter { row in
            let key = "\(row.label)|\(row.value)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

private extension Array where Element == CapabilityDisplayRow {
    func prefixArray(_ maxCount: Int) -> [CapabilityDisplayRow] {
        Array(prefix(maxCount))
    }
}
