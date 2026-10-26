#if HOSTED_TEST
import Foundation
import TronMobileCore

extension HostedSubagentParityFixture {
    /// Real transcript DTOs, deliberately not result-arrival or array ordered.
    /// All declarations share a timestamp; finalized groupIndex is authoritative.
    static func toolSummaryTintTranscript(_ scenario: String) -> [TranscriptItem] {
        let active = scenario.hasPrefix("active-")
        let failedIndex: Int? = scenario == "latest-failed" ? 2
            : ["recovered", "active-failed", "cross-group"].contains(scenario) ? 0 : nil
        let prefix = "tint-\(scenario)"
        func call(_ index: Int, group: String, groupIndex: Int, count: Int) -> [String: Any] {
            ["id": "\(prefix)-part-\(index)", "ordinal": index, "type": "toolCall",
             "toolCallId": "\(prefix)-\(index)", "name": "read", "arguments": ["path": "fixture-\(index).txt"],
             "toolSegmentId": prefix, "groupId": group, "groupIndex": groupIndex,
             "groupCount": count, "groupFinalized": true]
        }
        func message(_ id: String, content: [[String: Any]]) -> [String: Any] {
            ["id": id, "presentationId": id, "timestamp": "2026-01-01T00:00:00Z",
             "kind": "message", "role": "assistant", "content": content]
        }
        let firstCount = scenario == "cross-group" ? 2 : 3
        // Last array member is NOT the latest invocation. Cross-group also
        // proves that a new group's index 0 follows the prior group's index 1.
        let indices = firstCount == 3 ? [2, 0, 1] : [1, 0]
        var entries = [message(prefix, content: indices.map {
            call($0, group: prefix, groupIndex: $0, count: firstCount)
        })]
        if scenario == "cross-group" {
            entries.append(message(prefix + "-follow", content: [
                call(2, group: prefix + "-follow", groupIndex: 0, count: 1)
            ]))
        }
        // Latest call completes first. Earlier failure arrives last, with a
        // later startedAt as well: neither mutable timestamp may choose tint.
        for index in [2, 1, 0] where !active || index != 2 {
            let id = "\(prefix)-result-\(index)"
            entries.append(["id": id, "presentationId": id,
                "timestamp": "2026-01-01T00:00:0\(5 - index)Z", "kind": "message", "role": "toolResult",
                "toolCallId": "\(prefix)-\(index)", "toolName": "read", "isError": index == failedIndex,
                "startedAt": "2026-01-01T00:00:0\(2 - index)Z", "durationMs": 2500,
                "content": [["id": id + "-text", "ordinal": 0, "type": "text", "text": "Fixture result \(index)"]]])
        }
        entries.append(message(prefix + "-summary", content: [["id": prefix + "-summary-text", "ordinal": 0,
            "type": "text", "text": "Tool summary review · \(scenario)"]]))
        return try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: entries))
    }
}
#endif
