import Foundation

/// Centralized tool result parsing service
/// Extracts data from tool arguments and results for UI display
/// Views should receive pre-parsed data and not perform any regex parsing
struct ToolResultParser {

    // MARK: - SpawnSubagent Parsing

    /// Parse SpawnSubagent tool to create SubagentToolData for chip display
    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        let task = ToolArgumentParser.string("task", from: tool.arguments)
            .map { $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") }
            ?? "Sub-agent task"
        let model = ToolArgumentParser.string("model", from: tool.arguments)

        // Prefer structured details for sessionId and status
        let sessionId: String
        let resultStatus: SubagentStatus?
        let resultSummary: String?
        let turns: Int

        if let details = tool.details {
            sessionId = (details["sessionId"]?.value as? String) ?? extractSessionId(from: tool.result) ?? tool.toolCallId
            if let success = details["success"]?.value as? Bool {
                resultStatus = success ? .completed : .failed
            } else {
                resultStatus = extractSubagentStatus(from: tool.result)
            }
            resultSummary = (details["summary"]?.value as? String) ?? extractResultSummary(from: tool.result)
            turns = (details["totalTurns"]?.value as? Int) ?? extractTurns(from: tool.result)
        } else {
            sessionId = extractSessionId(from: tool.result) ?? tool.toolCallId
            resultStatus = extractSubagentStatus(from: tool.result)
            resultSummary = extractResultSummary(from: tool.result)
            turns = extractTurns(from: tool.result)
        }

        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = resultStatus ?? .completed
        case .error:
            status = .failed
        }

        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: task,
            model: model,
            status: status,
            currentTurn: turns,
            resultSummary: resultSummary,
            fullOutput: tool.result,
            duration: tool.durationMs,
            error: error,
            tokenUsage: nil
        )
    }

    /// Parse WaitForSubagent tool result to create SubagentToolData for chip display
    static func parseWaitForSubagent(from tool: ToolUseData) -> SubagentToolData? {
        let sessionId = ToolArgumentParser.string("sessionId", from: tool.arguments)
            ?? extractSessionId(from: tool.result)
            ?? tool.toolCallId

        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = .completed
        case .error:
            status = .failed
        }

        let (summary, fullOutput) = extractWaitForSubagentOutput(from: tool.result)
        let turns = extractTurns(from: tool.result)
        let duration = extractDurationMs(from: tool.result)
        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: "Sub-agent task",
            model: nil,
            status: status,
            currentTurn: turns,
            resultSummary: summary,
            fullOutput: fullOutput,
            duration: duration ?? tool.durationMs,
            error: error,
            tokenUsage: nil
        )
    }

    // MARK: - RenderAppUI Parsing

    /// Parse RenderAppUI tool arguments to create RenderAppUIChipData for chip display
    static func parseRenderAppUI(from tool: ToolUseData) -> RenderAppUIChipData? {
        let canvasId = ToolArgumentParser.string("canvasId", from: tool.arguments) ?? tool.toolCallId
        let title = ToolArgumentParser.string("title", from: tool.arguments)

        let status: RenderAppUIStatus
        switch tool.status {
        case .running:
            status = .rendering
        case .success:
            status = .complete
        case .error:
            status = .error
        }

        return RenderAppUIChipData(
            toolCallId: tool.toolCallId,
            canvasId: canvasId,
            title: title,
            status: status,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }

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
                status: .running
            )
        }

        let chipSummary = taskManagerChipSummary(action: action, title: taskTitle, result: tool.result)
        let entityDetail = tool.result.flatMap { parseEntityDetail(from: $0, action: action) }

        return TaskManagerChipData(
            toolCallId: tool.toolCallId,
            action: action,
            taskTitle: taskTitle,
            chipSummary: chipSummary,
            fullResult: tool.result,
            arguments: tool.arguments,
            entityDetail: entityDetail,
            status: .completed
        )
    }

    /// Parse enriched tool result text into a structured EntityDetail snapshot.
    /// Returns nil for list/search actions or malformed input.
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

        // List/search actions — count extraction
        case "list":
            if let result, let match = result.firstMatch(of: /Tasks \((\d+)/) {
                let count = Int(match.1) ?? 0
                return "\(count) task\(count == 1 ? "" : "s")"
            }
            return "Tasks listed"
        case "search":
            if let result, let match = result.firstMatch(of: /\((\d+)\)/) {
                let count = Int(match.1) ?? 0
                return "\(count) result\(count == 1 ? "" : "s")"
            }
            return "Search complete"
        case "list_projects":
            if let result, let match = result.firstMatch(of: /Projects \((\d+)\)/) {
                let count = Int(match.1) ?? 0
                return "\(count) project\(count == 1 ? "" : "s")"
            }
            return "Projects listed"
        case "list_areas":
            if let result, let match = result.firstMatch(of: /Areas \((\d+)\)/) {
                let count = Int(match.1) ?? 0
                return "\(count) area\(count == 1 ? "" : "s")"
            }
            return "Areas listed"

        default:
            return "Done"
        }
    }

    /// Extract entity name from tool result text
    /// Matches ID patterns like "task_xxx: Name [status]" or "# Name" headers
    private static func extractEntityName(from result: String?) -> String? {
        guard let result else { return nil }
        // Match "entity_id: Name" — strip trailing [status]
        if let match = result.firstMatch(of: /(?:task_|proj_|area_)\w+:\s+(.+?)(?:\s+\[|$)/) {
            let name = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        // Match "# Name" header (get actions)
        if let match = result.firstMatch(of: /(?m)^#\s+(.+)$/) {
            return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - NotifyApp Parsing

    /// Parse NotifyApp tool to create NotifyAppChipData for chip display
    static func parseNotifyApp(from tool: ToolUseData) -> NotifyAppChipData? {
        guard let title = ToolArgumentParser.string("title", from: tool.arguments),
              let body = ToolArgumentParser.string("body", from: tool.arguments) else {
            return nil
        }

        let sheetContent = ToolArgumentParser.string("sheetContent", from: tool.arguments)

        let status: NotifyAppStatus
        switch tool.status {
        case .running:
            status = .sending
        case .success:
            status = .sent
        case .error:
            status = .failed
        }

        var successCount: Int?
        var failureCount: Int?
        var errorMessage: String?

        // Prefer structured details from server
        if let details = tool.details,
           let sc = details["successCount"]?.value as? Int {
            successCount = sc
            failureCount = (details["failureCount"]?.value as? Int) ?? 0
        } else if let result = tool.result {
            // Fallback: regex on freetext result
            if let match = result.firstMatch(of: /to\s+(\d+)\s+device/) {
                successCount = Int(match.1)
            }
            if let match = result.firstMatch(of: /failed\s+for\s+(\d+)/) {
                failureCount = Int(match.1)
            }
        }

        if status == .failed, let result = tool.result {
            errorMessage = result
        }

        return NotifyAppChipData(
            toolCallId: tool.toolCallId,
            title: title,
            body: body,
            sheetContent: sheetContent,
            status: status,
            successCount: successCount,
            failureCount: failureCount,
            errorMessage: errorMessage
        )
    }

    // MARK: - QueryAgent Parsing

    /// Parse QueryAgent tool to create QueryAgentChipData for chip display
    static func parseQueryAgent(from tool: ToolUseData) -> QueryAgentChipData? {
        let sessionId = ToolArgumentParser.string("sessionId", from: tool.arguments) ?? "unknown"

        let queryType: QueryType
        if let qt = ToolArgumentParser.string("queryType", from: tool.arguments) {
            queryType = QueryType(rawValue: qt) ?? .unknown
        } else {
            queryType = .unknown
        }

        let status: QueryAgentStatus
        switch tool.status {
        case .running:
            status = .querying
        case .success:
            status = .success
        case .error:
            status = .error
        }

        let resultPreview: String?
        if let result = tool.result {
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            resultPreview = lines.first.map { $0.count > 80 ? String($0.prefix(80)) + "..." : $0 }
        } else {
            resultPreview = nil
        }

        return QueryAgentChipData(
            toolCallId: tool.toolCallId,
            sessionId: sessionId,
            queryType: queryType,
            status: status,
            durationMs: tool.durationMs,
            resultPreview: resultPreview,
            fullResult: tool.result,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }

    // MARK: - WaitForAgents Parsing

    /// Parse WaitForAgents tool to create WaitForAgentsChipData for chip display
    static func parseWaitForAgents(from tool: ToolUseData) -> WaitForAgentsChipData? {
        let sessionIds = ToolArgumentParser.stringArray("sessionIds", from: tool.arguments) ?? []

        let mode: WaitMode
        if let m = ToolArgumentParser.string("mode", from: tool.arguments) {
            mode = WaitMode(rawValue: m) ?? .all
        } else {
            mode = .all
        }

        let status: WaitForAgentsStatus
        // Prefer structured details for timeout detection
        let timedOut: Bool
        if let details = tool.details, let to = details["timedOut"]?.value as? Bool {
            timedOut = to
        } else if let result = tool.result {
            timedOut = result.lowercased().contains("timeout")
        } else {
            timedOut = false
        }

        switch tool.status {
        case .running:
            status = .waiting
        case .success:
            status = timedOut ? .timedOut : .completed
        case .error:
            status = timedOut ? .timedOut : .error
        }

        // Count completed agents - prefer structured details
        var completedCount = 0
        if let details = tool.details,
           let results = details["results"]?.value as? [[String: Any]] {
            completedCount = results.count
        } else if let result = tool.result {
            // Fallback: regex on freetext result
            let matches = result.matches(of: /Session:\s*`sess_/)
            completedCount = matches.count
        }

        let resultPreview: String?
        if let result = tool.result {
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            resultPreview = lines.first.map { $0.count > 80 ? String($0.prefix(80)) + "..." : $0 }
        } else {
            resultPreview = nil
        }

        return WaitForAgentsChipData(
            toolCallId: tool.toolCallId,
            sessionIds: sessionIds,
            mode: mode,
            status: status,
            completedCount: completedCount,
            durationMs: tool.durationMs,
            resultPreview: resultPreview,
            fullResult: tool.result,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }

    // MARK: - Private Result Extraction Helpers
    // These parse free-text result strings (not JSON arguments), so regex is appropriate.

    /// Extract output and summary from WaitForSubagent result
    private static func extractWaitForSubagentOutput(from result: String?) -> (summary: String?, fullOutput: String?) {
        guard let result = result else { return (nil, nil) }

        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n([\s\S]*)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = output.components(separatedBy: "\n---\n").first ?? output
            let lines = cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }
            let summary = lines.first.map { $0.count > 100 ? String($0.prefix(100)) + "..." : $0 }
            return (summary, cleaned)
        }

        if result.lowercased().contains("completed") {
            return ("Sub-agent completed", result)
        }

        return (nil, result)
    }

    /// Extract turn count from result
    private static func extractTurns(from result: String?) -> Int {
        guard let result = result else { return 0 }
        if let match = result.firstMatch(of: /\*?\*?Turns\*?\*?\s*[:\|]\s*(\d+)/) {
            return Int(match.1) ?? 0
        }
        return 0
    }

    /// Extract duration in milliseconds from result
    private static func extractDurationMs(from result: String?) -> Int? {
        guard let result = result else { return nil }
        if let match = result.firstMatch(of: /Duration[:\s*\|]+\s*(\d+\.?\d*)\s*(ms|s|seconds?)/) {
            let value = Double(match.1) ?? 0
            let unit = String(match.2).lowercased()
            if unit.hasPrefix("s") && !unit.hasPrefix("second") || unit.contains("second") {
                return Int(value * 1000)
            }
            return Int(value)
        }
        return nil
    }

    /// Extract session ID from result text
    private static func extractSessionId(from result: String?) -> String? {
        guard let result = result else { return nil }
        if let match = result.firstMatch(of: /sess_[a-zA-Z0-9_-]+/) {
            return String(match.0)
        }
        if let match = result.firstMatch(of: /sessionId[:\s"]+([a-zA-Z0-9_-]+)/) {
            return String(match.1)
        }
        return nil
    }

    /// Extract subagent status from result text
    private static func extractSubagentStatus(from result: String?) -> SubagentStatus? {
        guard let result = result else { return nil }
        let lower = result.lowercased()
        if lower.contains("completed") || lower.contains("successfully") {
            return .completed
        }
        if lower.contains("failed") || lower.contains("error") {
            return .failed
        }
        if lower.contains("running") || lower.contains("spawned") {
            return .running
        }
        return nil
    }

    /// Extract result summary from result text
    private static func extractResultSummary(from result: String?) -> String? {
        guard let result = result else { return nil }
        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n(.+)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = output.components(separatedBy: "\n").first ?? output
            return firstLine.count > 200 ? String(firstLine.prefix(200)) + "..." : firstLine
        }
        if result.lowercased().contains("spawned") {
            return "Sub-agent spawned successfully"
        }
        return nil
    }
}
