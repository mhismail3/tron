import Foundation

/// Shared argument parsing for tool JSON arguments.
/// Uses JSONSerialization instead of regex for correct handling of
/// escapes, nested values, and edge cases.
enum ToolArgumentParser {

    // MARK: - Generic Extractor

    /// Extract a string value for a given key from JSON arguments.
    /// Returns nil if the key is missing, the value is not a string, or JSON is invalid.
    static func string(_ key: String, from args: String) -> String? {
        guard let data = args.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String else {
            return nil
        }
        return value
    }

    /// Extract an integer value for a given key from JSON arguments.
    /// Returns nil if the key is missing, the value is not a number, or JSON is invalid.
    static func integer(_ key: String, from args: String) -> Int? {
        guard let data = args.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? Int else {
            return nil
        }
        return value
    }

    /// Extract a boolean value for a given key from JSON arguments.
    /// Returns nil if the key is missing, the value is not a bool, or JSON is invalid.
    static func boolean(_ key: String, from args: String) -> Bool? {
        guard let data = args.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? Bool else {
            return nil
        }
        return value
    }

    /// Extract a string array for a given key from JSON arguments.
    static func stringArray(_ key: String, from args: String) -> [String]? {
        guard let data = args.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? [String] else {
            return nil
        }
        return value
    }

    // MARK: - Typed Extractors

    /// Extract file path: tries "file_path" first, falls back to "path".
    static func filePath(from args: String) -> String {
        string("file_path", from: args) ?? string("path", from: args) ?? ""
    }

    /// Extract command field.
    static func command(from args: String) -> String {
        string("command", from: args) ?? ""
    }

    /// Extract pattern field.
    static func pattern(from args: String) -> String {
        string("pattern", from: args) ?? ""
    }

    /// Extract path field, defaulting to "." if missing.
    static func path(from args: String) -> String {
        string("path", from: args) ?? "."
    }

    /// Extract url field.
    static func url(from args: String) -> String {
        string("url", from: args) ?? ""
    }

    /// Extract query field.
    static func query(from args: String) -> String {
        string("query", from: args) ?? ""
    }

    /// Extract content field.
    static func content(from args: String) -> String {
        string("content", from: args) ?? ""
    }

    /// Extract action field.
    static func action(from args: String) -> String {
        string("action", from: args) ?? ""
    }

    // MARK: - Display Helpers

    /// Shorten a file path to just the filename for display.
    static func shortenPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Truncate a string to maxLength, appending "..." if truncated.
    static func truncate(_ str: String, maxLength: Int = 40) -> String {
        guard str.count > maxLength else { return str }
        return String(str.prefix(maxLength)) + "..."
    }

    /// Extract domain from a URL string, stripping "www." prefix.
    static func extractDomain(from url: String) -> String {
        if let urlObj = URL(string: url), let host = urlObj.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.contains("://") {
            let afterProtocol = url.components(separatedBy: "://").last ?? url
            let domain = afterProtocol.components(separatedBy: "/").first ?? afterProtocol
            return domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
        }
        return String(url.prefix(30))
    }
}
