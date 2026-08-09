import Foundation

enum WorkerConsoleStatusKind: Equatable, Sendable {
    case healthy
    case paused
    case retired
    case needsAttention
}

struct WorkerConsoleStatus: Equatable, Sendable {
    let kind: WorkerConsoleStatusKind
    let title: String
    let detail: String
    let systemImage: String
}

struct WorkerInputFieldPresentation: Equatable, Identifiable, Sendable {
    let name: String
    let type: String
    let isRequired: Bool
    let detail: String?

    var id: String { name }
}

struct WorkerProvenancePresentation: Equatable, Identifiable, Sendable {
    let source: String
    let revision: String?

    var id: String { "\(source):\(revision ?? "")" }

    var compactLabel: String {
        let sourceTail = source
            .split(whereSeparator: { ":/".contains($0) })
            .last
            .map(String.init) ?? source
        let shortSource = WorkerConsolePresentation.compactText(sourceTail, maxLength: 18)
        guard let revision, !revision.isEmpty else { return shortSource }
        return "\(shortSource) · \(WorkerConsolePresentation.compactText(revision, maxLength: 8))"
    }

    var fullLabel: String {
        revision.map { "\(source) · \($0)" } ?? source
    }
}

enum WorkerResultDisposition: Equatable, Sendable {
    case available
    case usedByAgent
    case needsAttention
    case resolved

    var title: String {
        switch self {
        case .available: "Available"
        case .usedByAgent: "Used by agent"
        case .needsAttention: "Needs attention"
        case .resolved: "Resolved"
        }
    }
}

/// Human-readable projection for the Worker Console. The server remains the
/// owner of worker facts; this type only converts protocol vocabulary and
/// extensible JSON into the compact presentation used by iOS.
enum WorkerConsolePresentation {
    static func status(for worker: WorkerSummaryDTO) -> WorkerConsoleStatus {
        if worker.retired {
            return WorkerConsoleStatus(
                kind: .retired,
                title: "Retired",
                detail: "Stored safely and no longer receiving work",
                systemImage: "archivebox"
            )
        }
        if !worker.enabled {
            return WorkerConsoleStatus(
                kind: .paused,
                title: "Disabled",
                detail: "Durable state is retained; new work is paused",
                systemImage: "pause.circle"
            )
        }
        if normalized(worker.health) == "healthy" {
            return WorkerConsoleStatus(
                kind: .healthy,
                title: "Healthy",
                detail: "Enabled and ready to receive work",
                systemImage: "bolt.circle.fill"
            )
        }
        return WorkerConsoleStatus(
            kind: .needsAttention,
            title: displayLabel(worker.health),
            detail: "Open this worker to review runs and durable results",
            systemImage: "exclamationmark.triangle"
        )
    }

    static func compactIdentifier(_ value: String, length: Int = 10) -> String {
        guard value.count > length else { return value }
        return String(value.prefix(length))
    }

    static func compactRunIdentifier(_ value: String, length: Int = 8) -> String {
        guard value.count > length else { return value }
        return "…\(value.suffix(length))"
    }

