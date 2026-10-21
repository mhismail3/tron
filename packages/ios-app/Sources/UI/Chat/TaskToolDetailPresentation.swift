import Foundation
import TronMobileCore

// MARK: - task

extension HomeToolDetailPresentation {
    static func task(_ call: Call) -> HomeToolDetailPresentation? {
        let action = call.string("action")
        let taskID = call.string("taskId")
        guard let action, ["list", "status", "report", "steer", "interrupt", "resume", "stop", "rename"].contains(action) else { return nil }
        let targetTitle = call.detail("title") ?? taskID
        let (icon, title): (String, String) = switch action {
        case "status": ("list.bullet.clipboard", "Task status")
        case "report": ("doc.text", "Task report")
        case "steer": ("arrow.turn.down.right", "Steer task")
        case "interrupt": ("pause.circle", "Interrupt task")
        case "rename": ("pencil", "Rename task")
        case "stop": ("stop.circle", "Stop task")
        case "resume": ("play.circle", "Resume task")
        default: ("checklist", "Task")
        }
        var sections: [Section] = []
        if let failure = call.failure { sections.append(failure) }
        var identity: [Row] = []
        if let operation = call.string("operationId") {
            identity.append(Row(icon: "gearshape.2", title: "Operation", value: operation))
        }

        if call.running {
            if !identity.isEmpty { sections.append(.rows(title: nil, detail: nil, rows: identity)) }
            if let text = call.string("text") { sections.append(.prompt(id: "message", title: action == "resume" ? "Instruction" : "Message", text: text)) }
            return HomeToolDetailPresentation(header: runningHeader(icon: icon, title: title, subtitle: taskID), sections: sections)
        }
        if call.error {
            if !identity.isEmpty { sections.append(.rows(title: "Request", detail: nil, rows: identity)) }
            if let text = call.string("text") { sections.append(.prompt(id: "message", title: action == "resume" ? "Instruction" : "Message", text: text)) }
            let rejected = call.text.hasPrefix("Validation failed")
            return HomeToolDetailPresentation(header: Header(icon: icon, title: title, subtitle: taskID,
                                                             pill: rejected ? "Rejected" : "Refused", tone: .failure), sections: sections)
        }

        switch action {
        case "status" where taskID == nil:
            return taskList(call)
        case "list":
            return taskList(call)
        case "status":
            guard let taskID, let details = call.details,
                  let status = try? HomeTaskDTO.decode(.object(details), taskID: taskID) else { return nil }
            return taskStatus(status, details: details, icon: icon)
        case "report":
            guard let details = call.details, let page = details["text"]?.stringValue,
                  let offset = details["offset"]?.intValue, let total = details["bytes"]?.intValue else { return nil }
            return taskReport(page: page, offset: offset, total: total, next: details["nextOffset"]?.intValue,
                              identity: identity, icon: icon, taskID: taskID)
        case "steer", "interrupt", "stop", "resume", "rename":
            guard let accepted = call.details?["accepted"]?.boolValue else { return nil }
            if !accepted {
                let reason = call.detail("reason") ?? call.text
                return HomeToolDetailPresentation(
                    header: Header(icon: icon, title: title, subtitle: targetTitle, pill: "Refused", tone: .failure),
                    sections: [.failure(title: "Refused", message: reason, issues: [])])
            }
            if action == "rename", let renamed = call.detail("title") ?? call.string("title") {
                identity.append(Row(icon: "pencil", title: "New title", value: renamed))
            }
            if action == "resume" {
                if let next = call.detail("taskId"), next != taskID { identity.append(Row(icon: "arrow.forward.circle", title: "Continues as task", value: next)) }
                if let session = call.detail("sessionId") { identity.append(Row(icon: "bubble.left.and.text.bubble.right", title: "Worker session", value: session)) }
                if let operation = call.detail("operationId") { identity.append(Row(icon: "gearshape.2", title: "New operation", value: operation)) }
            }
            let effect = switch action {
            case "steer": "Delivered to the worker's running operation."
            case "stop": "Stop recorded for this exact operation."
            case "interrupt": call.details?["interrupted"]?.boolValue == false ? "No command was running to interrupt." : "The worker's current command was interrupted."
            case "rename": "Task renamed."
            default: "The task continues in place in its worker session."
            }
            if !identity.isEmpty { sections.append(.rows(title: nil, detail: nil, rows: identity)) }
            if let text = call.string("text") {
                sections.append(.prompt(id: "message", title: action == "resume" ? "Instruction" : "Message", text: text, detail: effect))
            } else {
                // Stop may have no message; retain its effect without an empty identity card.
                sections.append(.rows(title: nil, detail: effect, rows: []))
            }
            return HomeToolDetailPresentation(header: Header(icon: icon, title: title, subtitle: targetTitle, pill: "Accepted", tone: .success),
                                              sections: sections)
        default:
            return nil
        }
    }

