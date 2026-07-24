import Foundation

struct ToolInvocationBriefPresentation: Equatable {
    struct Issue: Equatable {
        let title: String
        let message: String
        let nextStep: String?
        let rows: [ToolDisplayRow]
    }

    let title: String
    let subtitle: String?
    let headline: String
    let narrative: String
    let factRows: [ToolDisplayRow]
    let requestRows: [ToolDisplayRow]
    let resultRows: [ToolDisplayRow]
    let resultBody: String?
    let issue: Issue?
    let evidenceRows: [ToolDisplayRow]
    let technicalRows: [ToolDisplayRow]
    let rawRequest: String?
    let rawResult: String?
    let rawPayload: String?
    let backgroundInvocationId: String?

    var isBackgroundHandoff: Bool { backgroundInvocationId != nil }

    init(data: ToolInvocationData) {
        let display = data.display
        let evidence = ToolEvidencePresentation(data: data)
        let title = evidence.title
        let issue = Self.issue(from: data, display: display, title: title)
        let resultBody = Self.resultBody(from: data, display: display)
        let requestRows = Self.requestRows(from: data, display: display)
        let resultRows = Self.resultRows(from: display)
        let evidenceRows = Self.evidenceRows(from: data, display: display)
        let subtitle = Self.subtitle(from: evidence, issue: issue, resultBody: resultBody)
        let backgroundInvocationId = Self.backgroundInvocationId(from: data.result)

        self.title = title
        self.subtitle = subtitle
        self.headline = Self.headline(
            for: data.status,
            title: title,
            issue: issue,
            backgroundInvocationId: backgroundInvocationId
        )
        self.narrative = Self.narrative(
            for: data,
            title: title,
            issue: issue,
            backgroundInvocationId: backgroundInvocationId
        )
        self.factRows = Self.factRows(
            from: data,
            display: display,
            backgroundInvocationId: backgroundInvocationId
        )
        self.requestRows = requestRows
        self.resultRows = resultRows
        self.resultBody = resultBody
        self.issue = issue
        self.evidenceRows = evidenceRows
        self.technicalRows = display.technicalRows
        self.rawRequest = display.prettyArguments
        self.rawResult = display.prettyResult
        self.rawPayload = [self.rawRequest, self.rawResult]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: "\n\n")
            .nilIfEmpty
        self.backgroundInvocationId = backgroundInvocationId
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

    private static func subtitle(
        from evidence: ToolEvidencePresentation,
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
        for status: ToolInvocationStatus,
        title: String,
        issue: Issue?,
        backgroundInvocationId: String?
    ) -> String {
        if backgroundInvocationId != nil {
            return "\(title) is continuing in the background"
        }
        switch status {
        case .generating, .running:
            return "\(title) is running"
        case .success:
            return "\(title) completed"
        case .error, .unavailable:
            return issue?.title ?? "\(title) needs attention"
        }
    }

    private static func narrative(
        for data: ToolInvocationData,
        title: String,
        issue: Issue?,
        backgroundInvocationId: String?
    ) -> String {
        if let issue {
            if let nextStep = issue.nextStep {
                return "\(issue.title). \(nextStep)"
            }
            return issue.title
        }
        if backgroundInvocationId != nil {
            return "\(title) was durably handed off after the foreground grace period. The conversation can continue now; current status, nested work, cancellation, and the eventual result remain available in Session Context."
        }
        switch data.status {
        case .generating, .running:
            switch ToolInvocationSurface(identity: data.identity) {
            case .worker(let worker) where worker.runnerKind == "agent":
                return "\(title) is working in a durable agent session. Live engine updates appear below until its typed result is ready."
            case .worker:
                return "\(title) is running as a durable worker. Live engine updates appear below until its typed result is ready."
            case .core:
                return "Tron is using the \(title) core primitive. Live execution evidence appears below until it finishes."
            case .unknown:
                return "Tron is using \(title). Live execution evidence appears below until it finishes."
            }
        case .success:
            switch ToolInvocationSurface(identity: data.identity) {
            case .worker:
                return "\(title) completed and returned a schema-validated worker result."
            case .core:
                return "Tron completed the \(title) core operation."
            case .unknown:
                return "Tron completed \(title) successfully."
            }
        case .error, .unavailable:
            return "\(title) did not complete. Open the issue and evidence sections for the safe failure details."
        }
    }

    private static func factRows(
        from data: ToolInvocationData,
        display: ToolInvocationDisplayModel,
        backgroundInvocationId: String?
    ) -> [ToolDisplayRow] {
        var rows = [
            ToolDisplayRow(
                label: "Status",
                value: backgroundInvocationId == nil ? display.statusText : "Background"
            ),
            ToolDisplayRow(
                label: "Type",
                value: ToolInvocationSurface(identity: data.identity).displayKind
            )
        ]
        if let backgroundInvocationId {
            rows.append(
                ToolDisplayRow(
                    label: "Durable run",
                    value: abbreviatedIdentifier(backgroundInvocationId)
                )
            )
        }
        if let duration = data.formattedDuration {
            rows.append(
                ToolDisplayRow(
                    label: backgroundInvocationId == nil ? "Duration" : "Foreground wait",
                    value: duration
                )
            )
        }
        return rows
    }

