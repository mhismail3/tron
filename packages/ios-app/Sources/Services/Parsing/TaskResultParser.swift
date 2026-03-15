import Foundation

/// Task manager result parsing for UI display.
enum TaskResultParser {

    // MARK: - TaskManager Parsing

    /// Parse TaskManager tool to create TaskManagerChipData for chip display
    static func parseTaskManager(from tool: ToolUseData) -> TaskManagerChipData? {
        let action = ToolArgumentParser.string("action", from: tool.arguments) ?? "list"
        let taskTitle = ToolArgumentParser.string("title", from: tool.arguments)

        guard tool.result != nil else {
            return TaskManagerChipData(
                toolCallId: tool.toolCallId,
                action: action,
                taskTitle: taskTitle,
                chipSummary: taskManagerRunningSummary(action: action),
                fullResult: nil,
                arguments: tool.arguments,
                entityDetail: nil,
                listResult: nil,
                durationMs: nil,
                status: .running
            )
        }

        let chipSummary = taskManagerChipSummary(action: action, title: taskTitle, result: tool.result)
        let entityDetail = tool.result.flatMap { parseEntityDetail(from: $0, action: action) }
        let listResult = tool.result.flatMap { parseListResult(from: $0, action: action) }
        let batchResult = tool.result.flatMap { parseBatchResult(from: $0, action: action) }

        return TaskManagerChipData(
            toolCallId: tool.toolCallId,
            action: action,
            taskTitle: taskTitle,
            chipSummary: chipSummary,
            fullResult: tool.result,
            arguments: tool.arguments,
            entityDetail: entityDetail,
            listResult: listResult,
            batchResult: batchResult,
            durationMs: tool.durationMs,
            status: .completed
        )
    }

    /// Parse enriched tool result text into a structured EntityDetail snapshot.
    /// Returns nil for list/search/batch actions or malformed input.
    static func parseEntityDetail(from result: String, action: String) -> EntityDetail? {
        let entityActions = Set(["create", "update", "get", "delete", "done", "add_note"])
        guard entityActions.contains(action) else { return nil }

        // Try JSON parsing first (server returns raw JSON objects)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseEntityDetailFromJSON(json)
        }

        let lines = result.components(separatedBy: "\n")

