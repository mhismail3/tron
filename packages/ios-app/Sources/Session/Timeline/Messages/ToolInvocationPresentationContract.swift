import Foundation

/// Engine-owned classification for one exact provider-facing function.
///
/// The server derives this from the advertised function contract. The client
/// uses it only for presentation and never guesses worker identity from names.
enum ToolInvocationSurface: Equatable {
    struct Worker: Equatable {
        let id: String?
        let name: String?
        let version: String?
        let runnerKind: String?
    }

    case core(group: String?)
    case worker(Worker)
    case unknown

    init(identity: ToolIdentity) {
        let hints = identity.presentationHints
        switch hints?.string("surfaceKind")?.lowercased() {
        case "core":
            self = .core(group: hints?.string("primitiveGroup")?.nilIfEmpty)
        case "worker":
            self = .worker(
                Worker(
                    id: hints?.string("workerId")?.nilIfEmpty,
                    name: hints?.string("workerName")?.nilIfEmpty,
                    version: hints?.string("workerVersion")?.nilIfEmpty,
                    runnerKind: hints?.string("runnerKind")?.nilIfEmpty?.lowercased()
                )
            )
        default:
            self = .unknown
        }
    }

    var isWorker: Bool {
        if case .worker = self { return true }
        return false
    }

    var isAgentWorker: Bool {
        guard case .worker(let worker) = self else { return false }
        return worker.runnerKind == "agent"
    }

    var displayKind: String {
        switch self {
        case .core:
            return "Core primitive"
        case .worker(let worker):
            return worker.runnerKind == "agent" ? "Agent worker" : "Worker"
        case .unknown:
            return "Tool"
        }
    }

    var progressTitle: String {
        switch self {
        case .worker(let worker) where worker.runnerKind == "agent":
            return "Agent worker progress"
        case .worker:
            return "Worker progress"
        case .core:
            return "Execution progress"
        case .unknown:
            return "Progress"
        }
    }

    var resultTitle: String {
        isWorker ? "Worker output" : "Result"
    }

    var workerName: String? {
        guard case .worker(let worker) = self else { return nil }
        return worker.name
    }
}

extension ToolIdentity {
    /// Merge partial lifecycle observations without erasing richer identity
    /// already received from an earlier event.
    func merging(_ newer: ToolIdentity) -> ToolIdentity {
        var mergedHints = presentationHints ?? [:]
        for (key, value) in newer.presentationHints ?? [:] {
            mergedHints[key] = value
        }
        return ToolIdentity(
            toolName: newer.toolName ?? toolName,
            traceId: newer.traceId ?? traceId,
            rootInvocationId: newer.rootInvocationId ?? rootInvocationId,
            themeColor: newer.themeColor ?? themeColor,
            presentationHints: mergedHints.isEmpty ? nil : mergedHints
        )
    }
}

struct ToolStructuredField: Equatable, Identifiable {
    let key: String
    let value: ToolStructuredValue

    var id: String { key }
}

indirect enum ToolStructuredValue: Equatable {
    case object([ToolStructuredField])
    case array([ToolStructuredValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    var displayType: String {
        switch self {
        case .object: "Object"
        case .array: "List"
        case .string: "Text"
        case .number: "Number"
        case .boolean: "Boolean"
        case .null: "Empty"
        }
    }

    var containsNestedValues: Bool {
        switch self {
        case .object(let fields):
            return fields.contains { field in
                switch field.value {
                case .object, .array:
                    return true
                case .string, .number, .boolean, .null:
                    return false
                }
            }
        case .array:
            return true
        case .string, .number, .boolean, .null:
            return false
        }
    }
}

/// A typed, deterministic presentation document decoded from schema-valid
/// worker output or a fixed primitive's JSON result.
struct ToolStructuredDocument: Equatable {
    enum Source: Equatable {
        case request
        case result
    }

    let source: Source
    let root: ToolStructuredValue

    static func request(from data: ToolInvocationData) -> ToolStructuredDocument? {
        parse(json: data.arguments, source: .request)
    }

    static func result(from data: ToolInvocationData) -> ToolStructuredDocument? {
        if let result = data.result,
           let document = parse(json: result, source: .result) {
            return document
        }
        if let output = data.details?.anyCodableDict("output")?.rawValues {
            return ToolStructuredDocument(source: .result, root: value(from: output))
        }
        return nil
    }

    static func result(
        content: String,
        details: [String: AnyCodable]?
    ) -> ToolStructuredDocument? {
        if let document = parse(json: content, source: .result) {
            return document
        }
        if let output = details?.anyCodableDict("output")?.rawValues {
            return ToolStructuredDocument(source: .result, root: value(from: output))
        }
        return nil
    }

    private static func parse(json: String, source: Source) -> ToolStructuredDocument? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return nil
        }
        return ToolStructuredDocument(source: source, root: value(from: object))
    }

    private static func value(from raw: Any) -> ToolStructuredValue {
        if raw is NSNull {
            return .null
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.stringValue)
        }
        if let bool = raw as? Bool {
            return .boolean(bool)
        }
        if let string = raw as? String {
            return .string(string)
        }
        if let dictionary = raw as? [String: Any] {
            return .object(
                dictionary.keys.sorted().map { key in
                    ToolStructuredField(key: key, value: value(from: dictionary[key] ?? NSNull()))
                }
            )
        }
        if let dictionary = raw as? [String: AnyCodable] {
            return value(from: dictionary.rawValues)
        }
        if let array = raw as? [Any] {
            return .array(array.map(value(from:)))
        }
        if let wrapped = raw as? AnyCodable {
            return value(from: wrapped.value)
        }
        return .string(String(describing: raw))
    }
}
