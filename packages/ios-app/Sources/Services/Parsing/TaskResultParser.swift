import Foundation

/// Task manager and list result parsing, extracted from ToolResultParser.
/// Handles parsing of TaskManager tool results into structured data for UI display.
enum TaskResultParser {

    // MARK: - TaskManager Parsing

    /// Parse TaskManager tool to create TaskManagerChipData for chip display
    static func parseTaskManager(from tool: ToolUseData) -> TaskManagerChipData? {
        let action = ToolArgumentParser.string("action", from: tool.arguments) ?? "list"
        let taskTitle = ToolArgumentParser.string("title", from: tool.arguments)
            ?? ToolArgumentParser.string("projectTitle", from: tool.arguments)
            ?? ToolArgumentParser.string("areaTitle", from: tool.arguments)

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
    /// Returns nil for list/search actions or malformed input.
    /// Supports both text format (`# Title\nID: ... | Status: ...`) and JSON format.
    static func parseEntityDetail(from result: String, action: String) -> EntityDetail? {
        // Skip list/search actions — no entity to parse
        let entityActions = Set(["create", "update", "get", "delete", "log_time",
                                 "create_project", "update_project", "get_project", "delete_project",
                                 "create_area", "update_area", "get_area", "delete_area"])
        guard entityActions.contains(action) else { return nil }

        // Determine entity type from action
        let entityType: EntityDetail.EntityType
        if action.contains("project") {
            entityType = .project
        } else if action.contains("area") {
            entityType = .area
        } else {
            entityType = .task
        }

        // Try JSON parsing first (server may return raw JSON objects)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseEntityDetailFromJSON(json, entityType: entityType)
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

        // Parse ID from first part: "ID: task_abc"
        var id = ""
        var status = ""
        var priority: String?
        var taskCount: Int?
        var completedTaskCount: Int?

        for part in metaParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ID:") {
                id = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Status:") {
                status = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Priority:") {
                priority = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if let match = trimmed.firstMatch(of: /(\d+)\/(\d+)\s+tasks/) {
                completedTaskCount = Int(match.1)
                taskCount = Int(match.2)
            }
        }
        guard !id.isEmpty, !status.isEmpty else { return nil }

        // Parse area counts line (for areas): "N projects, M tasks (K active)"
        var projectCount: Int?
        var areaTaskCount: Int?
        var activeTaskCount: Int?
        if entityType == .area {
            let countsIdx = metaIdx + 1
            if countsIdx < lines.count {
                let countsLine = lines[countsIdx]
                if let match = countsLine.firstMatch(of: /(\d+)\s+project/) {
                    projectCount = Int(match.1)
                }
                if let match = countsLine.firstMatch(of: /(\d+)\s+task/) {
                    areaTaskCount = Int(match.1)
                }
                if let match = countsLine.firstMatch(of: /\((\d+)\s+active\)/) {
                    activeTaskCount = Int(match.1)
                }
            }
        }

        // Parse remaining key-value lines and sections
        var description: String?
        var activeForm: String?
        var projectName: String?
        var areaName: String?
        var parentId: String?
        var dueDate: String?
        var deferredUntil: String?
        var estimatedMinutes: Int?
        var actualMinutes: Int?
        var tags: [String] = []
        var source: String?
        var createdAt: String?
        var updatedAt: String?
        var startedAt: String?
        var completedAt: String?
        var notes: String?
        var subtasks: [EntityDetail.ListItem] = []
        var tasks: [EntityDetail.ListItem] = []
        var blockedBy: [String] = []
        var blocks: [String] = []
        var activity: [EntityDetail.ActivityItem] = []

        // Start parsing after the metadata line(s)
        var startIdx = metaIdx + 1
        if entityType == .area { startIdx = metaIdx + 2 } // skip counts line

        // Description: first non-empty line after metadata that isn't a known key
        var descriptionLines: [String] = []
        var notesLines: [String] = []
        var inNotes = false
        var inSubtasks = false
        var inTasks = false
        var inActivity = false

        var i = startIdx
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Section headers reset current context
            if trimmed.hasPrefix("Subtasks (") {
                inSubtasks = true
                inTasks = false; inNotes = false; inActivity = false
                i += 1; continue
            }
            if trimmed.hasPrefix("Tasks (") {
                inTasks = true
                inSubtasks = false; inNotes = false; inActivity = false
                i += 1; continue
            }
            if trimmed == "Notes:" || trimmed.hasPrefix("Notes:") {
                inNotes = true
                inSubtasks = false; inTasks = false; inActivity = false
                // Check for inline content after "Notes:"
                let afterNotes = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !afterNotes.isEmpty { notesLines.append(afterNotes) }
                i += 1; continue
            }
            if trimmed.hasPrefix("Recent activity:") {
                inActivity = true
                inSubtasks = false; inTasks = false; inNotes = false
                i += 1; continue
            }

            // Parse list items in sections
            if inSubtasks || inTasks {
                if let item = parseListItem(from: trimmed) {
                    if inSubtasks { subtasks.append(item) }
                    else { tasks.append(item) }
                    i += 1; continue
                }
                if trimmed.isEmpty { i += 1; continue }
                // Non-list-item, non-empty line ends section
                inSubtasks = false; inTasks = false
            }

            if inNotes {
                if trimmed.isEmpty && notesLines.isEmpty {
                    i += 1; continue // skip leading blank
                }
                // Notes end at a known key or section
                if isKnownKey(trimmed) || trimmed.hasPrefix("Subtasks (") || trimmed.hasPrefix("Tasks (") || trimmed.hasPrefix("Recent activity:") {
                    inNotes = false
                    // Don't advance — re-process this line
                    continue
                }
                notesLines.append(trimmed)
                i += 1; continue
            }

            if inActivity {
                // Activity items: "  2026-02-11: created - detail"
                if let item = parseActivityItem(from: trimmed) {
                    activity.append(item)
                    i += 1; continue
                }
                if trimmed.isEmpty { i += 1; continue }
                inActivity = false
            }

            // Key-value parsing
            if trimmed.isEmpty {
                i += 1; continue
            }

            if trimmed.hasPrefix("Active form:") {
                activeForm = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Project:") {
                projectName = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Area:") {
                areaName = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Parent:") {
                parentId = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Due:") {
                dueDate = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Deferred until:") {
                deferredUntil = String(trimmed.dropFirst(15)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Time:") {
                let timeStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let match = timeStr.firstMatch(of: /(\d+)\/(\d+)min/) {
                    actualMinutes = Int(match.1)
                    estimatedMinutes = Int(match.2)
                }
            } else if trimmed.hasPrefix("Tags:") {
                let tagStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                tags = tagStr.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if trimmed.hasPrefix("Source:") {
                source = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Created:") {
                createdAt = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Updated:") {
                updatedAt = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Started:") {
                startedAt = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Completed:") {
                completedAt = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Blocked by:") {
                let ids = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                blockedBy = ids.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if trimmed.hasPrefix("Blocks:") {
                let ids = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                blocks = ids.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if !isKnownKey(trimmed) && description == nil {
                // First unrecognized non-empty line is the description
                descriptionLines.append(trimmed)
                // Collect multi-line description
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty || isKnownKey(nextLine) || nextLine.hasPrefix("Subtasks (")
                        || nextLine.hasPrefix("Tasks (") || nextLine.hasPrefix("Recent activity:")
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
            entityType: entityType,
            title: title,
            id: id,
            status: status,
            priority: priority,
            source: source,
            activeForm: activeForm,
            description: description,
            notes: notes,
            tags: tags,
            projectName: projectName,
            areaName: areaName,
            parentId: parentId,
            dueDate: dueDate,
            deferredUntil: deferredUntil,
            estimatedMinutes: estimatedMinutes,
            actualMinutes: actualMinutes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            taskCount: entityType == .area ? areaTaskCount : taskCount,
            completedTaskCount: completedTaskCount,
            projectCount: projectCount,
            activeTaskCount: activeTaskCount,
            subtasks: subtasks,
            tasks: tasks,
            blockedBy: blockedBy,
            blocks: blocks,
            activity: activity
        )
    }

    /// Parse an EntityDetail from a JSON dictionary (raw server response).
    /// Handles both full entity JSON and success-confirmation JSON (delete/log_time).
    private static func parseEntityDetailFromJSON(_ json: [String: Any], entityType: EntityDetail.EntityType) -> EntityDetail? {
        let title = json["title"] as? String ?? ""
        var id = json["id"] as? String ?? ""
        var status = json["status"] as? String ?? ""

        // Handle success-confirmation responses: { "success": true, "taskId": "..." }
        if id.isEmpty, json["success"] != nil {
            id = (json["taskId"] as? String)
                ?? (json["projectId"] as? String)
                ?? (json["areaId"] as? String)
                ?? ""
            if status.isEmpty {
                let success = json["success"] as? Bool ?? false
                status = success ? "confirmed" : "failed"
            }
        }

        guard !id.isEmpty, !status.isEmpty else { return nil }

        let priority = json["priority"] as? String
        let source = json["source"] as? String
        let activeForm = json["activeForm"] as? String
        let description = json["description"] as? String
        let notes = json["notes"] as? String
        let projectName = json["projectName"] as? String
        let areaName = json["areaName"] as? String
        let parentId = json["parentId"] as? String
        let dueDate = json["dueDate"] as? String
        let deferredUntil = json["deferredUntil"] as? String
        let estimatedMinutes = json["estimatedMinutes"] as? Int
        let actualMinutes = json["actualMinutes"] as? Int
        let createdAt = json["createdAt"] as? String
        let updatedAt = json["updatedAt"] as? String
        let startedAt = json["startedAt"] as? String
        let completedAt = json["completedAt"] as? String
        let taskCount = json["taskCount"] as? Int
        let completedTaskCount = json["completedTaskCount"] as? Int
        let projectCount = json["projectCount"] as? Int
        let activeTaskCount = json["activeTaskCount"] as? Int

        let tags: [String]
        if let tagArray = json["tags"] as? [String] {
            tags = tagArray
        } else {
            tags = []
        }

        let blockedBy: [String]
        if let arr = json["blockedBy"] as? [String] {
            blockedBy = arr
        } else {
            blockedBy = []
        }

        let blocks: [String]
        if let arr = json["blocks"] as? [String] {
            blocks = arr
        } else {
            blocks = []
        }

        return EntityDetail(
            entityType: entityType,
            title: title,
            id: id,
            status: status,
            priority: priority,
            source: source,
            activeForm: activeForm,
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            notes: notes.flatMap { $0.isEmpty ? nil : $0 },
            tags: tags,
            projectName: projectName,
            areaName: areaName,
            parentId: parentId,
            dueDate: dueDate,
            deferredUntil: deferredUntil,
            estimatedMinutes: estimatedMinutes,
            actualMinutes: actualMinutes,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            taskCount: taskCount,
            completedTaskCount: completedTaskCount,
            projectCount: projectCount,
            activeTaskCount: activeTaskCount,
            subtasks: [],
            tasks: [],
            blockedBy: blockedBy,
            blocks: blocks,
            activity: []
        )
    }

    /// Parse a list item like "  [x] task_abc: Title [high]"
    private static func parseListItem(from line: String) -> EntityDetail.ListItem? {
        guard let match = line.firstMatch(of: /\[([x> b\-])\]\s+([\w_]+):\s+(.+)/) else { return nil }
        let mark = String(match.1)
        let id = String(match.2)
        var titleAndExtra = String(match.3).trimmingCharacters(in: .whitespaces)

        // Extract trailing [priority] or similar
        var extra: String?
        if let extraMatch = titleAndExtra.firstMatch(of: /\s+(\[\w+\])$/) {
            extra = String(extraMatch.1)
            titleAndExtra = String(titleAndExtra[titleAndExtra.startIndex..<extraMatch.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }

        return EntityDetail.ListItem(mark: mark, id: id, title: titleAndExtra, extra: extra)
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
        let keys = ["Active form:", "Project:", "Area:", "Parent:", "Due:", "Deferred until:",
                     "Time:", "Tags:", "Source:", "Created:", "Updated:", "Started:", "Completed:",
                     "Blocked by:", "Blocks:", "ID:"]
        return keys.contains(where: { line.hasPrefix($0) })
    }

    // MARK: - List Result Parsing

    /// Parse list/search result text into structured ListResult.
    /// Returns nil for entity actions or malformed input.
    /// Supports both text format and JSON format (from Rust agent).
    static func parseListResult(from result: String, action: String) -> ListResult? {
        let listActions = Set(["list", "search", "list_projects", "list_areas"])
        guard listActions.contains(action) else { return nil }

        // Handle empty results
        if result.hasPrefix("No ") && result.hasSuffix(" found.") {
            return .empty(result)
        }

        // Try JSON parsing first (Rust agent returns JSON arrays)
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
        case "list_projects":
            return parseProjectList(lines: lines)
        case "list_areas":
            return parseAreaList(lines: lines)
        default:
            return nil
        }
    }

    /// Parse a list result from a JSON dictionary (Rust agent response).
    /// Handles: { "tasks": [...], "count": N }, { "projects": [...] }, { "areas": [...] }
    private static func parseListResultFromJSON(_ json: [String: Any], action: String) -> ListResult? {
        switch action {
        case "list", "search":
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
                    let priority = task["priority"] as? String
                    let dueDate = task["dueDate"] as? String
                    let mark: String
                    switch status {
                    case "completed": mark = "x"
                    case "in_progress": mark = ">"
                    case "cancelled": mark = "-"
                    case "backlog": mark = "b"
                    default: mark = " "
                    }
                    return TaskListItem(taskId: id, title: title, mark: mark,
                                        priority: priority == "medium" ? nil : priority,
                                        dueDate: dueDate)
                }
                return items.isEmpty ? .empty("No tasks found.") : .tasks(items)
            }

        case "list_projects":
            guard let projectsArray = json["projects"] as? [[String: Any]] else { return nil }
            if projectsArray.isEmpty { return .empty("No projects found.") }
            let items = projectsArray.compactMap { proj -> ProjectListItem? in
                guard let id = proj["id"] as? String,
                      let title = proj["title"] as? String else { return nil }
                let status = proj["status"] as? String ?? "active"
                let completed = proj["completedTasks"] as? Int ?? proj["completedTaskCount"] as? Int
                let total = proj["totalTasks"] as? Int ?? proj["taskCount"] as? Int
                return ProjectListItem(projectId: id, title: title, status: status,
                                       completedTasks: completed, totalTasks: total)
            }
            return items.isEmpty ? .empty("No projects found.") : .projects(items)

        case "list_areas":
            guard let areasArray = json["areas"] as? [[String: Any]] else { return nil }
            if areasArray.isEmpty { return .empty("No areas found.") }
            let items = areasArray.compactMap { area -> AreaListItem? in
                guard let id = area["id"] as? String,
                      let title = area["title"] as? String else { return nil }
                let status = area["status"] as? String ?? "active"
                let projectCount = area["projectCount"] as? Int
                let taskCount = area["taskCount"] as? Int
                let activeCount = area["activeTaskCount"] as? Int
                return AreaListItem(areaId: id, title: title, status: status,
                                    projectCount: projectCount, taskCount: taskCount,
                                    activeTaskCount: activeCount)
            }
            return items.isEmpty ? .empty("No areas found.") : .areas(items)

        default:
            return nil
        }
    }

    /// Parse task list: "Tasks (N):\n[mark] id: title (P:priority, due:date)"
    private static func parseTaskList(lines: [String]) -> ListResult? {
        var items: [TaskListItem] = []
        for line in lines.dropFirst() {  // Skip "Tasks (N):" header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match: [mark] id: title (metadata)
            guard let match = trimmed.firstMatch(of: /\[([x> b\-])\]\s+(.+?):\s+(.+)/) else { continue }
            let mark = String(match.1)
            let id = String(match.2)
            var titleAndMeta = String(match.3).trimmingCharacters(in: .whitespaces)

            // Extract trailing (P:priority, due:date) metadata
            var priority: String?
            var dueDate: String?
            if let metaMatch = titleAndMeta.firstMatch(of: /\s+\((.+)\)$/) {
                let metaStr = String(metaMatch.1)
                titleAndMeta = String(titleAndMeta[titleAndMeta.startIndex..<metaMatch.range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                for part in metaStr.components(separatedBy: ", ") {
                    let trimmedPart = part.trimmingCharacters(in: .whitespaces)
                    if trimmedPart.hasPrefix("P:") {
                        priority = String(trimmedPart.dropFirst(2))
                    } else if trimmedPart.hasPrefix("due:") {
                        dueDate = String(trimmedPart.dropFirst(4))
                    }
                }
            }

            items.append(TaskListItem(taskId: id, title: titleAndMeta, mark: mark, priority: priority, dueDate: dueDate))
        }
        return items.isEmpty ? .empty("No tasks found.") : .tasks(items)
    }

    /// Parse search results: "Search results (N):\n  id: title [status]"
    private static func parseSearchResults(lines: [String]) -> ListResult? {
        var items: [SearchResultItem] = []
        for line in lines.dropFirst() {  // Skip "Search results (N):" header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match: id: title [status]
            guard let match = trimmed.firstMatch(of: /(.+?):\s+(.+?)\s+\[(\w+)\]/) else { continue }
            items.append(SearchResultItem(
                itemId: String(match.1),
                title: String(match.2),
                status: String(match.3)
            ))
        }
        return items.isEmpty ? .empty("No tasks found.") : .searchResults(items)
    }

    /// Parse project list: "Projects (N):\n  id: title [status] (M/K tasks)"
    private static func parseProjectList(lines: [String]) -> ListResult? {
        var items: [ProjectListItem] = []
        for line in lines.dropFirst() {  // Skip "Projects (N):" header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match: id: title [status] (M/K tasks)
            guard let match = trimmed.firstMatch(of: /(.+?):\s+(.+?)\s+\[(\w+)\](.*)/) else { continue }
            let id = String(match.1)
            let title = String(match.2)
            let status = String(match.3)
            let rest = String(match.4)

            var completed: Int?
            var total: Int?
            if let progressMatch = rest.firstMatch(of: /\((\d+)\/(\d+) tasks\)/) {
                completed = Int(progressMatch.1)
                total = Int(progressMatch.2)
            }

            items.append(ProjectListItem(projectId: id, title: title, status: status, completedTasks: completed, totalTasks: total))
        }
        return items.isEmpty ? .empty("No projects found.") : .projects(items)
    }

    /// Parse area list: "Areas (N):\n  id: title [status] Np/Mt (K active)"
    private static func parseAreaList(lines: [String]) -> ListResult? {
        var items: [AreaListItem] = []
        for line in lines.dropFirst() {  // Skip "Areas (N):" header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match: id: title [status] Np/Mt (K active)
            guard let match = trimmed.firstMatch(of: /(.+?):\s+(.+?)\s+\[(\w+)\](.*)/) else { continue }
            let id = String(match.1)
            let title = String(match.2)
            let status = String(match.3)
            let rest = String(match.4)

            var projectCount: Int?
            var taskCount: Int?
            var activeCount: Int?
            if let countsMatch = rest.firstMatch(of: /(\d+)p\/(\d+)t\s+\((\d+) active\)/) {
                projectCount = Int(countsMatch.1)
                taskCount = Int(countsMatch.2)
                activeCount = Int(countsMatch.3)
            }

            items.append(AreaListItem(areaId: id, title: title, status: status, projectCount: projectCount, taskCount: taskCount, activeTaskCount: activeCount))
        }
        return items.isEmpty ? .empty("No areas found.") : .areas(items)
    }

    /// Running state summary for chip
    private static func taskManagerRunningSummary(action: String) -> String {
        switch action {
        case "create": return "Creating task..."
        case "update": return "Updating task..."
        case "delete": return "Deleting task..."
        case "list": return "Listing tasks..."
        case "search": return "Searching tasks..."
        case "get": return "Getting task..."
        case "create_project": return "Creating project..."
        case "update_project": return "Updating project..."
        case "list_projects": return "Listing projects..."
        case "log_time": return "Logging time..."
        case "add_dependency": return "Adding dependency..."
        case "remove_dependency": return "Removing dependency..."
        case "get_project": return "Getting project..."
        case "delete_project": return "Deleting project..."
        case "create_area": return "Creating area..."
        case "update_area": return "Updating area..."
        case "get_area": return "Getting area..."
        case "delete_area": return "Deleting area..."
        case "list_areas": return "Listing areas..."
        case "batch_create": return "Creating tasks..."
        case "batch_delete": return "Deleting tasks..."
        case "batch_update": return "Updating tasks..."
        default: return "Managing tasks..."
        }
    }

    /// Completed state summary for chip — strict format: <verb> <type> "<name>"
    private static func taskManagerChipSummary(action: String, title: String?, result: String?) -> String {
        let name = title ?? extractEntityName(from: result)
        let truncated = name.map { $0.count > 30 ? String($0.prefix(30)) + "..." : $0 }

        switch action {
        // Task actions
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
        case "log_time":
            return "Logged time"

        // Project actions
        case "create_project":
            if let t = truncated { return "Created project \"\(t)\"" }
            return "Created project"
        case "update_project":
            if let t = truncated { return "Updated project \"\(t)\"" }
            return "Updated project"
        case "delete_project":
            if let t = truncated { return "Deleted project \"\(t)\"" }
            return "Deleted project"
        case "get_project":
            if let t = truncated { return "Project \"\(t)\"" }
            return "Project details"

        // Area actions
        case "create_area":
            if let t = truncated { return "Created area \"\(t)\"" }
            return "Created area"
        case "update_area":
            if let t = truncated { return "Updated area \"\(t)\"" }
            return "Updated area"
        case "delete_area":
            if let t = truncated { return "Deleted area \"\(t)\"" }
            return "Deleted area"
        case "get_area":
            if let t = truncated { return "Area \"\(t)\"" }
            return "Area details"

        // List/search actions — extract counts from JSON arrays or text-format headers
        case "list", "search":
            if let count = extractListCount(from: result, jsonKey: "tasks") {
                if action == "search" {
                    return "\(count) result\(count == 1 ? "" : "s")"
                }
                return "\(count) task\(count == 1 ? "" : "s")"
            }
            return action == "search" ? "Search complete" : "Tasks listed"
        case "list_projects":
            if let count = extractListCount(from: result, jsonKey: "projects") {
                return "\(count) project\(count == 1 ? "" : "s")"
            }
            return "Projects listed"
        case "list_areas":
            if let count = extractListCount(from: result, jsonKey: "areas") {
                return "\(count) area\(count == 1 ? "" : "s")"
            }
            return "Areas listed"

        // Batch actions — extract affected count from JSON
        case "batch_create":
            if let count = extractBatchAffected(from: result) {
                return "Created \(count) task\(count == 1 ? "" : "s")"
            }
            return "Batch created"
        case "batch_delete":
            if let count = extractBatchAffected(from: result) {
                let dryRun = extractBatchDryRun(from: result)
                if dryRun { return "\(count) task\(count == 1 ? "" : "s") (preview)" }
                return "Deleted \(count) task\(count == 1 ? "" : "s")"
            }
            return "Batch deleted"
        case "batch_update":
            if let count = extractBatchAffected(from: result) {
                let dryRun = extractBatchDryRun(from: result)
                if dryRun { return "\(count) task\(count == 1 ? "" : "s") (preview)" }
                return "Updated \(count) task\(count == 1 ? "" : "s")"
            }
            return "Batch updated"

        default:
            return "Done"
        }
    }

    /// Extract entity name from tool result.
    /// Tries JSON `title` field first, falls back to text-format parsing for historical events.
    private static func extractEntityName(from result: String?) -> String? {
        guard let result else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try JSON format first (canonical)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String,
           !title.isEmpty {
            return title
        }

        // Fallback: text-format parsing for historical events
        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed

        // Match "# Title" header
        if firstLine.hasPrefix("# ") {
            let title = String(firstLine.dropFirst(2))
            return title.isEmpty ? nil : title
        }

        // Match "Verb entity_id: Title [status]" — extract title after first ": "
        if let colonRange = firstLine.range(of: ": ") {
            var name = String(firstLine[colonRange.upperBound...])
            // Strip trailing [status] bracket
            if let bracketStart = name.range(of: " [") {
                name = String(name[name.startIndex..<bracketStart.lowerBound])
            }
            return name.isEmpty ? nil : name
        }

        return nil
    }

    /// Extract count from list results.
    /// Tries JSON array first, falls back to text-format header parsing for historical events.
    private static func extractListCount(from result: String?, jsonKey: String) -> Int? {
        guard let result else { return nil }

        // Try JSON format first (canonical)
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json[jsonKey] as? [Any] {
            return items.count
        }

        // Fallback: text-format header parsing for historical events
        // Matches patterns like "Tasks (3/5):", "Areas (3)", "Search results for ... (3):"
        if let match = result.range(of: #"\((\d+)(?:/\d+)?\)"#, options: .regularExpression) {
            let numStr = String(result[match]).replacingOccurrences(of: "(", with: "").components(separatedBy: "/").first ?? ""
            if let count = Int(numStr.replacingOccurrences(of: ")", with: "")) {
                return count
            }
        }

        return nil
    }

    // MARK: - Batch Result Parsing

    /// Parse batch operation result JSON into a `BatchResult`.
    /// Returns nil for non-batch actions.
    static func parseBatchResult(from result: String, action: String) -> BatchResult? {
        let batchActions: [String: BatchResult.BatchAction] = [
            "batch_create": .create,
            "batch_delete": .delete,
            "batch_update": .update,
        ]
        guard let batchAction = batchActions[action] else { return nil }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let affected = json["affected"] as? Int ?? 0
        let dryRun = json["dryRun"] as? Bool ?? false
        let ids = json["ids"] as? [String] ?? []

        return BatchResult(
            action: batchAction,
            affected: affected,
            dryRun: dryRun,
            ids: ids
        )
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

    /// Extract `dryRun` flag from batch result JSON.
    private static func extractBatchDryRun(from result: String?) -> Bool {
        guard let result else { return false }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["dryRun"] as? Bool ?? false
    }
}
