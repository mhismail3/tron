#if HOSTED_TEST
import Foundation
import TronMobileCore

/// Shared synthetic values for visual review of the production settings renderer.
/// Editors still consume the typed values; labels/counts mirror Gateway declarations.
enum HostedSettingsReviewSchema {
    static let sections: [JSONValue] = [
        section("model", "Model", 10, inline: true),
        section("workers", "Workers & delegation", 15, inline: true),
        section("context", "Compaction", 20), section("tools", "Tools", 30),
        section("approvals", "Agent changes", 45), section("run", "Connection", 50),
        section("trust", "Trusted Projects", 55), section("connections", "Mac Terminal", 58),
    ]

    private static func section(_ id: String, _ title: String, _ order: Int, inline: Bool = false) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "order": .number(Double(order)), "chatInline": .bool(inline)])
    }

    static func key(_ id: String, _ group: String, _ label: String, _ value: JSONValue,
                    _ display: String, _ control: String = "number", order: Double = 10,
                    help: String = "", subgroup: String? = nil, essential: Bool = false,
                    layer: String = "mac", options: [JSONValue] = []) -> JSONValue {
        let layers = id.hasPrefix("model.queue") ? ["profile", "mac"]
            : ["model.ref[role=chat]", "model.thinking[role=chat]", "tools.active"].contains(id) ? ["chat", "profile", "project", "mac"]
            : id == "permissions.budget.task" ? ["profile"]
            : id.hasPrefix("tools.codemode") || id.hasPrefix("tools.shell") || id == "model.offered" || id == "model.thinkingBudgets" ? ["project", "mac"]
            : id == "permissions.defaultProjectTrust" || id == "run.httpProxy" || id == "run.cacheWarming" ? ["mac"]
            : ["chat", "project", "mac"]
        var row: [String: JSONValue] = [
            "key": .string(id), "group": .string(group), "value": value, "display": .string(display),
            "layer": .string(layer), "applied": .bool(true), "origin": .string(layer == "chat" ? "override" : "inherited"),
            "layers": .array(layers.map { .object(["layer": .string($0), "value": $0 == layer ? value : .null]) }),
            "badges": .array([.object(["kind": .string("layer"), "label": .string(layer == "chat" ? "Session" : layer == "profile" ? "Home profile" : "Mac")])]),
            "presentation": .object(["label": .string(label), "help": .string(help.isEmpty && id == "tools.active" ? "The tools the model may call." : help),
                "order": .number(order), "importance": .string(essential ? "essential" : "advanced"),
                "editableLayers": .array(layers.map(JSONValue.string)), "timing": .string("fixed"), "effect": .string("next-turn"),
                "control": .string(control), "valueKind": .string(control == "list" ? "stringList" : control == "number" ? "integer" : "choice"),
                "range": .object(["min": .number(0), "max": .number(1_000_000), "step": .number(1), "unit": .string("tokens")]),
                "options": .array(options)]),
        ]
        if id == "tools.active", var presentation = row["presentation"]?.objectValue {
            presentation["optionsSource"] = .object(["name": .string("catalog.tools"), "dependsOn": .array([])])
            row["presentation"] = .object(presentation)
        }
        if let subgroup { row["subgroup"] = .string(subgroup) }
        return .object(row)
    }

    static let sheetThemeKeys: [JSONValue] = {
        let approvals: [JSONValue] = additionalKeys.prefix(12).compactMap { value in
            guard let governed = value.objectValue?["key"]?.stringValue,
                  var row = key("permissions.floor", "approvals", "Agent approvals", .string("quiet"), "Quiet", "choice", order: 90,
                    help: "Which setting changes need your OK.",
                    options: [.object(["value": .string("quiet"), "label": .string("Quiet"), "detail": .string("The change applies without telling you")]),
                              .object(["value": .string("notify"), "label": .string("Notify"), "detail": .string("The change applies and tells you")]),
                              .object(["value": .string("approve"), "label": .string("Approve"), "detail": .string("The change waits for your approval")])]).objectValue else { return nil }
            row["qualifiers"] = .object(["key": .string(governed)])
            return .object(row)
        }
        return approvals + [key("permissions.macTerminalKey", "connections", "Mac Terminal key", .null, "Not set", "readOnly", order: 15,
            help: "Lets this paired iPhone open a shell on the Mac over Tailscale through Remote Login, even when the Gateway is not running.")]
    }()

    static let tools = ["ask_user", "display", "notify", "read", "bash", "edit", "write", "web_search", "fetch_content", "knowledge", "computer", "schedule", "connections", "settings", "zoom"]
    static let additionalKeys: [JSONValue] = [
        key("model.thinking[role=chat]", "model", "Thinking", .string("high"), "High", "choice", order: 20,
            help: "How much the model reasons before it answers.", essential: true, layer: "chat",
            options: [.object(["value": .string("high"), "label": .string("High")])]),
        key("model.queue[role=worker]", "workers", "Worker models", .array([.string("anthropic/claude-opus-5-5"), .string("openai/gpt-6")]), "2 models", "list", order: 40, essential: true, layer: "profile"),
        key("model.queue[role=subagent]", "workers", "Subagent models", .array([.string("openai/gpt-6-luna")]), "1 model", "list", order: 42, essential: true, layer: "profile"),
        key("permissions.budget.task", "workers", "Task budget", .object(["inputTokens": .number(200_000)]), "input 200000", "readOnly", order: 50, help: "Tokens one Home task may use, cached included. Empty is no limit.", essential: true, layer: "profile"),
        key("context.compaction.enabled", "context", "Automatic compaction", .bool(true), "On", "toggle", help: "Summarize older conversation when the context fills.", essential: true),
        key("context.compaction.reserveTokens", "context", "Response reserve", .number(16_384), "16,384 tokens", order: 20, help: "Tokens kept free for the reply. Compaction starts once the conversation fills the context window minus this."),
        key("context.compaction.keepRecentTokens", "context", "Kept after compaction", .number(20_000), "20K tokens", order: 30, help: "The latest tokens of conversation kept word for word; older turns become a summary."),
        key("context.compaction.instructions", "context", "Summary instructions", .string(""), "—", "text", order: 40, help: "Extra instructions for compaction summaries."),
        key("context.branchSummary.reserveTokens", "context", "Branch summary reserve", .number(16_384), "16,384 tokens", order: 50, help: "Tokens reserved when summarizing an abandoned branch."),
        key("model.thinking[role=summarizer]", "context", "Summary thinking", .string("inherit"), "Same as chat", "choice", order: 80, help: "Thinking level for compaction summaries.", options: [.object(["value": .string("inherit"), "label": .string("Same as chat")])]),
        key("tools.active", "tools", "Tools", .array(tools.map(JSONValue.string)), "15 tools", "checklist", essential: true, layer: "chat"),
        key("tools.codemode.mode", "tools", "Code mode", .string("on"), "On", "choice", order: 20, help: "Let the model call tools from a script.", options: [.object(["value": .string("on"), "label": .string("On")])]),
        key("tools.codemode.inlineBudget", "tools", "Inline budget", .number(16_000), "16000", order: 30, help: "Bytes of script output returned inline."),
        key("tools.shell.path", "tools", "Shell", .string("/bin/bash"), "/bin/bash", "text", order: 40, help: "The shell the bash tool runs."),
        key("tools.shell.commandPrefix", "tools", "Command prefix", .string(""), "—", "text", order: 50, help: "Text run before every shell command."),
        key("context.images.autoResize", "tools", "Resize images", .bool(true), "On", "toggle", order: 60, help: "Shrink large images before they are sent.", subgroup: "Images"),
        key("context.images.block", "tools", "Block images", .bool(false), "Allowed", "toggle", order: 70, help: "Replace images with a placeholder for the model.", subgroup: "Images", layer: "chat"),
        key("run.transport", "run", "Transport", .string("auto"), "Automatic", "choice", order: 90, help: "How requests reach the provider.", essential: true, options: [.object(["value": .string("auto"), "label": .string("Automatic")])]),
        key("run.httpIdleTimeoutMs", "run", "Idle timeout", .number(300_000), "300 s", order: 100, help: "How long a silent HTTP stream may idle."),
        key("run.websocketConnectTimeoutMs", "run", "WebSocket connect timeout", .number(10_000), "10 s", order: 110, help: "How long a WebSocket connection may take to open."),
        key("run.httpProxy", "run", "HTTP proxy", .null, "Not set", "secret", order: 120, help: "Proxy for model requests. Applies after a restart."),
        key("run.cacheWarming", "run", "Cache warming", .string("off"), "Off", "choice", order: 130, help: "Keep model prompt caches warm.", options: [.object(["value": .string("off"), "label": .string("Off")])]),
        key("permissions.defaultProjectTrust", "trust", "Default trust policy", .string("ask"), "Ask", "choice", order: 20, help: "What happens with a project that has no trust decision.", options: [.object(["value": .string("ask"), "label": .string("Ask")])]),
        key("model.thinkingBudgets", "workers", "Thinking budgets", .object(["high": .number(16_384)]), "1 budget", "readOnly", order: 60, help: "Token budget per thinking level, for models that take one."),
        key("model.offered", "workers", "Offered models", .array([]), "0 items", "list", order: 70, help: "Models offered in the picker. Empty offers every model."),
        key("run.queue.steeringMode", "run", "Steering delivery", .string("one-at-a-time"), "One at a time", "choice", order: 10, subgroup: "Queue"),
        key("run.queue.followUpMode", "run", "Follow-up delivery", .string("one-at-a-time"), "One at a time", "choice", order: 20, subgroup: "Queue"),
        key("run.retry.enabled", "run", "Retry", .bool(true), "On", "toggle", order: 30, subgroup: "Retry"),
        key("run.retry.maxRetries", "run", "Retries", .number(3), "3 retries", order: 40, subgroup: "Retry"),
    ]
}

#endif
