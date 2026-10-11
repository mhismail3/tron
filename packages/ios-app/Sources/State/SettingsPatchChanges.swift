import Foundation
import TronMobileCore

/// Turns the pi-document patches that today's per-key settings screens build
/// into `settings.change` key changes (gateway docs/settings-model.md 5.2).
///
/// It exists only while those hand-built screens do: the generic renderer
/// (#780) and the Settings rebuild (#769) send key changes themselves and
/// delete this table. A patch path it does not know is refused rather than
/// dropped, so a screen cannot lose a field silently.
enum SettingsPatchChanges {
    private static let keys: [String: String] = [
        "defaultThinkingLevel": "model.thinking[role=chat]",
        "thinkingBudgets": "model.thinkingBudgets",
        "enabledModels": "model.offered",
        "compaction.thinkingLevel": "model.thinking[role=summarizer]",
        "compaction.enabled": "context.compaction.enabled",
        "compaction.reserveTokens": "context.compaction.reserveTokens",
        "compaction.keepRecentTokens": "context.compaction.keepRecentTokens",
        "compaction.instructions": "context.compaction.instructions",
        "branchSummary.reserveTokens": "context.branchSummary.reserveTokens",
        "images.autoResize": "context.images.autoResize",
        "images.blockImages": "context.images.block",
        "defaultTools": "tools.active",
        "codemode.mode": "tools.codemode.mode",
        "codemode.inlineBudget": "tools.codemode.inlineBudget",
        "shellPath": "tools.shell.path",
        "shellCommandPrefix": "tools.shell.commandPrefix",
        "defaultProjectTrust": "permissions.defaultProjectTrust",
        "steeringMode": "run.queue.steeringMode",
        "followUpMode": "run.queue.followUpMode",
        "retry.enabled": "run.retry.enabled",
        "retry.maxRetries": "run.retry.maxRetries",
        "retry.baseDelayMs": "run.retry.baseDelayMs",
        "retry.provider.timeoutMs": "run.retry.provider.timeoutMs",
        "retry.provider.maxRetries": "run.retry.provider.maxRetries",
        "retry.provider.maxRetryDelayMs": "run.retry.provider.maxRetryDelayMs",
        "transport": "run.transport",
        "httpIdleTimeoutMs": "run.httpIdleTimeoutMs",
        "websocketConnectTimeoutMs": "run.websocketConnectTimeoutMs",
        "httpProxy": "run.httpProxy",
        "extensions": "sources.extensions",
        "skills": "sources.skills",
        "prompts": "sources.prompts",
        "themes": "sources.themes",
        "packages": "sources.packages",
        "npmCommand": "sources.npmCommand",
        "enableInstallTelemetry": "setup.installTelemetry",
    ]

    /// The `settings.change` params for one patch written to one settings target.
    static func params(patch: JSONValue, target: SettingsTarget, commandID: String) throws -> JSONValue {
        let layer = target.scope == .global ? "mac" : "project"
        var changes: [JSONValue] = []
        try collect(patch, path: [], layer: layer, into: &changes)
        let targetValue: JSONValue = switch target {
        case .global: .object(["kind": .string("mac")])
        case .project(let cwd): .object(["kind": .string("project"), "cwd": .string(cwd)])
        }
        return .object(["commandId": .string(commandID), "target": targetValue, "changes": .array(changes)])
    }

    private static func change(_ key: String, layer: String, value: JSONValue, qualifiers: [String: JSONValue]? = nil) -> JSONValue {
        var change: [String: JSONValue] = ["key": .string(key), "layer": .string(layer)]
        if case .null = value { change["op"] = .string("unset") } else { change["op"] = .string("set"); change["value"] = value }
        if let qualifiers { change["qualifiers"] = .object(qualifiers) }
        return .object(change)
    }

    private static func collect(_ value: JSONValue, path: [String], layer: String, into changes: inout [JSONValue]) throws {
        let dotted = path.joined(separator: ".")
        if dotted == "defaultModel" {
            changes.append(change("model.ref[role=chat]", layer: layer, value: value))
            return
        }
        if dotted == "modelContextWindows", let windows = value.objectValue {
            for (model, window) in windows.sorted(by: { $0.key < $1.key }) {
                changes.append(change("model.contextWindow", layer: layer, value: window, qualifiers: ["model": .string(model)]))
            }
            return
        }
        if let key = keys[dotted] {
            changes.append(change(key, layer: layer, value: value))
            return
        }
        guard let object = value.objectValue else {
            throw GatewayFailure(code: "invalid_request", message: "This settings screen sent \(dotted.isEmpty ? "a value" : dotted), which is not a setting Tron knows.", retryable: false, details: nil)
        }
        for (name, child) in object.sorted(by: { $0.key < $1.key }) {
            try collect(child, path: path + [name], layer: layer, into: &changes)
        }
    }
}
