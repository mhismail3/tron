import Foundation

struct JSONValueDecodingLimits: Sendable, Equatable {
    let maximumDepth: Int
    let maximumNodes: Int
    let maximumCollectionMembers: Int
    let maximumStringBytes: Int
    let maximumTotalStringBytes: Int

    static let gateway = JSONValueDecodingLimits(
        maximumDepth: 64,
        maximumNodes: 32_768,
        maximumCollectionMembers: 8_192,
        maximumStringBytes: 1_048_576,
        maximumTotalStringBytes: 4 * 1_048_576
    )
}

enum JSONValueDecodingLimitKind: String, Sendable, Equatable {
    case depth
    case nodes
    case collectionMembers = "collection_members"
    case stringBytes = "string_bytes"
    case totalStringBytes = "total_string_bytes"
}

/// Typed evidence for a bounded dynamic JSON rejection. The coding path is
/// reduced to source-owned keys and fixed placeholders before it leaves the
/// decoder; response-owned dictionary keys never cross this boundary.
struct JSONValueDecodingLimitViolation: Error, Sendable, Equatable, LocalizedError {
    let kind: JSONValueDecodingLimitKind
    let actual: Int
    let maximum: Int
    let codingPath: String

    var errorDescription: String? {
        "Dynamic JSON exceeds its \(kind.rawValue) budget"
    }
}

private extension CodingUserInfoKey {
    static let jsonValueDecodingLimits = CodingUserInfoKey(
        rawValue: "com.tron.mobile.json-value-decoding-limits"
    )!
}

