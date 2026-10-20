#if HOSTED_TEST
import Foundation

/// Synthetic content using home-owner.taskControl / controlCatalog wire shapes.
/// Catalog rows have no worker model; reports and receipts have no task title.
enum HostedTaskToolSheetFixture {
    static func result(_ scenario: String) -> (request: [String: Any], details: [String: Any]) {
        let id = "photo-readiness"
        func checkin(_ step: String, done: String, next: String, blocker: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["id": UUID().uuidString, "taskId": id, "sessionId": "worker-session",
                                      "operationId": "worker-operation", "at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180)),
                                      "step": step, "done": done, "next": next]
            if let blocker { value["blocker"] = blocker }
            return value
        }
        switch scenario {
        case "task-list":
            let rows: [[String: Any]] = [
                ["taskId": id, "title": "Keep Send disabled while photos prepare", "state": "running", "outcome": NSNull(),
                 "sessionId": "worker-session", "operationId": "worker-operation", "updatedAt": ISO8601DateFormatter().string(from: Date()),
                 "checkins": [checkin("Capturing the composer", done: "Attachment readiness now has one owner.", next: "Review light and dark previews.")],
                 "actions": ["status", "steer", "interrupt", "stop", "rename"]],
                ["taskId": "session-reconnect", "title": "Preserve drafts across reconnect", "state": "settled", "outcome": "final", "checkins": [], "actions": ["status", "report", "resume", "rename"]],
                ["taskId": "tool-sheet-review", "title": "Review tool sheet previews", "state": "settled", "outcome": "needs-input",
                 "checkins": [checkin("Ready for visual review", done: "Light and dark previews captured.", next: "Wait for approval.", blocker: "Visual approval needed.")], "actions": ["status", "report", "resume", "rename"]],
                ["taskId": "older-layout-audit", "title": "", "state": "settled", "outcome": "interrupted", "checkins": [], "actions": ["status", "report"]]
            ]
            return (["action": "list"], ["tasks": rows, "counts": ["active": 10, "finished": 495], "more": true, "workers": ["running": 10]])
        case "task-status":
            return (["action": "status", "taskId": id], ["taskId": id, "homeId": "home-fixture", "title": "Keep Send disabled while photos prepare",
                "createdAt": 1791960000000, "updatedAt": 1791962700000, "intent": ["text": HostedToolSheetsPolishFixture.brief], "target": "/workspace/project",
                "lifecycle": "active", "operationId": "worker-operation", "sessionId": "worker-session", "workerModel": ["provider": "openai", "id": "gpt-6.1-sol"],
                "checkins": [checkin("Capturing the composer", done: "Attachment readiness now has one owner.", next: "Review light and dark previews.")],
                "spend": ["sourceDigest": String(repeating: "a", count: 64), "inputTokens": 18450, "outputTokens": 3210, "cacheReadTokens": 64000, "cacheWriteTokens": 1200]])
        case "task-report":
            let report = ["resultId": "photo-preview-checkpoint", "outcome": "needs-input", "text": HostedToolSheetsPolishFixture.brief]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            return (["action": "report", "taskId": id], ["taskId": id, "offset": 0, "bytes": data.count, "text": String(decoding: data, as: UTF8.self), "nextOffset": NSNull()])
        case "task-steer", "task-interrupt", "task-resume", "task-stop", "task-rename":
            let action = String(scenario.dropFirst(5))
            var request: [String: Any] = ["action": action, "taskId": id]
            if ["steer", "resume", "interrupt"].contains(action) { request["text"] = HostedToolSheetsPolishFixture.brief }
            if action == "rename" { request["title"] = "Photo preparation: ready for review" }
            var receipt: [String: Any] = ["accepted": true, "action": action, "taskId": id, "sessionId": "worker-session", "operationId": "worker-operation"]
            if action == "resume" { receipt["taskId"] = "photo-readiness-2"; receipt["resumes"] = id }
            if action == "interrupt" { receipt["interrupted"] = true }
            if action == "rename" { receipt["title"] = request["title"]; receipt["state"] = "running" }
            return (request, receipt)
        case "task-malformed":
            return (["action": "list"], ["tasks": [["taskId": "incomplete-row"]], "counts": ["active": 1, "finished": 0], "more": false])
        case "task-refused":
            return (["action": "steer", "taskId": id, "text": "Please capture the composer."], [:])
        default:
            return (["action": "future-action", "taskId": id], ["unrecognized": "Result preserved in the generic sheet"])
        }
    }
}
#endif