        // Find the "# Title" header line
        guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return nil }
        let title = String(lines[headerIdx].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        // Next line should be "ID: ... | Status: ..." metadata
        let metaIdx = headerIdx + 1
        guard metaIdx < lines.count else { return nil }
        let metaLine = lines[metaIdx]
        let metaParts = metaLine.components(separatedBy: " | ")

        var id = ""
        var status = ""

        for part in metaParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ID:") {
                id = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Status:") {
                status = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !id.isEmpty, !status.isEmpty else { return nil }

        // Parse remaining key-value lines and sections
        var description: String?
        var activeForm: String?
        var parentId: String?
        var createdAt: String?
        var updatedAt: String?
        var startedAt: String?
        var completedAt: String?
        var notes: String?
        var subtasks: [EntityDetail.ListItem] = []
        var activity: [EntityDetail.ActivityItem] = []

        let startIdx = metaIdx + 1

        var descriptionLines: [String] = []
        var notesLines: [String] = []
        var inNotes = false
        var inSubtasks = false
        var inActivity = false

        var i = startIdx
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Section headers reset current context
            if trimmed.hasPrefix("Subtasks (") {
                inSubtasks = true
                inNotes = false; inActivity = false
                i += 1; continue
            }
            if trimmed == "Notes:" || trimmed.hasPrefix("Notes:") {
                inNotes = true
                inSubtasks = false; inActivity = false
                let afterNotes = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !afterNotes.isEmpty { notesLines.append(afterNotes) }
                i += 1; continue
            }
            if trimmed.hasPrefix("Recent activity:") {
                inActivity = true
                inSubtasks = false; inNotes = false
                i += 1; continue
            }

            if inSubtasks {
                if let item = parseListItem(from: trimmed) {
                    subtasks.append(item)
                    i += 1; continue
                }
                if trimmed.isEmpty { i += 1; continue }
                inSubtasks = false
            }

            if inNotes {
                if trimmed.isEmpty && notesLines.isEmpty {
                    i += 1; continue
                }
                if isKnownKey(trimmed) || trimmed.hasPrefix("Subtasks (") || trimmed.hasPrefix("Recent activity:") {
                    inNotes = false
                    continue
                }
                notesLines.append(trimmed)
                i += 1; continue
            }

            if inActivity {
                if let item = parseActivityItem(from: trimmed) {
                    activity.append(item)
                    i += 1; continue
                }
                if trimmed.isEmpty { i += 1; continue }
                inActivity = false
            }

            if trimmed.isEmpty {
                i += 1; continue
            }

            if trimmed.hasPrefix("Active form:") {
                activeForm = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Parent:") {
                parentId = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Created:") {
                createdAt = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Updated:") {
                updatedAt = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Started:") {
                startedAt = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Completed:") {
                completedAt = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if !isKnownKey(trimmed) && description == nil {
                descriptionLines.append(trimmed)
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty || isKnownKey(nextLine) || nextLine.hasPrefix("Subtasks (")
                        || nextLine.hasPrefix("Recent activity:")
                        || nextLine.hasPrefix("Notes:") { break }
                    descriptionLines.append(nextLine)
                    j += 1
                }
                description = descriptionLines.joined(separator: "\n")
                i = j; continue
            }

            i += 1
        }

        if !notesLines.isEmpty {
            notes = notesLines.joined(separator: "\n")
        }

        return EntityDetail(
            title: title,
            id: id,
            status: status,
            activeForm: activeForm,
            description: description,
            notes: notes,
            parentId: parentId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            subtasks: subtasks,
            activity: activity
        )
    }

    /// Parse an EntityDetail from a JSON dictionary (raw server response).
    private static func parseEntityDetailFromJSON(_ json: [String: Any]) -> EntityDetail? {
        let title = json["title"] as? String ?? ""
        var id = json["id"] as? String ?? ""
        var status = json["status"] as? String ?? ""

        // Handle success-confirmation responses: { "success": true, "taskId": "..." }
        if id.isEmpty, json["success"] != nil {
            id = (json["taskId"] as? String) ?? ""
            if status.isEmpty {
                let success = json["success"] as? Bool ?? false
                status = success ? "confirmed" : "failed"
            }
        }

        guard !id.isEmpty, !status.isEmpty else { return nil }

        let activeForm = json["activeForm"] as? String
        let description = json["description"] as? String
        let notes = json["notes"] as? String
        let parentId = json["parentTaskId"] as? String
        let createdAt = json["createdAt"] as? String
        let updatedAt = json["updatedAt"] as? String
        let startedAt = json["startedAt"] as? String
        let completedAt = json["completedAt"] as? String

        return EntityDetail(
            title: title,
            id: id,
            status: status,
            activeForm: activeForm,
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            notes: notes.flatMap { $0.isEmpty ? nil : $0 },
            parentId: parentId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            subtasks: [],
            activity: []
        )
    }

    /// Parse a list item like "  [x] task_abc: Title"
    private static func parseListItem(from line: String) -> EntityDetail.ListItem? {
        guard let match = line.firstMatch(of: /\[([x> ?\-])\]\s+([\w_-]+):\s+(.+)/) else { return nil }
        let mark = String(match.1)
        let id = String(match.2)
        let titleAndExtra = String(match.3).trimmingCharacters(in: .whitespaces)

        var extra: String?
        var title = titleAndExtra
        if let extraMatch = titleAndExtra.firstMatch(of: /\s+(\[\w+\])$/) {
            extra = String(extraMatch.1)
            title = String(titleAndExtra[titleAndExtra.startIndex..<extraMatch.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }

        return EntityDetail.ListItem(mark: mark, id: id, title: title, extra: extra)
    }

    /// Parse an activity item like "  2026-02-11: created - detail"
    private static func parseActivityItem(from line: String) -> EntityDetail.ActivityItem? {
        guard let match = line.firstMatch(of: /(\d{4}-\d{2}-\d{2}):\s+(\S+)(?:\s+-\s+(.+))?/) else { return nil }
        return EntityDetail.ActivityItem(
            date: String(match.1),
            action: String(match.2),
            detail: match.3.map { String($0).trimmingCharacters(in: .whitespaces) }
        )
    }

    /// Check if a line starts with a known key prefix
    private static func isKnownKey(_ line: String) -> Bool {
        let keys = ["Active form:", "Parent:", "Created:", "Updated:", "Started:", "Completed:", "ID:"]
        return keys.contains(where: { line.hasPrefix($0) })
    }

    // MARK: - List Result Parsing

    /// Parse list/search result text into structured ListResult.
    static func parseListResult(from result: String, action: String) -> ListResult? {
        let listActions = Set(["list", "search"])
        guard listActions.contains(action) else { return nil }

        if result.hasPrefix("No ") && result.hasSuffix(" found.") {
            return .empty(result)
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseListResultFromJSON(json, action: action)
        }

        let lines = result.components(separatedBy: "\n")
        switch action {
        case "list":
            return parseTaskList(lines: lines)
        case "search":
            return parseSearchResults(lines: lines)
        default:
            return nil
        }
    }

    /// Parse a list result from a JSON dictionary.
    private static func parseListResultFromJSON(_ json: [String: Any], action: String) -> ListResult? {
        guard let tasksArray = json["tasks"] as? [[String: Any]] else { return nil }
        if tasksArray.isEmpty { return .empty("No tasks found.") }
        if action == "search" {
            let items = tasksArray.compactMap { task -> SearchResultItem? in
                guard let id = task["id"] as? String,
                      let title = task["title"] as? String else { return nil }
                let status = task["status"] as? String ?? "pending"
                return SearchResultItem(itemId: id, title: title, status: status)
            }
            return items.isEmpty ? .empty("No tasks found.") : .searchResults(items)
        } else {
            let items = tasksArray.compactMap { task -> TaskListItem? in
                guard let id = task["id"] as? String,
                      let title = task["title"] as? String else { return nil }
                let status = task["status"] as? String ?? "pending"
                let mark: String
                switch status {
                case "completed": mark = "x"
                case "in_progress": mark = ">"
                case "cancelled": mark = "-"
                case "stale": mark = "?"
                default: mark = " "
                }
                return TaskListItem(taskId: id, title: title, mark: mark, status: status)
            }
            return items.isEmpty ? .empty("No tasks found.") : .tasks(items)
        }
    }

    /// Parse task list text format
    private static func parseTaskList(lines: [String]) -> ListResult? {
        var items: [TaskListItem] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let match = trimmed.firstMatch(of: /\[([x> ?\-])\]\s+(.+?):\s+(.+)/) else { continue }
            let mark = String(match.1)
            let id = String(match.2)
            let title = String(match.3).trimmingCharacters(in: .whitespaces)

            items.append(TaskListItem(taskId: id, title: title, mark: mark, status: nil))
        }
        return items.isEmpty ? .empty("No tasks found.") : .tasks(items)
    }

    /// Parse search results text format
    private static func parseSearchResults(lines: [String]) -> ListResult? {
        var items: [SearchResultItem] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let match = trimmed.firstMatch(of: /(.+?):\s+(.+?)\s+\[(\w+)\]/) else { continue }
            items.append(SearchResultItem(
                itemId: String(match.1),
                title: String(match.2),
                status: String(match.3)
            ))
        }
        return items.isEmpty ? .empty("No tasks found.") : .searchResults(items)
    }

    // MARK: - Batch Result Parsing

    /// Parse batch_create result JSON into a `BatchResult`.
    static func parseBatchResult(from result: String, action: String) -> BatchResult? {
        guard action == "batch_create" else { return nil }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let affected = json["affected"] as? Int ?? 0
        let ids = json["ids"] as? [String] ?? []

        return BatchResult(affected: affected, ids: ids)
    }

    // MARK: - Chip Summaries

    /// Running state summary for chip
    private static func taskManagerRunningSummary(action: String) -> String {
        switch action {
        case "create": return "Creating task..."
        case "update": return "Updating task..."
        case "delete": return "Deleting task..."
        case "list": return "Listing tasks..."
        case "search": return "Searching tasks..."
        case "get": return "Getting task..."
        case "done": return "Completing task..."
        case "add_note": return "Adding note..."
        case "batch_create": return "Creating tasks..."
        default: return "Managing tasks..."
        }
    }

    /// Completed state summary for chip
    private static func taskManagerChipSummary(action: String, title: String?, result: String?) -> String {
        let name = title ?? extractEntityName(from: result)
        let truncated = name.map { $0.count > 30 ? String($0.prefix(30)) + "..." : $0 }

        switch action {
        case "create":
            if let t = truncated { return "Created task \"\(t)\"" }
            return "Created task"
        case "update":
            if let t = truncated { return "Updated task \"\(t)\"" }
            return "Updated task"
        case "delete":
            if let t = truncated { return "Deleted task \"\(t)\"" }
            return "Deleted task"
        case "get":
            if let t = truncated { return "Task \"\(t)\"" }
            return "Task details"
        case "done":
            if let t = truncated { return "Completed \"\(t)\"" }
            return "Task completed"
        case "add_note":
            if let t = truncated { return "Note on \"\(t)\"" }
            return "Note added"
        case "list", "search":
            if let count = extractListCount(from: result) {
                if action == "search" {
                    return "\(count) result\(count == 1 ? "" : "s")"
                }
                return "\(count) task\(count == 1 ? "" : "s")"
            }
            return action == "search" ? "Search complete" : "Tasks listed"
        case "batch_create":
            if let count = extractBatchAffected(from: result) {
                return "Created \(count) task\(count == 1 ? "" : "s")"
            }
            return "Batch created"
        default:
            return "Done"
        }
    }

    /// Extract entity name from tool result.
    private static func extractEntityName(from result: String?) -> String? {
        guard let result else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String,
           !title.isEmpty {
            return title
        }

        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
        if firstLine.hasPrefix("# ") {
            let title = String(firstLine.dropFirst(2))
            return title.isEmpty ? nil : title
        }

        return nil
    }

    /// Extract count from list results.
    private static func extractListCount(from result: String?) -> Int? {
        guard let result else { return nil }

        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["tasks"] as? [Any] {
            return items.count
        }

        return nil
    }

    /// Extract `affected` count from batch result JSON.
    private static func extractBatchAffected(from result: String?) -> Int? {
        guard let result else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["affected"] as? Int
    }
}