private struct DynamicJSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Bounded dynamic JSON used only at protocol extension points such as tool
/// details. Stable gateway fields remain strongly typed.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let limits = decoder.userInfo[.jsonValueDecodingLimits] as? JSONValueDecodingLimits ?? .gateway
        guard decoder.codingPath.count <= limits.maximumDepth else {
            throw Self.limitViolation(
                kind: .depth,
                actual: decoder.codingPath.count,
                maximum: limits.maximumDepth,
                codingPath: decoder.codingPath
            )
        }

        let single = try decoder.singleValueContainer()
        let decoded: JSONValue
        if single.decodeNil() {
            decoded = .null
        } else if let value = try? single.decode(Bool.self) {
            decoded = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Dynamic JSON numbers must be finite"
                )
            }
            decoded = .number(value)
        } else if let value = try? single.decode(String.self) {
            guard value.utf8.count <= limits.maximumStringBytes else {
                throw Self.limitViolation(
                    kind: .stringBytes,
                    actual: value.utf8.count,
                    maximum: limits.maximumStringBytes,
                    codingPath: decoder.codingPath
                )
            }
            decoded = .string(value)
        } else if let keyed = try? decoder.container(keyedBy: DynamicJSONCodingKey.self) {
            let keys = keyed.allKeys
            guard keys.count <= limits.maximumCollectionMembers else {
                throw Self.limitViolation(
                    kind: .collectionMembers,
                    actual: keys.count,
                    maximum: limits.maximumCollectionMembers,
                    codingPath: decoder.codingPath
                )
            }
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(keys.count)
            for key in keys {
                guard key.stringValue.utf8.count <= limits.maximumStringBytes else {
                    throw Self.limitViolation(
                        kind: .stringBytes,
                        actual: key.stringValue.utf8.count,
                        maximum: limits.maximumStringBytes,
                        codingPath: decoder.codingPath + [key]
                    )
                }
                result[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            decoded = .object(result)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            if let count = unkeyed.count, count > limits.maximumCollectionMembers {
                throw Self.limitViolation(
                    kind: .collectionMembers,
                    actual: count,
                    maximum: limits.maximumCollectionMembers,
                    codingPath: decoder.codingPath
                )
            }
            var result: [JSONValue] = []
            result.reserveCapacity(min(unkeyed.count ?? 0, limits.maximumCollectionMembers))
            while !unkeyed.isAtEnd {
                guard result.count < limits.maximumCollectionMembers else {
                    throw Self.limitViolation(
                        kind: .collectionMembers,
                        actual: result.count + 1,
                        maximum: limits.maximumCollectionMembers,
                        codingPath: decoder.codingPath
                    )
                }
                result.append(try unkeyed.decode(JSONValue.self))
            }
            decoded = .array(result)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
        }
        try Self.validate(decoded, limits: limits, codingPath: decoder.codingPath)
        self = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Dynamic JSON numbers must be finite"
                ))
            }
            try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    private static func validate(
        _ root: JSONValue,
        limits: JSONValueDecodingLimits,
        codingPath: [any CodingKey]
    ) throws {
        var stack: [(value: JSONValue, depth: Int)] = [(root, codingPath.count)]
        var nodes = 0
        var stringBytes = 0
        while let current = stack.popLast() {
            guard current.depth <= limits.maximumDepth else {
                throw limitViolation(
                    kind: .depth,
                    actual: current.depth,
                    maximum: limits.maximumDepth,
                    codingPath: codingPath
                )
            }
            nodes += 1
            guard nodes <= limits.maximumNodes else {
                throw limitViolation(
                    kind: .nodes,
                    actual: nodes,
                    maximum: limits.maximumNodes,
                    codingPath: codingPath
                )
            }
            switch current.value {
            case .string(let value):
                stringBytes += value.utf8.count
            case .object(let value):
                guard value.count <= limits.maximumCollectionMembers else {
                    throw limitViolation(
                        kind: .collectionMembers,
                        actual: value.count,
                        maximum: limits.maximumCollectionMembers,
                        codingPath: codingPath
                    )
                }
                stringBytes += value.keys.reduce(into: 0) { $0 += $1.utf8.count }
                stack.append(contentsOf: value.values.map { ($0, current.depth + 1) })
            case .array(let value):
                guard value.count <= limits.maximumCollectionMembers else {
                    throw limitViolation(
                        kind: .collectionMembers,
                        actual: value.count,
                        maximum: limits.maximumCollectionMembers,
                        codingPath: codingPath
                    )
                }
                stack.append(contentsOf: value.map { ($0, current.depth + 1) })
            case .number, .bool, .null:
                break
            }
            guard stringBytes <= limits.maximumTotalStringBytes else {
                throw limitViolation(
                    kind: .totalStringBytes,
                    actual: stringBytes,
                    maximum: limits.maximumTotalStringBytes,
                    codingPath: codingPath
                )
            }
        }
    }

    private static func limitViolation(
        kind: JSONValueDecodingLimitKind,
        actual: Int,
        maximum: Int,
        codingPath: [any CodingKey]
    ) -> JSONValueDecodingLimitViolation {
        let path = codingPath.prefix(32).map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            // DynamicJSONCodingKey is response-owned data. Only synthesized
            // model keys are retained; all other keys use one fixed marker.
            guard String(reflecting: type(of: key)).hasSuffix(".CodingKeys") else {
                return "<dynamic>"
            }
            let admitted = key.stringValue.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                    ? Character(String(scalar)) : "?"
            }
            return String(admitted.prefix(64))
        }.reduce(into: "") { result, component in
            if component.hasPrefix("[") { result += component }
            else { result += result.isEmpty ? component : ".\(component)" }
        }
        return JSONValueDecodingLimitViolation(
            kind: kind,
            actual: max(0, actual),
            maximum: max(0, maximum),
            codingPath: String((path.isEmpty ? "dynamic" : path).prefix(256))
        )
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder.gateway.decode(type, from: JSONEncoder.gateway.encode(self))
    }

    var prettyPrinted: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static var gateway: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var gateway: JSONDecoder {
        gateway(jsonValueLimits: .gateway)
    }

    static func gateway(jsonValueLimits: JSONValueDecodingLimits) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.jsonValueDecodingLimits] = jsonValueLimits
        return decoder
    }
}
