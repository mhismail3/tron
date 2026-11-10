#if HOSTED_TEST
import Foundation
import TronMobileCore

extension HostedSubagentParityFixture {
    static var chipCategoryTranscript: [TranscriptItem] {
        func semantic(_ kind: String, origin: String, title: String?, direction: String = "inboundContext",
                      sequence: Int, extra: [String: Any] = [:]) -> [String: Any] {
            var originObject: [String: Any] = ["kind": origin, "confidence": "receipt"]
            if let title { originObject["title"] = title }
            return ["version": 1, "sequence": sequence, "direction": direction, "contextEffect": "modelInput",
                    "delivery": "stored", "visibility": "visible", "kind": kind, "origin": originObject]
                .merging(extra) { $1 }
        }
        func text(_ id: String, _ value: String) -> [String: Any] {
            ["id": id + "-text", "ordinal": 0, "type": "text", "text": value]
        }
        func custom(_ id: String, _ customType: String, origin: String, title: String?, body: String,
                    details: [String: Any], sequence: Int) -> [String: Any] {
            ["id": id, "timestamp": "2026-01-01T00:00:0\(sequence)Z", "kind": "customMessage", "customType": customType,
             "display": true, "content": [text(id, body)], "details": details,
             "semantic": semantic("message", origin: origin, title: title, sequence: sequence)]
        }
        func toolCall(_ id: String, name: String) -> [String: Any] {
            ["id": id, "presentationId": id, "timestamp": "2026-01-01T00:00:10Z", "kind": "message", "role": "assistant",
             "content": [["id": id + "-call", "ordinal": 0, "type": "toolCall", "toolCallId": id,
                          "name": name, "arguments": ["path": "fixture.txt"]]]]
        }
        func toolResult(_ id: String, name: String, failed: Bool) -> [String: Any] {
            ["id": id + "-result", "presentationId": id + "-result", "timestamp": "2026-01-01T00:00:11Z",
             "kind": "message", "role": "toolResult", "toolCallId": id, "toolName": name, "isError": failed,
             "durationMs": 1200, "content": [text(id + "-result", failed ? "No such file." : "Fixture contents.")]]
        }
        let rows: [[String: Any]] = [
            ["id": "chip-compaction", "timestamp": "2026-01-01T00:00:00Z", "kind": "compaction",
             "summary": "", "tokensBefore": 182_000],
            ["id": "chip-prompt", "presentationId": "chip-prompt", "timestamp": "2026-01-01T00:00:01Z",
             "kind": "message", "role": "user", "content": [text("chip-prompt", "Review the open diff.")],
             "semantic": semantic("prompt", origin: "user", title: nil, direction: "agentInvocation", sequence: 1,
                 extra: ["resourceInvocations": [["source": "prompt", "name": "code-review", "arguments": ""]]])],
            ["id": "chip-model", "timestamp": "2026-01-01T00:00:01Z", "kind": "modelChange",
             "modelRef": ["provider": "anthropic", "id": "claude-opus-5-5"]],
            ["id": "chip-command", "timestamp": "2026-01-01T00:00:02Z", "kind": "customEntry",
             "customType": "tron.command.v1", "data": ["command": "review"],
             "semantic": semantic("command", origin: "extension", title: "Reviewer", direction: "ambientStatus",
                 sequence: 2, extra: ["lifecycle": "completed",
                     "resourceInvocations": [["source": "extension", "name": "review", "arguments": ""]]])],
            custom("chip-automation", "tron.home-trigger.v1", origin: "extension", title: "Automation",
                   body: "Daily digest is due.", details: ["trigger": ["kind": "automation", "title": "Daily digest"]],
                   sequence: 3),
            custom("chip-worker", "tron.home-task-result.v1", origin: "extension", title: "Home task",
                   body: "Home task: Fix typo | outcome: final\n\nDone.",
                   details: ["taskId": "chip-task", "taskTitle": "Fix typo", "resultRef": ["entryId": "report"],
                             "terminalEvidence": ["outcome": "final"]], sequence: 4),
            custom("chip-subagent", "subagent_supervisor_request", origin: "subagent", title: "Subagents",
                   body: "Discovery finished.", details: ["reason": "progress_update"], sequence: 5),
            ["id": "chip-notification", "timestamp": "2026-01-01T00:00:06Z", "kind": "customEntry",
             "customType": "fixture.status", "data": ["message": "Index rebuilt."],
             "semantic": semantic("status", origin: "extension", title: "Indexer", direction: "ambientStatus",
                                  sequence: 6)],
            custom("chip-context", "fixture.context", origin: "extension", title: "Fixture extension",
                   body: "Workspace context.", details: [:], sequence: 7),
            toolCall("chip-tool-done", name: "read"),
            toolResult("chip-tool-done", name: "read", failed: false),
            toolCall("chip-tool-failed", name: "grep"),
            toolResult("chip-tool-failed", name: "grep", failed: true),
            toolCall("chip-tool-running", name: "bash"),
        ]
        return try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }
}
#endif
