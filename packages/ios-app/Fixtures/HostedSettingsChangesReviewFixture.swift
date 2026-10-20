#if HOSTED_TEST
import Foundation
import TronMobileCore

/// `-settings-changes-review`: Global Settings' Changes feed over realistic audit
/// rows (long values, every status, workers with and without a known task title,
/// new and old) and two full Gateway-sized pages, for visual review and the
/// Filters interaction measurement. Rows are dated relative to launch. Every
/// entry point is inert without the argument.
enum HostedSettingsChangesReview {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-settings-changes-review")
    static let pageSize = 50

    /// The last look sits between the new and the old rows.
    static var lastLook: String? {
        enabled ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600)) : nil
    }

    /// The app's session catalog, which supplies worker task titles, as it is in production.
    @MainActor static func prepare(_ model: AppModel) async {
        if enabled { _ = await model.refreshSessions() }
    }

    static func response(_ method: String) -> JSONValue? {
        enabled && method == "session.list" ? sessions : nil
    }
    static let workerTaskID = "task_01J9ZQ8K2M4R7XWV"
    static let workerSessionID = "worker-session-restructure"

    /// One worker session the catalog knows, so its task's title is available.
    static var sessions: JSONValue {
        let worker = SessionSummary(id: workerSessionID, name: "Restructure 0.4: compare ownership metadata",
            cwd: "/workspace/tron", parentSessionId: nil, homeTaskId: workerTaskID, createdAt: iso(-7200), updatedAt: iso(-3600),
            messageCount: 4, firstMessage: "Compare ownership metadata", phase: .idle, summaryRevision: 1)
        return .object(["sessions": .array([try! JSONValue.encode(worker)]), "nextCursor": .null,
                        "listRevision": .number(1), "projectionToken": .string("settings-changes-review:1"),
                        "archivedCount": .number(0)])
    }

    static func page(_ params: [String: JSONValue]) -> JSONValue? {
        guard enabled else { return nil }
        let cursor = params["cursor"]?.stringValue
        let offset = cursor == "review-2" ? pageSize : 0
        let rows = (offset..<(offset + pageSize)).map(entry)
            .filter { params["key"] == nil || params["key"] == $0.objectValue?["key"] }
            .filter { row in
                guard let status = params["status"]?.stringValue else { return true }
                return row.objectValue?["status"]?.stringValue == status
            }
            .filter { row in
                guard let actor = params["actor"]?.stringValue else { return true }
                let kind = row.objectValue?["actor"]?.objectValue?["kind"]?.stringValue
                return actor == "agents" ? kind != "ui" : kind == actor
            }
        return .object(["entries": .array(rows), "nextCursor": offset == 0 ? .string("review-2") : .null])
    }

    private static let samples: [(key: String, label: String, layer: String, scope: String, actor: [String: JSONValue],
                                  actorLabel: String, status: String, before: String, after: String)] = [
        ("model.queue[role=worker]", "Worker models", "profile", "Home profile",
         ["kind": .string("worker"), "id": .string(workerSessionID), "sessionId": .string(workerSessionID), "taskId": .string(workerTaskID)],
         "Home task \(workerTaskID)", "applied", "anthropic/claude-opus-5-5, openai/gpt-6",
         "anthropic/claude-opus-5-5, openai/gpt-6, opencode-go/deepseek-v4.1-flash"),
        ("model.thinking[role=chat]", "Thinking", "chat", "Session",
         ["kind": .string("agent"), "id": .string("fixture-chat"), "sessionId": .string("fixture-chat")],
         "A chat's agent", "pending", "Medium", "High"),
        ("run.retry.maxRetries", "Retries", "mac", "Mac", ["kind": .string("ui"), "id": .string("device")],
         "You", "failed", "4 retries", "6 retries"),
        ("tools.shell.path", "Shell", "project", "Repository", ["kind": .string("outside"), "id": .string(".tron/settings.json")],
         "Outside Tron", "outside", "/bin/bash", "/opt/homebrew/bin/fish --login --init-command 'set -gx TRON 1'"),
        ("permissions.budget.task", "Task budget", "profile", "Home profile", ["kind": .string("home"), "id": .string("home")],
         "Home", "applied", "input 200000", "input 400000"),
        ("model.queue[role=subagent]", "Subagent models", "profile", "Home profile",
         ["kind": .string("worker"), "id": .string("worker-unknown"), "sessionId": .string("worker-unknown"), "taskId": .string("task_01J9ZQUNKNOWNTITLE")],
         "Home task task_01J9ZQUNKNOWNTITLE", "declined", "openai/gpt-6-luna", "anthropic/claude-haiku-5-5"),
        ("context.compaction.reserveTokens", "Reserve", "mac", "Mac", ["kind": .string("ui"), "id": .string("device")],
         "You", "applied", "16,384 tokens", "20,000 tokens"),
    ]

    private static func entry(_ index: Int) -> JSONValue {
        let sample = samples[index % samples.count]
        // Minutes, hours, then days: the first rows are new since the last look (3 h).
        let age: TimeInterval = index == 0 ? 2 * 3600 : index == 1 ? 20 * 60 : index == 2 ? 26 * 3600
            : index == 3 ? 3 * 86400 : index == 4 ? 5 * 60 : Double(index) * 4 * 3600
        let target: JSONValue = sample.layer == "project"
            ? .object(["kind": .string("project"), "cwd": .string("/fixture/project")])
            : sample.layer == "chat" ? .object(["kind": .string("session"), "sessionId": .string("fixture-chat")])
            : .object(["kind": .string(sample.layer == "profile" ? "home" : "mac")])
        var object: [String: JSONValue] = [
            "changeId": .string("review-\(index)"), "at": .string(iso(-age)), "actor": .object(sample.actor),
            "target": target, "layer": .string(sample.layer), "key": .string(sample.key), "op": .string("set"),
            "tier": .string(sample.status == "pending" ? "approve" : "quiet"), "status": .string(sample.status),
            "presentation": .object(["label": .string(sample.label), "actor": .string(sample.actorLabel),
                "layer": .string(sample.scope),
                "display": .object(["before": .string(sample.before), "after": .string(sample.after)])]),
        ]
        if sample.status == "failed" { object["failure"] = .string("The Mac settings file is read-only") }
        return .object(object)
    }

    private static func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }
}
#endif