    /// Control rows intentionally carry no model: never borrow the current Home
    /// model for a historical worker. Show only fields recorded in this result.
    private static func taskList(_ call: Call) -> HomeToolDetailPresentation? {
        guard let details = call.details, let tasks = details["tasks"]?.arrayValue,
              let counts = details["counts"]?.objectValue,
              let active = counts["active"]?.intValue, active >= 0,
              let finished = counts["finished"]?.intValue, finished >= 0,
              let more = details["more"]?.boolValue else { return nil }
        var rows: [TaskRow] = []
        for value in tasks {
            guard let task = value.objectValue, let id = task["taskId"]?.stringValue, !id.isEmpty,
                  let state = task["state"]?.stringValue, ["starting", "running", "settled"].contains(state) else { return nil }
            let outcome = task["outcome"]?.stringValue
            let checkin = task["checkins"]?.arrayValue?.last?.objectValue
            let attention = outcome == "needs-input" || checkin?["blocker"]?.stringValue != nil
            let label = attention ? "Needs attention" : state == "starting" ? "Starting" : state == "running" ? "Running" : outcome == "final" ? "Finished" : outcome == "interrupted" ? "Stopped" : "Needs attention"
            let tone: Tone = label == "Needs attention" ? .failure : state == "starting" ? .pending : label == "Stopped" ? .neutral : .success
            var lines: [String] = []
            if let checkin {
                let text = ["step", "done", "next", "blocker"].compactMap { checkin[$0]?.stringValue }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !text.isEmpty { lines.append(text) }
            }
            if let at = checkin?["at"]?.stringValue ?? task["updatedAt"]?.stringValue {
                lines.append(relativeTaskTime(at))
            }
            rows.append(TaskRow(id: id, title: task["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                subtitle: lines.isEmpty ? nil : lines.joined(separator: "\n"), state: label, tone: tone))
        }
        guard Set(rows.map(\.id)).count == rows.count else { return nil }
        let summary = "\(active.formatted()) running · \(finished.formatted()) finished"
        return HomeToolDetailPresentation(
            header: Header(icon: "checklist", title: "Tasks", subtitle: summary, pill: "Listed", tone: .neutral),
            sections: [.tasks(summary: "\(count(rows.count, "task")) shown", footer: more ? "More tasks are available." : nil, rows: rows)])
    }

    private static func relativeTaskTime(_ at: String) -> String {
        guard let date = HomeChapterPresentation.parse(at) else { return at }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    private static func taskStatus(_ task: HomeTaskDTO, details: [String: JSONValue], icon: String) -> HomeToolDetailPresentation {
        let outcome = task.terminalEvidence?.outcome
        let tone: Tone = switch task.lifecycle {
        case .pending: .pending
        case .active: .success
        case .terminal: outcome == .final ? .success : outcome == .interrupted ? .neutral : .failure
        }
        let stateLabel = task.lifecycle == .active ? "Running" : task.lifecycle == .pending ? "Starting" : outcome == .final ? "Finished" : outcome == .interrupted ? "Stopped" : "Needs attention"
        let header = Header(icon: icon, title: task.title ?? task.taskId,
                            subtitle: [task.project, task.taskId].compactMap { $0 }.joined(separator: " · "),
                            pill: stateLabel, tone: tone)
        var state: [Row] = []
        if let terminal = task.terminalEvidence {
            state.append(Row(icon: "flag.checkered", title: "Result", value: "\(terminal.outcome.rawValue.capitalized) · \(terminal.reason)"))
        }
        let duration = max(0, task.updatedAt - task.createdAt)
        state.append(Row(icon: "timer", title: task.lifecycle == .terminal ? "Duration" : "Running for", value: ToolTiming.format(milliseconds: duration)))
        if let queue = details["queuePosition"]?.intValue { state.append(Row(icon: "list.number", title: "Queue position", value: "\(queue)")) }
        if let operation = task.operationId { state.append(Row(icon: "gearshape.2", title: "Operation", value: operation)) }
        var worker: [Row] = []
        for checkin in task.checkins ?? [] {
            worker.append(Row(icon: "text.bubble", title: "Check-in", value: HomeTaskPresentation.checkinText(checkin)))
        }
        if let model = task.workerModel { worker.append(Row(icon: "cpu", title: "Model", value: model.displayName)) }
        if let spend = task.spend {
            worker.append(Row(icon: "gauge.with.dots.needle.33percent", title: "Tokens",
                              value: HomeTaskPresentation.spendText(spend)))
        }
        if let subagents = task.subagents {
            let started = "\(subagents.started.formatted()) started"
            worker.append(Row(icon: "person.2", title: "Subagents",
                              value: subagents.stoppedAtEnd.map { "\(started) · \($0.formatted()) stopped at end" } ?? started))
        }
        if let runs = task.subagentRuns, runs.total > 0 {
            worker.append(Row(icon: "person.crop.circle.badge.clock", title: "Live runs",
                              value: runs.runs.map { "\($0.agent) (\($0.state))" }.joined(separator: ", ") + (runs.total > runs.runs.count ? " and \(runs.total - runs.runs.count) more" : "")))
        }
        if let session = task.workerSessionId { worker.append(Row(icon: "bubble.left.and.text.bubble.right", title: "Worker session", value: session)) }
        var sections: [Section] = [.rows(title: "State", detail: nil, rows: state)]
        if !worker.isEmpty { sections.append(.rows(title: "Worker", detail: nil, rows: worker)) }
        sections.append(.text(id: "brief", title: "Brief", text: task.intent.text))
        return HomeToolDetailPresentation(header: header, sections: sections)
    }

    /// One byte page of the task's immutable report. The Gateway pages the report's
    /// JSON, so the page's `text` value is decoded as far as this page carries it.
    private static func taskReport(page: String, offset: Int, total: Int, next: Int?, identity: [Row], icon: String,
                                   taskID: String?) -> HomeToolDetailPresentation? {
        guard offset >= 0, total >= offset else { return nil }
        let end = next ?? total
        guard end >= offset, end <= total else { return nil }
        let report = TaskReportPage(page: page, offset: offset)
        guard let text = report.text else { return nil }
        var rows = identity
        rows.append(Row(icon: "doc.plaintext", title: "Page", value: "Bytes \(offset.formatted())–\(end.formatted()) of \(total.formatted())"))
        let outcomeLabel = report.outcome.map { $0 == "needs-input" ? "Needs attention" : $0.replacingOccurrences(of: "-", with: " ").capitalized }
        if let outcomeLabel { rows.append(Row(icon: "flag.checkered", title: "Outcome", value: outcomeLabel)) }
        if let result = report.resultID { rows.append(Row(icon: "seal", title: "Result ID", value: result)) }
        let detail = next.map { "Home reads the rest from byte \($0.formatted())." }
        var sections: [Section] = [.rows(title: nil, detail: detail, rows: rows)]
        sections.append(.prompt(id: "report", title: report.complete ? "Report" : "Report (this page)", text: text))
        let pill = outcomeLabel ?? (next == nil ? "Last page" : "Page")
        let tone: Tone = report.outcome == "needs-input" ? .failure : .neutral
        return HomeToolDetailPresentation(header: Header(icon: icon, title: taskID ?? "Task report", subtitle: "Task report", pill: pill, tone: tone),
                                          sections: sections)
    }
}

/// The report fields one byte page of a report's JSON carries. A whole report
/// parses as JSON; a partial page decodes the `text` string as far as it goes.
struct TaskReportPage: Hashable, Sendable {
    let outcome: String?
    let resultID: String?
    let text: String?
    let complete: Bool

    init(page: String, offset: Int) {
        if offset == 0, let data = page.data(using: .utf8),
           let object = try? JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue {
            outcome = object["outcome"]?.stringValue
            resultID = object["resultId"]?.stringValue
            text = object["text"]?.stringValue
            complete = true
            return
        }
        outcome = offset == 0 ? Self.field("outcome", in: page) : nil
        resultID = offset == 0 ? Self.field("resultId", in: page) : nil
        complete = false
        if let start = page.range(of: "\"text\":\"") {
            text = Self.decodeString(page[start.upperBound...])
        } else if offset > 0 {
            // A later page usually continues the text value.
            text = Self.decodeString(page[...])
        } else {
            text = nil
        }
    }

    private static func field(_ name: String, in page: String) -> String? {
        guard let start = page.range(of: "\"\(name)\":\"") else { return nil }
        return decodeString(page[start.upperBound...])
    }

    /// Decodes JSON string escapes up to the closing quote or the end of the page.
    private static func decodeString(_ source: Substring) -> String {
        var result = ""
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            if character == "\"" { break }
            guard character == "\\" else { result.append(character); continue }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": break
            case "u":
                var hex = ""
                for _ in 0..<4 { if let digit = iterator.next() { hex.append(digit) } }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { result.append(Character(scalar)) }
            default: result.append(escaped)
            }
        }
        return result
    }
}

