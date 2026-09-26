import Foundation

/// Display-only names from the resource projection. Raw names, paths, package
/// sources, and invocations stay intact in the detail sheet and canonical data.
enum ProjectResourceTitlePresentation {
    static func title(kind: ProjectResourceKind, value: JSONValue) -> String {
        let object = value.objectValue ?? [:]
        for key in ["label", "title"] {
            if let text = nonempty(object[key]?.stringValue) { return text }
        }
        let name = nonempty(object["name"]?.stringValue) ?? nonempty(value.stringValue)
        if let name {
            if kind == .tools, let label = toolLabels[name] { return label }
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

    /// Package resolution has paths, not authored titles. Use the same friendly
    /// fallback as session resources without inventing a new canonical name.
    static func resourcePathTitle(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let candidate = file.lowercased() == "skill.md"
            ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            : stem(path)
        return ComposerResourceNameFormatter.friendly(candidate)
    }

    private static let toolLabels = [
        "read": "Read File", "write": "Write File", "edit": "Edit File",
        "bash": "Run Shell Command", "powershell": "Run PowerShell Command",
        "grep": "Search File Contents", "find": "Find Files", "ls": "List Files",
    ]

    /// Extension identities come from package resolutions or inline factory
    /// paths, so they need their own naming rule; the Hooks sheet owns this
    /// presentation now that Project Resources lists no extensions.
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
            // Do not present implementation directories as extension names.
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
        // The leading @ in an npm scope or SSH user is not a version delimiter.
        // A Git ref may itself contain slashes, so compare to the first path slash.
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
