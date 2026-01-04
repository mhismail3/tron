import Foundation

// MARK: - String Extensions

extension String {
    /// Truncates the string to a maximum length with ellipsis
    func truncated(to maxLength: Int, trailing: String = "...") -> String {
        if self.count > maxLength {
            return String(self.prefix(maxLength - trailing.count)) + trailing
        }
        return self
    }

    /// Removes leading and trailing whitespace and newlines
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns nil if the string is empty after trimming
    var nilIfEmpty: String? {
        trimmed.isEmpty ? nil : trimmed
    }

    /// Splits the string into lines
    var lines: [String] {
        components(separatedBy: .newlines)
    }

    /// Returns the first n lines
    func firstLines(_ n: Int) -> String {
        lines.prefix(n).joined(separator: "\n")
    }

    /// Checks if string contains only whitespace
    var isBlank: Bool {
        trimmed.isEmpty
    }

    /// Converts a camelCase or PascalCase string to Title Case
    var titleCased: String {
        // Insert space before uppercase letters
        let pattern = "([a-z])([A-Z])"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(self.startIndex..., in: self)
        let result = regex?.stringByReplacingMatches(
            in: self,
            range: range,
            withTemplate: "$1 $2"
        ) ?? self

        // Capitalize first letter
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    /// Safely creates a URL from the string
    var asURL: URL? {
        URL(string: self)
    }

    /// Base64 encodes the string
    var base64Encoded: String? {
        data(using: .utf8)?.base64EncodedString()
    }

    /// Decodes a base64 encoded string
    var base64Decoded: String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Optional String Extensions

extension Optional where Wrapped == String {
    /// Returns true if the optional string is nil or empty
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }

    /// Returns the string or a default value if nil/empty
    func orDefault(_ defaultValue: String) -> String {
        guard let value = self, !value.isEmpty else {
            return defaultValue
        }
        return value
    }
}

// MARK: - String Formatting

extension String {
    /// Formats the string as a file path, extracting just the filename
    var filename: String {
        (self as NSString).lastPathComponent
    }

    /// Formats the string as a file path, extracting the directory
    var directory: String {
        (self as NSString).deletingLastPathComponent
    }

    /// Formats the string as a file path, extracting the extension
    var fileExtension: String {
        (self as NSString).pathExtension
    }

    /// Removes the file extension
    var withoutExtension: String {
        (self as NSString).deletingPathExtension
    }
}

// MARK: - JSON Formatting

extension String {
    /// Pretty prints a JSON string
    var prettyPrintedJSON: String {
        guard let data = self.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: json,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return self
        }
        return prettyString
    }

    /// Compacts a JSON string by removing whitespace
    var compactedJSON: String {
        guard let data = self.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let compactData = try? JSONSerialization.data(
                  withJSONObject: json,
                  options: []
              ),
              let compactString = String(data: compactData, encoding: .utf8) else {
            return self
        }
        return compactString
    }
}
