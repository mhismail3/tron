import Foundation

/// Reads `server.tailscaleIp` from the `[settings]` overlay in
/// `~/.tron/profiles/user/profile.toml`.
enum ServerSettingsReader {
    static func tailscaleIP(at path: URL) -> String? {
        guard let text = try? String(contentsOf: path, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        let trimmed = ProfileSettingsToml.value(in: text, table: "settings.server", key: "tailscaleIp")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Writes wrapper-owned settings into `profiles/user/profile.toml`.
///
/// The Rust agent can boot from profile-seeded defaults, so a fresh install
/// must not need this file before pairing. The Mac wrapper only creates or
/// updates the minimal `[settings]` keys it owns, preserving any custom
/// profile behavior the user or iOS app already wrote.
enum ServerSettingsWriter {
    enum Failure: Error, LocalizedError, Equatable {
        case emptyTailscaleIP
        case malformedProfile
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyTailscaleIP:
                return "Tailscale IP was empty"
            case .malformedProfile:
                return "profile.toml is not valid UTF-8"
            case .writeFailed(let reason):
                return reason
            }
        }
    }

    static func cacheTailscaleIP(_ ip: String, at path: URL) throws {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.emptyTailscaleIP
        }

        try updateToml(
            at: path,
            table: "settings.server",
            key: "tailscaleIp",
            value: ProfileSettingsToml.stringLiteral(trimmed)
        )
    }

    static func removeSettingsOverlay(at path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return
        }
        let text = try readTomlText(at: path)
        let updated = ProfileSettingsToml.removingSettingsTables(from: text)
        if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: path)
            return
        }
        try write(Data(updated.utf8), to: path)
    }

    private static func updateToml(at path: URL, table: String, key: String, value: String) throws {
        let existing = FileManager.default.fileExists(atPath: path.path)
            ? try readTomlText(at: path)
            : ProfileSettingsToml.defaultUserProfile
        let updated = ProfileSettingsToml.updating(text: existing, table: table, key: key, value: value)
        try write(Data(updated.utf8), to: path)
    }

    private static func readTomlText(at path: URL) throws -> String {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw Failure.malformedProfile
        }
        return text.isEmpty ? ProfileSettingsToml.defaultUserProfile : text
    }

    private static func write(_ data: Data, to path: URL) throws {
        let fm = FileManager.default
        let parent = path.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let tmp = parent.appendingPathComponent(".profile.\(UUID().uuidString).tmp", isDirectory: false)
            try data.write(to: tmp, options: [.atomic])
            if fm.fileExists(atPath: path.path) {
                _ = try fm.replaceItemAt(path, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: path)
            }
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}

private enum ProfileSettingsToml {
    static let defaultUserProfile = """
    version = "2"
    name = "user"
    managed = false
    profileClass = "custom"
    inherits = ["normal"]

    """

    static func value(in text: String, table targetTable: String, key targetKey: String) -> String? {
        var currentTable: String?
        for line in text.components(separatedBy: .newlines) {
            if let table = tableName(from: line) {
                currentTable = table
                continue
            }
            guard currentTable == targetTable,
                  let pair = keyValue(from: line),
                  pair.key == targetKey
            else {
                continue
            }
            return stringValue(from: pair.value)
        }
        return nil
    }

    static func updating(text: String, table targetTable: String, key targetKey: String, value: String) -> String {
        var lines = normalizedLines(from: text)
        var currentTable: String?
        var tableStart: Int?
        var tableEnd = lines.count

        for index in lines.indices {
            if let table = tableName(from: lines[index]) {
                if currentTable == targetTable, tableEnd == lines.count {
                    tableEnd = index
                }
                currentTable = table
                if table == targetTable {
                    tableStart = index
                    tableEnd = lines.count
                }
            }
        }

        let settingLine = "\(targetKey) = \(value)"
        if let tableStart {
            for index in (tableStart + 1)..<tableEnd {
                guard let pair = keyValue(from: lines[index]), pair.key == targetKey else { continue }
                let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
                lines[index] = "\(indent)\(settingLine)"
                return joined(lines)
            }
            lines.insert(settingLine, at: tableEnd)
            return joined(lines)
        }

        if lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append("[\(targetTable)]")
        lines.append(settingLine)
        return joined(lines)
    }

    static func removingSettingsTables(from text: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in normalizedLines(from: text) {
            if let table = tableName(from: line) {
                skipping = table == "settings" || table.hasPrefix("settings.")
                if skipping {
                    continue
                }
            }
            if !skipping {
                output.append(line)
            }
        }
        while output.last == "" {
            output.removeLast()
        }
        return output.isEmpty ? "" : joined(output)
    }

    static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    private static func normalizedLines(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private static func tableName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else {
            return nil
        }
        if trimmed.hasPrefix("[[") {
            guard let end = trimmed.range(of: "]]")?.lowerBound else { return nil }
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            return String(trimmed[start..<end]).trimmingCharacters(in: .whitespaces)
        }
        guard let end = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let start = trimmed.index(after: trimmed.startIndex)
        return String(trimmed[start..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func keyValue(from line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func stringValue(from rawValue: String) -> String? {
        guard let first = rawValue.first else { return nil }
        if first == "\"" {
            guard let literal = quotedPrefix(from: rawValue, quote: "\"") else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
        }
        if first == "'" {
            guard let literal = quotedPrefix(from: rawValue, quote: "'") else { return nil }
            return String(literal.dropFirst().dropLast())
        }
        return rawValue.split(separator: "#", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func quotedPrefix(from value: String, quote: Character) -> String? {
        var escaped = false
        var result = ""
        for (index, character) in value.enumerated() {
            result.append(character)
            if index == 0 { continue }
            if quote == "\"", escaped {
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == quote {
                return result
            }
        }
        return nil
    }
}
