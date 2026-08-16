import Foundation

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String, fallback: String) -> String { self[key]?.stringValue ?? fallback }
    func int(_ key: String, fallback: Int) -> Int { self[key]?.intValue ?? fallback }
    func bool(_ key: String, fallback: Bool) -> Bool { self[key]?.boolValue ?? fallback }
    func lines(_ key: String) -> String { (self[key]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n") }
}
