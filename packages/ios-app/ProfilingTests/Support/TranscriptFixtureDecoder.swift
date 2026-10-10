import Foundation
@testable import TronMobile

/// Admits legacy inline test literals into the current transcript wire shape.
/// Shared protocol fixtures remain strict and are decoded without this helper.
func decodeTranscriptFixture<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let value = try JSONSerialization.jsonObject(with: data)
    let normalized = normalizeTranscriptFixture(value)
    return try JSONDecoder.gateway.decode(T.self, from: JSONSerialization.data(withJSONObject: normalized))
}

private func normalizeTranscriptFixture(_ value: Any) -> Any {
    if var dictionary = value as? [String: Any] {
        if dictionary["kind"] as? String == "message",
           dictionary["presentationId"] == nil,
           let id = dictionary["id"] as? String {
            dictionary["presentationId"] = id
        }
        if var content = dictionary["content"] as? [[String: Any]] {
            var activeThinkingRunOrdinal: Int?
            for index in content.indices {
                if content[index]["ordinal"] == nil { content[index]["ordinal"] = index }
                if content[index]["type"] as? String == "thinking" {
                    activeThinkingRunOrdinal = activeThinkingRunOrdinal ?? index
                    if content[index]["thinkingRunOrdinal"] == nil {
                        content[index]["thinkingRunOrdinal"] = activeThinkingRunOrdinal
                    }
                } else {
                    activeThinkingRunOrdinal = nil
                }
            }
            dictionary["content"] = content
        }
        for (key, nested) in dictionary { dictionary[key] = normalizeTranscriptFixture(nested) }
        return dictionary
    }
    if let array = value as? [Any] { return array.map(normalizeTranscriptFixture) }
    return value
}
