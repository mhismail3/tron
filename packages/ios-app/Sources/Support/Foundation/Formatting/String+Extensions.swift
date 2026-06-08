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

    /// Safely creates a URL from the string
    var asURL: URL? {
        URL(string: self)
    }

    /// Extract a preview from thinking content: first N non-empty lines, joined, max length.
    func thinkingPreview(maxLines: Int = 3, maxLength: Int = 120) -> String {
        let lines = components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxLines)
        let preview = lines.joined(separator: " ")
        return preview.truncated(to: maxLength)
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

    /// Abbreviates a macOS server path by replacing /Users/<username> with ~
    var abbreviatingHomeDirectory: String {
        replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
    }
}

