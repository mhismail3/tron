import Foundation

struct SessionContextProviderAuditOverview: Equatable, Sendable {
    let requestKind: String
    let messageCount: Int?
    let toolCount: Int?
}

enum SessionContextAuditFormatter {
    static func providerRequestOverview(
        _ value: AnyCodable
    ) -> SessionContextProviderAuditOverview {
        let root = value.dictionaryValue ?? [:]
        let providerRequest = AnyCodable(root["providerRequest"]).dictionaryValue ?? [:]
        return SessionContextProviderAuditOverview(
            requestKind: providerRequest["kind"] as? String ?? "redacted_request",
            messageCount: integer(root["messageCount"]),
            toolCount: integer(root["toolCount"])
        )
    }

    static func projectedJSONString(_ value: AnyCodable) -> String {
        let projected = project(value.value, key: nil)
        guard JSONSerialization.isValidJSONObject(projected),
              let data = try? JSONSerialization.data(
                withJSONObject: projected,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return String(describing: projected)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func project(_ value: Any, key: String?) -> Any {
        if let value = value as? AnyCodable {
            return project(value.value, key: key)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = project(entry.value, key: entry.key)
            }
        }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (rawKey, rawValue) in dictionary {
                guard let key = rawKey as? String else { continue }
                result[key] = project(rawValue, key: key)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { project($0, key: key) }
        }
        if let string = value as? String,
           string.hasPrefix("data:") || isMediaKey(key) && string.count > 256 {
            return "[media omitted: \(string.utf8.count) encoded bytes]"
        }
        return value
    }

    private static func isMediaKey(_ key: String?) -> Bool {
        guard let key = key?.lowercased() else { return false }
        return key == "data" || key == "image_url" || key == "imageurl"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double,
           value.isFinite {
            return Int(exactly: value.rounded(.towardZero))
        }
        return nil
    }
}
