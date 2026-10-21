import Foundation
import TronMobileCore

// MARK: - delegate

extension HomeToolDetailPresentation {
    static func delegate(_ call: Call) -> HomeToolDetailPresentation? {
        guard let taskID = call.string("taskId"), let intent = call.string("intent") else { return nil }
        let target = call.string("target")
        let title = call.string("title") ?? HomeChapterPresentation.topicPreview(intent, limit: 80)
        let subtitle = [target.map(basename), taskID].compactMap { $0 }.joined(separator: " · ")
        let queue = call.details?["queuePosition"]?.intValue
        let header: Header
        if call.running { header = runningHeader(icon: "paperplane", title: title, subtitle: subtitle) }
        else if call.error { header = Header(icon: "paperplane", title: title, subtitle: subtitle, pill: "Refused", tone: .failure) }
        else if let queue { header = Header(icon: "paperplane", title: title, subtitle: subtitle, pill: "Queued #\(queue)", tone: .pending) }
        else { header = Header(icon: "paperplane", title: title, subtitle: subtitle, pill: "Admitted", tone: .success) }

        var sections: [Section] = []
        if let failure = call.failure { sections.append(failure) }
        var task: [Row] = []
        if let target { task.append(Row(icon: "folder", title: "Project", value: target)) }
        if let queue { task.append(Row(icon: "list.number", title: "Queue position", value: "\(queue) · starts when a worker slot frees")) }
        if let session = call.detail("sessionId") { task.append(Row(icon: "bubble.left.and.text.bubble.right", title: "Worker session", value: session)) }
        if let operation = call.detail("operationId") { task.append(Row(icon: "gearshape.2", title: "Operation", value: operation)) }
        if !task.isEmpty { sections.append(.rows(title: "Task", detail: nil, rows: task)) }

        let worker = call.details?["worker"]?.objectValue
        let requestedModel = call.arguments["model"]?.objectValue.flatMap { object -> String? in
            guard let provider = object["provider"]?.stringValue, let id = object["id"]?.stringValue else { return nil }
            return "\(provider)/\(id)"
        }
        let requestedThinking = call.string("thinking")
        var workerRows: [Row] = []
        if let model = worker?["model"]?.stringValue ?? requestedModel {
            let source = (worker?["modelSource"]?.stringValue ?? (requestedModel == nil ? nil : "explicit"))?.components(separatedBy: ":").first
            workerRows.append(Row(icon: "cpu", title: "Model", value: [modelName(model), source].compactMap { $0 }.joined(separator: " · ")))
        } else if worker == nil, !call.error {
            workerRows.append(Row(icon: "cpu", title: "Model", value: "Home's worker profile"))
        }
        if let thinking = worker?["thinking"]?.stringValue ?? requestedThinking {
            let source = (worker?["thinkingSource"]?.stringValue ?? (requestedThinking == nil ? nil : "explicit"))?.components(separatedBy: ":").first
            workerRows.append(Row(icon: "brain.head.profile", title: "Thinking", value: [thinking.capitalized, source].compactMap { $0 }.joined(separator: " · ")))
        }
        if let note = worker?["note"]?.stringValue { workerRows.append(Row(icon: "info.circle", title: "Note", value: note)) }
        if let reason = call.string("reason") { workerRows.append(Row(icon: "text.quote", title: "Reason", value: reason)) }
        if !workerRows.isEmpty { sections.append(.rows(title: "Worker", detail: nil, rows: workerRows)) }
        let subagents = (call.details?["subagentModels"]?.arrayValue ?? []).compactMap { value -> Row? in
            guard let item = value.objectValue,
                  let model = item["model"]?.stringValue,
                  let available = item["available"]?.boolValue else { return nil }
            let status = available ? "Available" : "Skipped"
            let reason = item["reason"]?.stringValue
            return Row(icon: available ? "checkmark.circle" : "minus.circle",
                       title: modelName(model),
                       value: [status, available ? nil : reason].compactMap { $0 }.joined(separator: " · "))
        }
        if !subagents.isEmpty { sections.append(.rows(title: "Subagent models", detail: nil, rows: subagents)) }
        sections.append(.text(id: "brief", title: "Brief", text: intent))
        return HomeToolDetailPresentation(header: header, sections: sections)
    }
}