    private static func backgroundInvocationId(from result: String?) -> String? {
        guard let result,
              let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "worker_invocation_receipt",
              object["mode"] as? String == "background",
              let status = object["status"] as? String,
              status == "queued" || status == "running"
        else {
            return nil
        }
        return (object["invocationId"] as? String)?.nilIfEmpty
    }

    private static func abbreviatedIdentifier(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(10))…\(value.suffix(4))"
    }

    private static func requestRows(
        from data: ToolInvocationData,
        display: ToolInvocationDisplayModel
    ) -> [ToolDisplayRow] {
        var rows: [ToolDisplayRow] = display.requestRows.filter {
            !$0.isTechnical && !["Target", "Operation", "Action"].contains($0.label)
        }
        if let target = display.targetId?.nilIfEmpty {
            rows.insert(
                ToolDisplayRow(
                    label: "Action",
                    value: ToolPresentation.humanizeToolId(target)
                ),
                at: 0
            )
        }
        return deduplicate(rows)
            .map { row in ToolDisplayRow(label: row.label, value: safeTopLevelText(row.value, limit: 180)) }
            .filter { !$0.value.isEmpty }
            .prefixArray(6)
    }

    private static func resultRows(from display: ToolInvocationDisplayModel) -> [ToolDisplayRow] {
        display.resultRows
            .filter { !$0.isTechnical }
            .map { row in ToolDisplayRow(label: row.label, value: safeTopLevelText(row.value, limit: 180)) }
            .prefixArray(5)
    }

    private static func resultBody(
        from data: ToolInvocationData,
        display: ToolInvocationDisplayModel
    ) -> String? {
        guard data.status != .error, data.errorClassification == nil else { return nil }
        guard let body = (display.resultPreview ?? data.result)?.nilIfEmpty else { return nil }
        if backgroundInvocationId(from: data.result) != nil,
           let data = data.result?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return safeBodyText(message, limit: 900).nilIfEmpty
        }
        return safeBodyText(body, limit: 900).nilIfEmpty
    }

    private static func issue(
        from data: ToolInvocationData,
        display: ToolInvocationDisplayModel,
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
        var rows: [ToolDisplayRow] = []
        if let category = error?.category?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Category", value: safeTopLevelText(category, limit: 80)))
        }
        if let recoverable = error?.recoverable {
            rows.append(ToolDisplayRow(label: "Recoverable", value: recoverable ? "Yes" : "No"))
        }
        if let code = error?.code?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Code", value: safeTopLevelText(code, limit: 96)))
        }
        return Issue(
            title: issueTitle(error: error, message: rawMessage, defaultTitle: title),
            message: message,
            nextStep: nextStep(error: error, message: rawMessage),
            rows: rows
        )
    }

    private static func issueTitle(
        error: ToolErrorClassification?,
        message: String,
        defaultTitle: String
    ) -> String {
        let lowered = [error?.code, error?.category, message].compactMap { $0 }.joined(separator: " ").lowercased()
        if lowered.contains("policy") {
            return "Policy blocked this request"
        }
        if lowered.contains("schema") || lowered.contains("invalid") {
            return "Request shape needs correction"
        }
        return "\(defaultTitle) failed"
    }

    private static func nextStep(error: ToolErrorClassification?, message: String) -> String? {
        if let selector = explicitSelector(from: message) {
            return "Retry with the explicit \(selector) selector."
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
        from data: ToolInvocationData,
        display: ToolInvocationDisplayModel
    ) -> [ToolDisplayRow] {
        var rows: [ToolDisplayRow] = []
        if let status = display.technicalRows.first(where: { $0.label == "Engine status" })?.value.nilIfEmpty {
            let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized != "ok" {
                rows.append(ToolDisplayRow(label: "Engine status", value: status))
            }
        }
        if let trace = data.identity.traceId?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Trace ref", value: compactRef(trace), isTechnical: true))
        }
        if let root = data.identity.rootInvocationId?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Root ref", value: compactRef(root), isTechnical: true))
        }
        return rows
    }

    private static func compactRef(_ ref: String) -> String {
        guard ref.count > 16 else { return ref }
        return "\(ref.prefix(8))…\(ref.suffix(4))"
    }

    private static func deduplicate(_ rows: [ToolDisplayRow]) -> [ToolDisplayRow] {
        var seen = Set<String>()
        return rows.filter { row in
            let key = "\(row.label)|\(row.value)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

private extension Array where Element == ToolDisplayRow {
    func prefixArray(_ maxCount: Int) -> [ToolDisplayRow] {
        Array(prefix(maxCount))
    }
}
