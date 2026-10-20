#if HOSTED_TEST
import Foundation
import TronMobileCore

/// Global Extensions over the Gateway's real package shape: configured Mac
/// packages plus the bundled managed provider `packages.list` appends, and the
/// schema's Sources keys (labels/help mirror the Gateway declarations).
enum HostedExtensionsReview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-settings-ui-extensions") }

    static let configured = ["npm:pi-web-access", "git:github.com/example/pi-agent-browser", "npm:@example/pi-goal",
                             "npm:@example/anthropic-auth", "npm:@example/anthropic-auth-tools"]
    static let bundled = "tron:pi-subagents@0.76.1-tron.9#sha512-fixture"

    static var inventory: JSONValue {
        .object(["packages": .array((configured + [bundled]).map { source in
            .object(["source": .string(source), "scope": .string("user"), "filtered": .bool(false)])
        }), "resources": .object([
            "extensions": .array(configured.enumerated().map { index, source in
                .object(["path": .string("/fixture/packages/\(index)/index.ts"), "enabled": .bool(true),
                         "metadata": .object(["source": .string(source), "scope": .string("user"), "origin": .string("package")])])
            }),
            "skills": .array([]), "prompts": .array([]), "themes": .array([]),
        ])])
    }

    /// `packages.list` and `packages.checkUpdates` while enabled.
    static func response(_ method: String) -> JSONValue? {
        guard enabled else { return nil }
        switch method {
        case "packages.list": return inventory
        case "packages.checkUpdates": return .object(["updates": .array([])])
        default: return nil
        }
    }

    /// The Sources rows in the renderer fixture's resolved-key shape, set on the Mac.
    static var keys: [JSONValue] {
        guard enabled else { return [] }
        return sourceKeys.map { row in
            var object: [String: JSONValue] = [
                "key": .string(row.id), "group": .string("sources"), "display": .string(row.display), "layer": .string("mac"),
                "applied": .bool(true), "value": row.value, "layers": .array([.object(["layer": .string("mac")])]),
                "badges": .array([.object(["kind": .string("layer"), "label": .string("Set on Mac")])]),
                "presentation": .object(["label": .string(row.label), "help": .string(row.help), "order": .number(Double(row.order)),
                    "importance": .string(row.importance), "control": .string(row.control), "valueKind": .string("stringList")]),
            ]
            if let subgroup = row.subgroup { object["subgroup"] = .string(subgroup) }
            return .object(object)
        }
    }

    struct SourceKey { let id, label, help, display, importance, control: String; let subgroup: String?; let order: Int; let value: JSONValue }
    static var sourceKeys: [SourceKey] {
        ["extensions", "skills", "prompts", "themes"].enumerated().map { index, name in
            SourceKey(id: "sources.\(name)", label: name.capitalized, help: "Paths searched for \(name).", display: "Not set",
                      importance: "advanced", control: "list", subgroup: "Search paths", order: 10 + index * 10, value: .array([]))
        } + [
            SourceKey(id: "sources.packages", label: "Packages", help: "Installed pi packages.", display: "\(configured.count) packages",
                      importance: "essential", control: "readOnly", subgroup: nil, order: 50,
                      value: .array(configured.map(JSONValue.string))),
            SourceKey(id: "sources.npmCommand", label: "npm command", help: "The command used to install packages.", display: "Not set",
                      importance: "advanced", control: "list", subgroup: nil, order: 60, value: .array([])),
        ]
    }
}
#endif
