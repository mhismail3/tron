import Foundation
import TronMobileCore

enum ProjectResourceTitlePresentation {
    static func toolTitle(_ value: JSONValue) -> String {
        let object = value.objectValue ?? [:]
        let name = nonempty(object["name"]?.stringValue) ?? nonempty(value.stringValue)
        if let name {
            return ToolDetailPresentation.displayTitle(for: name, label: nonempty(object["label"]?.stringValue) ?? nonempty(object["title"]?.stringValue))
        }
        for key in ["label", "title"] {
            if let text = nonempty(object[key]?.stringValue), text != name { return text }
        }
        if let path = nonempty(object["path"]?.stringValue) {
            return resourcePathTitle(path)
        }
        if let id = nonempty(object["id"]?.stringValue) {
            return ComposerResourceNameFormatter.friendly(id)
        }
        return "Unnamed tool"
    }

    private static func resourcePathTitle(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let candidate = file.lowercased() == "skill.md"
            ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            : stem(path)
        return ComposerResourceNameFormatter.friendly(candidate)
    }

    private static func stem(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        return ["ts", "tsx", "js", "jsx", "mjs", "cjs", "md", "json"].contains(ext)
            ? (file as NSString).deletingPathExtension : file
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum ProjectResourceTextPresentation {
    static func readableDescription(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let characters = Array(normalized)
        guard characters.count > 2 else { return normalized }
        return characters.indices.map { index in
            guard characters[index] == "-",
                  index > characters.startIndex,
                  index < characters.index(before: characters.endIndex),
                  characters[characters.index(before: index)].isLetter || characters[characters.index(before: index)].isNumber,
                  characters[characters.index(after: index)].isLetter || characters[characters.index(after: index)].isNumber
            else { return String(characters[index]) }
            return "‑"
        }.joined()
    }
}
