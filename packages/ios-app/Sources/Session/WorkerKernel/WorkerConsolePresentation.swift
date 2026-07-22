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

    static func compactText(_ value: String, maxLength: Int = 80) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maxLength, maxLength > 1 else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }

    static func runSummary(_ run: WorkerInvocationDTO) -> String? {
        summaryValue(from: run.input, preferredKeys: ["task", "question", "query", "action", "title"])
    }

    static func inboxSummary(_ item: WorkerInboxItemDTO) -> String {
        summaryValue(
            from: item.result,
            preferredKeys: ["error", "message", "summary", "status", "question", "task"]
        ) ?? (normalized(item.severity) == "error" ? "Worker execution failed" : "Durable worker result")
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

    static func invocationTemplate(from schema: AnyCodable?) -> String {
        let fields = schemaFields(from: schema)
        guard !fields.isEmpty else { return "{}" }
        let object = Dictionary(uniqueKeysWithValues: fields.map { field in
            (field.name, exampleValue(for: field.type))
        })
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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

    private static func exampleValue(for type: String) -> Any {
        switch normalized(type) {
        case "boolean": false
        case "integer", "number": 0
        case "array": []
        case "object": [:]
        default: ""
        }
    }
}
