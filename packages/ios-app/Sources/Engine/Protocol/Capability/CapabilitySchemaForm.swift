import Foundation

indirect enum CapabilitySchemaFieldKind: Equatable, Sendable {
    case object
    case array
    case string
    case number
    case integer
    case boolean
    case enumeration([String])
    case nullable(CapabilitySchemaFieldKind)
    case unsupported(String)
}

struct CapabilitySchemaField: Identifiable, Equatable, Sendable {
    var id: String { path.joined(separator: ".") }
    var path: [String]
    var title: String
    var kind: CapabilitySchemaFieldKind
    var required: Bool
    var description: String?
    var defaultValue: AnyCodable?
    var examples: [AnyCodable]
    var uiHint: String?
    var children: [CapabilitySchemaField]
}

struct CapabilitySchemaFormModel: Equatable, Sendable {
    var fields: [CapabilitySchemaField]
    var unsupportedPaths: [String]

    static func build(from schema: AnyCodable?) -> CapabilitySchemaFormModel {
        guard let object = schema?.dictionaryValue else {
            return CapabilitySchemaFormModel(fields: [], unsupportedPaths: [])
        }
        var unsupported: [String] = []
        let root = field(
            name: "payload",
            path: [],
            schema: object,
            required: true,
            unsupported: &unsupported
        )
        return CapabilitySchemaFormModel(
            fields: root.children,
            unsupportedPaths: unsupported
        )
    }

    private static func field(
        name: String,
        path: [String],
        schema: [String: Any],
        required: Bool,
        unsupported: inout [String]
    ) -> CapabilitySchemaField {
        let type = schema["type"]
        let enumValues = (schema["enum"] as? [Any])?.compactMap { $0 as? String }
        let nullable = (type as? [Any])?.contains { ($0 as? String) == "null" } == true
        let typeName = normalizedTypeName(type)
        var kind = kindFor(typeName: typeName, enumValues: enumValues)
        if nullable {
            kind = .nullable(kind)
        }
        if case .unsupported = kind {
            unsupported.append((path + [name]).joined(separator: "."))
        }
        let requiredChildren = Set((schema["required"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let children = properties
            .compactMap { key, value -> CapabilitySchemaField? in
                guard let childSchema = value as? [String: Any] else { return nil }
                return field(
                    name: key,
                    path: path + [name],
                    schema: childSchema,
                    required: requiredChildren.contains(key),
                    unsupported: &unsupported
                )
            }
            .sorted { $0.title < $1.title }
        return CapabilitySchemaField(
            path: path + [name],
            title: schema["title"] as? String ?? name,
            kind: kind,
            required: required,
            description: schema["description"] as? String,
            defaultValue: schema["default"].map(AnyCodable.init),
            examples: (schema["examples"] as? [Any])?.map(AnyCodable.init) ?? [],
            uiHint: uiHint(schema: schema),
            children: children
        )
    }

    private static func normalizedTypeName(_ type: Any?) -> String {
        if let type = type as? String { return type }
        if let types = type as? [Any] {
            return types.compactMap { $0 as? String }.first { $0 != "null" } ?? "null"
        }
        return "object"
    }

    private static func kindFor(typeName: String, enumValues: [String]?) -> CapabilitySchemaFieldKind {
        if let enumValues, !enumValues.isEmpty {
            return .enumeration(enumValues)
        }
        switch typeName {
        case "object": return .object
        case "array": return .array
        case "string": return .string
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .boolean
        default: return .unsupported(typeName)
        }
    }

    private static func uiHint(schema: [String: Any]) -> String? {
        if let explicit = schema["uiHint"] as? String { return explicit }
        let format = schema["format"] as? String
        if matches(format, ["uri", "url"]) { return "url" }
        if matches(format, ["password"]) { return "secretReference" }
        let description = (schema["description"] as? String)?.lowercased() ?? ""
        if description.contains("path") { return "path" }
        if description.contains("command") { return "command" }
        if description.contains("markdown") { return "markdown" }
        if description.contains("duration") || description.contains("timeout") { return "duration" }
        if description.contains("network") { return "networkTarget" }
        return nil
    }

    private static func matches(_ value: String?, _ candidates: [String]) -> Bool {
        guard let value else { return false }
        return candidates.contains(value.lowercased())
    }
}
