import Foundation
import TronMobileCore

enum ProjectResourceTitlePresentation {
    static func title(kind: ProjectResourceKind, value: JSONValue) -> String {
        let object = value.objectValue ?? [:]
        let name = nonempty(object["name"]?.stringValue) ?? nonempty(value.stringValue)
        if kind == .tools, let name {
            return ToolDetailPresentation.displayTitle(for: name, label: nonempty(object["label"]?.stringValue) ?? nonempty(object["title"]?.stringValue))
        }
        for key in ["label", "title"] {
            if let text = nonempty(object[key]?.stringValue), text != name { return text }
        }
        if let name {
            return ComposerResourceNameFormatter.friendly(name)
        }
        if let path = nonempty(object["path"]?.stringValue) {
            return resourcePathTitle(path)
        }
        if let id = nonempty(object["id"]?.stringValue) {
            return ComposerResourceNameFormatter.friendly(id)
        }
        return "Unnamed \(kind.rawValue.dropLast())"
    }

    static func resourcePathTitle(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let candidate = file.lowercased() == "skill.md"
            ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            : stem(path)
        return ComposerResourceNameFormatter.friendly(candidate)
    }

    static func extensionTitle(name: String?, object: [String: JSONValue]) -> String {
        let path = nonempty(object["path"]?.stringValue)
            ?? nonempty(object["resolvedPath"]?.stringValue) ?? name ?? ""
        if path.hasPrefix("<inline:"), path.hasSuffix(">") {
            let inline = String(path.dropFirst(8).dropLast())
            if !inline.isEmpty, inline.allSatisfy(\.isNumber) { return "Extension \(inline)" }
            let titles = ["tron-schedule": "Tron Automations", "tron-notify": "Tron Notifications"]
            return titles[inline] ?? ComposerResourceNameFormatter.friendly(inline.isEmpty ? "Extension" : inline)
        }
        let entry = stem(path)
        let parent = (path as NSString).deletingLastPathComponent
        let parentName = (parent as NSString).lastPathComponent
        let genericEntries: Set<String> = ["index", "main", "extension"]
        if let package = packageName(object["source"]?.stringValue) {
            let label = ComposerResourceNameFormatter.friendly(package.hasPrefix("pi-") ? String(package.dropFirst(3)) : package)
            if !entry.isEmpty, !genericEntries.contains(entry) {
                return "\(label) · \(ComposerResourceNameFormatter.friendly(entry))"
            }
            let containers: Set<String> = ["", "src", "dist", "lib", "build", "extensions", "extension", package]
            return containers.contains(parentName)
                ? label
                : "\(label) · \(ComposerResourceNameFormatter.friendly(parentName))"
        }
        let candidate = genericEntries.contains(entry) && !parentName.isEmpty ? parentName : entry
        return ComposerResourceNameFormatter.friendly(candidate.isEmpty ? (name ?? "Extension") : candidate)
    }

    private static func packageName(_ source: String?) -> String? {
        guard let source else { return nil }
        var value: String
        if source.hasPrefix("npm:") { value = String(source.dropFirst(4)) }
        else if source.hasPrefix("git:") { value = String(source.dropFirst(4)) }
        else if source.hasPrefix("https://") || source.hasPrefix("ssh://") || source.hasPrefix("git@") { value = source }
        else { return nil }
        value = value.components(separatedBy: "://").last ?? value
        if let at = value.lastIndex(of: "@"), at != value.startIndex,
           value.firstIndex(of: "/").map({ at > $0 }) ?? true {
            value = String(value[..<at])
        }
        var name = (value as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return nonempty(name)
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
