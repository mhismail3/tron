#if HOSTED_TEST
import Foundation
import TronMobileCore

enum HostedSettingsReviewSchema {
    static func key(_ id: String, _ group: String, _ value: JSONValue, _ display: String,
                    subgroup: String? = nil, layer: String = "global", qualifiers: [String: String]? = nil) -> JSONValue {
        let layers = id.hasPrefix("model.queue") || id == "permissions.budget.task" ? ["session", "global"]
            : ["model.ref[role=chat]", "model.thinking[role=chat]", "tools.active"].contains(id) ? ["session", "project", "global"]
            : id.hasPrefix("tools.codemode") || id.hasPrefix("tools.shell") || id == "model.thinkingBudgets" ? ["project", "global"]
            : id == "permissions.defaultProjectTrust" || id == "run.cacheWarming" ? ["global"]
            : ["session", "project", "global"]
        var row: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "value": value, "display": .string(display),
            "layer": .string(layer), "applied": .bool(true),
            "overridden": .bool(layer != "project"),
            "layers": .array(layers.map { .object(["layer": .string($0), "value": $0 == layer ? value : .null]) }),
            "badges": .array([]),
        ]
        if let qualifiers { row["qualifiers"] = .object(qualifiers.mapValues(JSONValue.string)) }
        if let subgroup { row["subgroup"] = .string(subgroup) }
        return .object(row)
    }

    static let macTerminalKeys: [JSONValue] = {
        [key("permissions.macTerminalKey", "connections", .null, "Not set")]
    }()

    static var scopeReview: Bool { HostedLaunch.arguments.contains("-settings-scope-review") }

    static let tools = ["ask_user", "display", "notify", "read", "bash", "edit", "write", "web_search", "fetch_content", "knowledge", "computer", "schedule", "connections", "settings", "zoom"]
    static let additionalKeys: [JSONValue] = [
        key("model.thinking[role=chat]", "model", .string("high"), "High", layer: "session"),
        key("model.queue[role=worker]", "workers", .array([.string("anthropic/claude-opus-5-5"), .string("openai/gpt-6")]), "2 models", layer: "session"),
        key("model.queue[role=subagent]", "workers", .array([.string("openai/gpt-6-luna")]), "1 model", layer: "session"),
        key("permissions.budget.task", "workers", .object(["inputTokens": .number(200_000)]), "input 200000", layer: "session"),
        key("context.compaction.enabled", "context", .bool(true), "On"),
        key("context.compaction.reserveTokens", "context", .number(16_384), "16,384 tokens"),
        key("context.compaction.keepRecentTokens", "context", .number(20_000), "20K tokens"),
        key("context.compaction.instructions", "context", .string(""), "—"),
        key("context.branchSummary.reserveTokens", "context", .number(16_384), "16,384 tokens"),
        key("model.thinking[role=summarizer]", "context", .string("inherit"), "Same as chat"),
        key("tools.active", "tools", .array(tools.map(JSONValue.string)), "15 tools", layer: "session"),
        key("tools.codemode.mode", "tools", .string("on"), "On"),
        key("tools.codemode.inlineBudget", "tools", .number(16_000), "16000"),
        key("tools.shell.path", "tools", .string("/bin/bash"), "/bin/bash"),
        key("tools.shell.commandPrefix", "tools", .string(""), "—"),
        key("context.images.autoResize", "tools", .bool(true), "On", subgroup: "Images"),
        key("context.images.block", "tools", .bool(false), "Allowed", subgroup: "Images", layer: "session"),
        key("run.transport", "run", .string("auto"), "Automatic"),
        key("run.httpIdleTimeoutMs", "run", .number(300_000), "300 s"),
        key("run.websocketConnectTimeoutMs", "run", .number(10_000), "10 s"),
        key("run.cacheWarming", "run", .string("off"), "Off"),
        key("permissions.defaultProjectTrust", "trust", .string("ask"), "Ask"),
        key("model.thinkingBudgets", "workers", .object(["high": .number(16_384)]), "1 budget"),
        key("run.queue.steeringMode", "run", .string("one-at-a-time"), "One at a time", subgroup: "Queue"),
        key("run.queue.followUpMode", "run", .string("one-at-a-time"), "One at a time", subgroup: "Queue"),
        key("run.retry.enabled", "run", .bool(true), "On", subgroup: "Retry"),
        key("run.retry.maxRetries", "run", .number(3), "3 retries", subgroup: "Retry"),
    ]
}

#endif