    static func compactText(_ value: String, maxLength: Int = 80) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maxLength, maxLength > 1 else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }

    static func runnerLabel(_ value: String) -> String {
        switch normalized(value) {
        case "agent": "Agent runner"
        case "command": "Command runner"
        case "service", "residentservice": "Service runner"
        default: "\(displayLabel(value)) runner"
        }
    }

    static func triggerLabel(_ count: UInt64) -> String {
        "\(count) trigger\(count == 1 ? "" : "s")"
    }

    static func completedRunLabel(_ count: UInt64) -> String {
        "\(count) successful run\(count == 1 ? "" : "s")"
    }

    static func runSummary(_ run: WorkerInvocationDTO) -> String? {
        summaryValue(
            from: run.input,
            preferredKeys: ["task", "question", "query", "request", "prompt", "topic", "action", "title"]
        )
    }

    static func runResultSummary(_ run: WorkerInvocationDTO) -> String? {
        if let reference = run.output?.reference {
            let preview = reference.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                return WorkerRunGraphPresentation.resultPresentation(preview).summary
            }
            let message = reference.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : compactText(message, maxLength: 640)
        }
        guard let output = run.output?.legacyInline else { return nil }
        return summaryValue(
            from: output,
            preferredKeys: ["summary", "message", "result", "status", "error"]
        )
    }

    static func runInvocationSource(
        _ run: WorkerInvocationDTO,
        callerWorkerName: String? = nil
    ) -> String {
        if run.parentWorkerInvocationId != nil {
            return callerWorkerName.map { "Worker · \($0)" } ?? "Worker dispatch"
        }

        if run.triggerKind.hasPrefix("engine_hook:") {
            let hook = String(run.triggerKind.dropFirst("engine_hook:".count))
            return "Engine · \(displayLabel(hook))"
        }

        switch normalized(run.triggerKind) {
        case "manual":
            if run.modelToolInvocationId != nil {
                return "Agent tool call"
            }
            return run.originSessionId == nil ? "Worker Console" : "Agent session"
        case "workerdispatch":
            return callerWorkerName.map { "Worker · \($0)" } ?? "Worker dispatch"
        case "schedule":
            return "Schedule"
        case "selfwakeup":
            return "Worker self wake-up"
        case "engineevent":
            return "Engine event"
        case "webhook":
            return "Webhook"
        case "stream":
            return "Event stream"
        default:
            return displayLabel(run.triggerKind)
        }
    }

    static func runInteractionMode(_ run: WorkerInvocationDTO) -> String {
        switch normalized(run.interactionMode ?? "foreground") {
        case "background": "Background"
        case "foreground": "Foreground"
        default: displayLabel(run.interactionMode ?? "foreground")
        }
    }

    static func runAttemptLabel(_ run: WorkerInvocationDTO) -> String {
        "\(run.attemptCount) attempt\(run.attemptCount == 1 ? "" : "s")"
    }

    static func runCompactMetadata(
        _ run: WorkerInvocationDTO,
        callerWorkerName: String? = nil
    ) -> String {
        var parts = [
            runInvocationSource(run, callerWorkerName: callerWorkerName),
        ]
        if normalized(run.triggerKind) == "manual" {
            parts.append("Manual")
        }
        parts.append(runInteractionMode(run))
        if run.attemptCount > 1 {
            parts.append(runAttemptLabel(run))
        }
        return parts.joined(separator: " · ")
    }

    static func inboxSummary(_ item: WorkerInboxItemDTO) -> String {
        if let receipt = item.result.receipt {
            return compactText(
                receipt.preview.isEmpty ? receipt.reference.preview : receipt.preview,
                maxLength: 120
            )
        }
        return item.result.legacyInline.flatMap {
            summaryValue(
                from: $0,
                preferredKeys: ["error", "message", "summary", "status", "question", "task"]
            )
        } ?? (normalized(item.severity) == "error"
            ? "Worker execution failed"
            : "Durable worker result")
    }

    /// Human-readable lifecycle derived only from canonical inbox fields.
    /// Opening a result does not mutate this status; `contextAttached` means
    /// the result entered agent context, while `requiresAttention` already
    /// accounts for verified recovery of an earlier failure.
    static func resultDisposition(_ item: WorkerInboxItemDTO) -> WorkerResultDisposition {
        if item.requiresAttention {
            return .needsAttention
        }
        if normalized(item.severity) == "error" {
            return .resolved
        }
        if item.contextAttached {
            return .usedByAgent
        }
        return .available
    }

    static func timestamp(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let withoutFraction = value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value
        let core = String(withoutFraction.prefix(16))
        return core.replacingOccurrences(of: "T", with: " · ")
    }

    static func displayLabel(_ value: String) -> String {
        var separated = ""
        var previous: Character?
        for character in value {
            if let previous,
               character.isUppercase,
               previous.isLowercase || previous.isNumber {
                separated.append(" ")
            }
            separated.append(character)
            previous = character
        }
        return separated
            .replacingOccurrences(of: "::", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    static func schemaFields(from schema: AnyCodable?) -> [WorkerInputFieldPresentation] {
        guard let root = schema?.dictionaryValue,
              let properties = AnyCodable(root["properties"]).dictionaryValue else {
            return []
        }
        let required = Set(AnyCodable(root["required"]).arrayValue?.compactMap { $0 as? String } ?? [])
        return properties.keys.sorted().map { name in
            let definition = AnyCodable(properties[name]).dictionaryValue ?? [:]
            return WorkerInputFieldPresentation(
                name: name,
                type: definition["type"] as? String ?? "value",
                isRequired: required.contains(name),
                detail: definition["description"] as? String
            )
        }
    }

    static func provenance(from value: AnyCodable?) -> [WorkerProvenancePresentation] {
        guard let value else { return [] }
        let entries: [[String: Any]]
        if let array = value.arrayValue {
            entries = array.compactMap { AnyCodable($0).dictionaryValue }
        } else if let dictionary = value.dictionaryValue {
            entries = [dictionary]
        } else {
            return []
        }
        return entries.compactMap { entry in
            guard let source = entry["source"] as? String else { return nil }
            return WorkerProvenancePresentation(
                source: displayLabel(source),
                revision: entry["revision"] as? String
            )
        }
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func summaryValue(
        from value: AnyCodable,
        preferredKeys: [String]
    ) -> String? {
        func find(_ candidate: Any, depth: Int) -> String? {
            guard depth <= 3 else { return nil }
            if let text = candidate as? String, !text.isEmpty {
                return compactText(text)
            }
            if let dictionary = AnyCodable(candidate).dictionaryValue {
                for key in preferredKeys {
                    if let nested = dictionary[key], let result = find(nested, depth: depth + 1) {
                        return result
                    }
                }
                for key in ["output", "result", "deliverable"] {
                    if let nested = dictionary[key], let result = find(nested, depth: depth + 1) {
                        return result
                    }
                }
            }
            return nil
        }
        return find(value.value, depth: 0)
    }

}

enum WorkerPresentationSectionKind: String, CaseIterable, Sendable {
    case text
    case status
    case progress
    case table
    case list
    case link
    case artifact
    case confirmation
    case workerAction = "worker_action"
}

/// Pure projection for the closed declarative worker presentation contract.
///
/// Unknown contract versions and section kinds are ignored so an older client
/// retains the generic run/result console instead of failing protocol decode.
enum WorkerDeclarativePresentation {
    static func descriptor(for graph: WorkerRunGraphDTO) -> WorkerPresentationDTO? {
        let presentation = graph.nodes.first {
            $0.invocationId == graph.requestedInvocationId
        }?.presentation ?? graph.nodes.first {
            $0.workerId == graph.workerId && $0.presentation != nil
        }?.presentation
        guard let presentation,
              presentation.contractVersion == 1,
              !presentation.sections.isEmpty else {
            return nil
        }
        return presentation
    }

    static func kind(of section: WorkerPresentationSectionDTO) -> WorkerPresentationSectionKind? {
        WorkerPresentationSectionKind(rawValue: section.kind)
    }

    static func resultPointers(in presentation: WorkerPresentationDTO) -> [String] {
        Array(
            Set(
                presentation.sections
                    .filter { kind(of: $0).map(requiresResult) == true }
                    .compactMap(\.valuePointer)
            )
        ).sorted()
    }

    static func safeURL(_ value: String?) -> URL? {
        guard let value,
              value.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !isLocalHost(host),
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    static func primitiveText(_ value: AnyCodable) -> String? {
        if let string = value.stringValue {
            return WorkerConsolePresentation.compactText(string, maxLength: 4_096)
        }
        if let bool = value.boolValue {
            return bool ? "True" : "False"
        }
        if let int = value.intValue {
            return String(int)
        }
        if let double = value.doubleValue {
            return String(double)
        }
        return nil
    }

    static func progressValue(_ value: AnyCodable) -> Double? {
        let number: Double?
        if let double = value.doubleValue {
            number = double
        } else if let int = value.intValue {
            number = Double(int)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return min(max(number, 0), 1)
    }

    static func listItems(_ value: AnyCodable) -> [String] {
        guard let values = value.arrayValue else { return [] }
        return values.prefix(20).compactMap {
            primitiveText(AnyCodable($0)).map {
                WorkerConsolePresentation.compactText($0, maxLength: 512)
            }
        }
    }

    static func tableRows(
        _ value: AnyCodable,
        columns: [WorkerPresentationColumnDTO]
    ) -> [[String]] {
        guard let rows = value.arrayValue else { return [] }
        return rows.prefix(20).map { row in
            columns.map { column in
                Self.value(at: column.valuePointer, in: row)
                    .flatMap { primitiveText(AnyCodable($0)) }
                    .map { WorkerConsolePresentation.compactText($0, maxLength: 160) }
                    ?? "—"
            }
        }
    }

    static func value(at pointer: String, in root: Any) -> Any? {
        guard pointer.isEmpty || pointer.hasPrefix("/") else { return nil }
        var value = root
        if pointer.isEmpty {
            return value
        }
        for rawToken in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let token = decodePointerToken(String(rawToken)) else { return nil }
            if let dictionary = AnyCodable(value).dictionaryValue {
                guard let next = dictionary[token] else { return nil }
                value = next
            } else if let array = AnyCodable(value).arrayValue,
                      let index = Int(token),
                      index >= 0,
                      index < array.count {
                value = array[index]
            } else {
                return nil
            }
        }
        return value
    }

    private static func requiresResult(_ kind: WorkerPresentationSectionKind) -> Bool {
        switch kind {
        case .text, .status, .progress, .table, .list, .artifact:
            true
        case .link, .confirmation, .workerAction:
            false
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host == "::1"
            || host.hasPrefix("fe80:")
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
            || host.contains(":ffff:") {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || octets[0] == 127
            || octets[0] == 0
            || octets[0] >= 224
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func decodePointerToken(_ token: String) -> String? {
        var result = ""
        var index = token.startIndex
        while index < token.endIndex {
            if token[index] == "~" {
                let next = token.index(after: index)
                guard next < token.endIndex else { return nil }
                switch token[next] {
                case "0": result.append("~")
                case "1": result.append("/")
                default: return nil
                }
                index = token.index(after: next)
            } else {
                result.append(token[index])
                index = token.index(after: index)
            }
        }
        return result
    }
}
