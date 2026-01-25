import Foundation

/// A type-erased Codable value for handling dynamic JSON.
struct AnyCodable: Codable, Equatable, Hashable, @unchecked Sendable {
    let value: Any

    init(_ value: Any?) {
        self.value = value ?? NSNull()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode AnyCodable"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unable to encode AnyCodable"
                )
            )
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull):
            return true
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch value {
        case is NSNull:
            hasher.combine(0)
        case let bool as Bool:
            hasher.combine(bool)
        case let int as Int:
            hasher.combine(int)
        case let double as Double:
            hasher.combine(double)
        case let string as String:
            hasher.combine(string)
        default:
            hasher.combine(1)
        }
    }

    // MARK: - Convenience accessors

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var doubleValue: Double? { value as? Double }
    var boolValue: Bool? { value as? Bool }
    var arrayValue: [Any]? { value as? [Any] }
    var dictionaryValue: [String: Any]? { value as? [String: Any] }
    var isNull: Bool { value is NSNull }
}

extension AnyCodable: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        value = NSNull()
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Any...) {
        value = elements
    }
}

extension AnyCodable: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, Any)...) {
        value = Dictionary(uniqueKeysWithValues: elements)
    }
}

// MARK: - Payload Dictionary Extensions

/// Convenience extensions for [String: AnyCodable] payloads.
/// Simplifies the common pattern: payload["key"]?.value as? Type
extension Dictionary where Key == String, Value == AnyCodable {
    /// Get string value for key
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    /// Get int value for key
    func int(_ key: String) -> Int? {
        self[key]?.intValue
    }

    /// Get double value for key
    func double(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    /// Get bool value for key
    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    /// Get nested dictionary for key
    func dict(_ key: String) -> [String: Any]? {
        self[key]?.dictionaryValue
    }

    /// Get array for key
    func array(_ key: String) -> [Any]? {
        self[key]?.arrayValue
    }

    /// Get string array for key
    func stringArray(_ key: String) -> [String]? {
        self[key]?.arrayValue?.compactMap { $0 as? String }
    }

    /// Get nested AnyCodable dictionary for key
    func anyCodableDict(_ key: String) -> [String: AnyCodable]? {
        if let dict = self[key]?.dictionaryValue {
            return dict.mapValues { AnyCodable($0) }
        }
        return nil
    }
}
