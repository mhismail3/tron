#if HOSTED_TEST
import Foundation
import TronMobileCore

/// Synthetic socket evidence for lineage/history UI journeys; never live user data.
enum HostedHomeTaskHistoryFixture {
    private static let now = Date().timeIntervalSince1970
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-home-task-history-review") }
    static func checkin(_ index: Int) -> JSONValue {
        .object([
            "id": .string("history-checkin-\(index)"), "taskId": .string(index > 10 ? "active" : "terminal"),
            "sessionId": .string("worker-session"), "operationId": .string(index > 10 ? "task-operation" : "task-original"),
            "at": .string(Date(timeIntervalSince1970: now - (index > 10 ? 360 + Double(22 - index) * 180 : (210 - Double(index) * 3) * 60)).formatted(.iso8601)),
            "step": .string(index == 22 ? "Visual review ready" : "Validation milestone \(index)"),
            "done": .string("Clean 99a69ce97\nrc65 uncapped 289.538s"),
            "next": .string("Review the same 4 light/dark captures."),
            "blocker": .string("Maintainer visual approval needed."), "needsAttention": .bool(true), "attention": .string("requested"),
            "refs": .object(["branch": .string("fix/task-history"), "commit": .string("99a69ce97"), "issue": .string("#2073")])
        ])
    }
    static func row(_ base: JSONValue) -> JSONValue {
        var row = base.objectValue!
        row["title"] = .string("Restructure #1345 · Phase 3")
        row["checkins"] = .array([checkin(22)])
        row["attention"] = .bool(true)
        return .object(row)
    }
    static func history(_ params: [String: JSONValue]) -> JSONValue {
        let checkins: [JSONValue] = (0...22).reversed().map { index in
            let value = checkin(index)
            let current = index > 10
            let record: [String: JSONValue] = [
                "id": .string("history-checkin-\(index)"), "at": value.objectValue!["at"]!,
                "taskId": .string(current ? "active" : "terminal"), "operationId": .string(current ? "task-operation" : "task-original"),
                "operationNumber": .number(current ? 3 : 1), "lifecycle": .string(current ? "active" : "terminal"),
                "outcome": current ? .null : .string("needs-input"), "checkin": value]
            return .object(record)
        }
        let operations: [JSONValue] = [3, 2, 1].map { number in
            let record: [String: JSONValue] = [
                "id": .string("operation-\(number)"),
                "at": .string(Date(timeIntervalSince1970: now - (number == 3 ? 120 : number == 2 ? 165 : 240) * 60).formatted(.iso8601)),
                "taskId": .string(number == 3 ? "active" : number == 2 ? "empty-resume" : "terminal"),
                "operationId": .string(number == 3 ? "task-operation" : number == 2 ? "task-gap" : "task-original"),
                "operationNumber": .number(Double(number)), "lifecycle": .string(number == 3 ? "active" : "terminal"),
                "outcome": number == 3 ? .null : .string("needs-input")]
            return .object(record)
        }
        let all = (checkins + operations).sorted { $0.objectValue!["at"]!.stringValue! > $1.objectValue!["at"]!.stringValue! }
        let offset = params["cursor"]?.stringValue.flatMap(Int.init) ?? 0
        let end = min(offset + (params["limit"]?.intValue ?? 20), all.count)
        var page: [String: JSONValue] = ["items": .array(Array(all[offset..<end])), "total": .number(Double(all.count)), "complete": .bool(true)]
        if end < all.count { page["nextCursor"] = .string(String(end)) }
        return .object(page)
    }
}
#endif
