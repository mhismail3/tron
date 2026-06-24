import Foundation

enum CapabilityActivityPresentation {
    static func title(
        for identity: CapabilityIdentity,
        arguments: [String: AnyCodable]? = nil
    ) -> String {
        CapabilityPresentation.title(
            for: identity,
            targetId: targetId(from: object(from: arguments))
        )
    }

    static func title(
        for identity: CapabilityIdentity,
        arguments: AnyCodable?
    ) -> String {
        title(for: identity, arguments: object(from: arguments)?.mapValues { AnyCodable($0) })
    }

    static func symbol(
        for identity: CapabilityIdentity,
        arguments: [String: AnyCodable]? = nil
    ) -> String {
        CapabilityPresentation.symbol(
            for: identity,
            targetId: targetId(from: object(from: arguments))
        )
    }

    static func symbol(
        for identity: CapabilityIdentity,
        arguments: AnyCodable?
    ) -> String {
        symbol(for: identity, arguments: object(from: arguments)?.mapValues { AnyCodable($0) })
    }

    static func summary(
        explicit: String? = nil,
        arguments: [String: AnyCodable]? = nil,
        identity: CapabilityIdentity
    ) -> String? {
        if let explicit = explicit?.nilIfEmpty {
            return explicit.truncated(to: 120)
        }
        if let hinted = CapabilityPresentation.presentationString("summary", for: identity)
            ?? CapabilityPresentation.presentationString("subtitle", for: identity)
            ?? CapabilityPresentation.presentationString("commandText", for: identity) {
            return hinted.truncated(to: 120)
        }

        let rawObject = object(from: arguments)
        let object = targetArguments(from: rawObject) ?? rawObject
        guard let object else { return nil }
        if let summary = simpleSummary(from: object) {
            return summary.truncated(to: 120)
        }
        return nil
    }

    static func summary(
        explicit: String? = nil,
        arguments: AnyCodable?,
        identity: CapabilityIdentity
    ) -> String? {
        summary(explicit: explicit, arguments: object(from: arguments)?.mapValues { AnyCodable($0) }, identity: identity)
    }

    private static func object(from arguments: [String: AnyCodable]?) -> [String: Any]? {
        arguments?.mapValues { $0.value }
    }

    private static func object(from arguments: AnyCodable?) -> [String: Any]? {
        arguments?.value as? [String: Any]
    }

    private static func targetId(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let target = object["target"] as? String {
            return target.nilIfEmpty
        }
        if let target = object["target"] as? [String: Any] {
            return firstString(
                ["operationName", "operation", "action", "name"],
                in: target
            )
        }
        return firstString(
            ["operationName", "operation", "action", "target", "name"],
            in: object
        )
    }

    private static func targetArguments(from object: [String: Any]?) -> [String: Any]? {
        guard let object else { return nil }
        if let arguments = object["arguments"] as? [String: Any] {
            return arguments
        }
        if let payload = object["payload"] as? [String: Any] {
            return payload
        }
        return nil
    }

    private static func simpleSummary(from object: [String: Any]) -> String? {
        if let command = firstString(["command", "cmd", "shellCommand"], in: object) {
            return command
        }
        if let query = firstString(["query", "q", "searchQuery"], in: object) {
            return query
        }
        if let pattern = firstString(["pattern", "glob", "name"], in: object) {
            return pattern
        }
        if let url = firstString(["url", "apiUrl", "endpoint"], in: object) {
            return url
        }
        if let path = firstString(["workspacePath", "path", "filePath", "cwd"], in: object) {
            return compactPathLabel(path)
        }
        return nil
    }

    private static func firstString(_ keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let string = object[key] as? String, let value = string.nilIfEmpty {
                return value
            }
        }
        return nil
    }

    private static func compactPathLabel(_ path: String) -> String {
        if path == "." {
            return "current folder"
        }
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.nilIfEmpty ?? path
    }
}
