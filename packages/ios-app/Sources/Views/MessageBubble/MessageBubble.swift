import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onSkillTap: ((Skill) -> Void)?
    var onAskUserQuestionTap: ((AskUserQuestionToolData) -> Void)?
    var onCompactionTap: ((Int, Int, String, String?) -> Void)?
    var onSubagentTap: ((SubagentToolData) -> Void)?
    var onRenderAppUITap: ((RenderAppUIChipData) -> Void)?
    var onTodoWriteTap: (() -> Void)?

    private var isUserMessage: Bool {
        message.role == .user
    }

    /// Check if we have any metadata to display
    private var hasMetadata: Bool {
        message.tokenUsage != nil ||
        message.shortModelName != nil ||
        message.formattedLatency != nil ||
        message.hasThinking == true
    }

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
            // Show attachments above skills for user messages (thumbnails at top)
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachedFileThumbnails(attachments: attachments)
            }

            // Show skills above text for user messages (iOS 26 glass chips)
            if let skills = message.skills, !skills.isEmpty {
                if #available(iOS 26.0, *) {
                    MessageSkillChips(skills: skills) { skill in
                        onSkillTap?(skill)
                    }
                } else {
                    // Fallback for older iOS
                    HStack(spacing: 6) {
                        ForEach(skills) { skill in
                            SkillChipFallback(skill: skill) {
                                onSkillTap?(skill)
                            }
                        }
                    }
                }
            }

            contentView

            // Show enriched metadata badge for assistant messages with metadata
            if !isUserMessage && hasMetadata {
                MessageMetadataBadge(
                    usage: message.tokenUsage,
                    incrementalUsage: message.incrementalTokens,
                    model: message.shortModelName,
                    latency: message.formattedLatency,
                    hasThinking: message.hasThinking
                )
            } else if let usage = message.tokenUsage {
                // Fallback to simple token badge for user messages
                TokenBadge(usage: usage)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            TextContentView(text: text, role: message.role)

        case .streaming(let text):
            StreamingContentView(text: text)

        case .thinking(let visible, let isExpanded):
            ThinkingContentView(content: visible, isExpanded: isExpanded)

        case .toolUse(let tool):
            // Handle subagent tools specially
            switch tool.toolName.lowercased() {
            case "spawnsubagent":
                // Convert SpawnSubagent tool to SubagentChip
                if let chipData = createSubagentToolData(from: tool) {
                    if #available(iOS 26.0, *) {
                        SubagentChip(data: chipData) {
                            onSubagentTap?(chipData)
                        }
                    } else {
                        SubagentChipFallback(data: chipData) {
                            onSubagentTap?(chipData)
                        }
                    }
                } else {
                    // Fallback to regular tool view if parsing fails
                    ToolResultRouter(tool: tool)
                }
            case "waitforsubagent":
                // Show WaitForSubagent as completion chip with result
                if let chipData = createWaitForSubagentToolData(from: tool) {
                    if #available(iOS 26.0, *) {
                        SubagentChip(data: chipData) {
                            onSubagentTap?(chipData)
                        }
                    } else {
                        SubagentChipFallback(data: chipData) {
                            onSubagentTap?(chipData)
                        }
                    }
                } else {
                    // Fallback to regular tool view if parsing fails
                    ToolResultRouter(tool: tool)
                }
            case "renderappui":
                // Show RenderAppUI as chip with canvas status
                if let chipData = createRenderAppUIChipData(from: tool) {
                    if #available(iOS 26.0, *) {
                        RenderAppUIChip(data: chipData) {
                            onRenderAppUITap?(chipData)
                        }
                    } else {
                        RenderAppUIChipFallback(data: chipData) {
                            onRenderAppUITap?(chipData)
                        }
                    }
                } else {
                    // Fallback to regular tool view if parsing fails
                    ToolResultRouter(tool: tool)
                }
            case "todowrite":
                // Show TodoWrite as compact chip with task counts
                if let chipData = createTodoWriteChipData(from: tool) {
                    if #available(iOS 26.0, *) {
                        TodoWriteChip(data: chipData) {
                            onTodoWriteTap?()
                        }
                    } else {
                        TodoWriteChipFallback(data: chipData) {
                            onTodoWriteTap?()
                        }
                    }
                } else {
                    // Fallback to regular tool view if parsing fails
                    ToolResultRouter(tool: tool)
                }
            default:
                ToolResultRouter(tool: tool)
            }

        case .toolResult(let result):
            StandaloneToolResultView(result: result)

        case .error(let errorMessage):
            ErrorContentView(message: errorMessage)

        case .images(let images):
            ImagesContentView(images: images)

        case .modelChange(let from, let to):
            ModelChangeNotificationView(from: from, to: to)

        case .reasoningLevelChange(let from, let to):
            ReasoningLevelChangeNotificationView(from: from, to: to)

        case .interrupted:
            InterruptedNotificationView()

        case .transcriptionFailed:
            TranscriptionFailedNotificationView()

        case .transcriptionNoSpeech:
            TranscriptionNoSpeechNotificationView()

        case .compaction(let tokensBefore, let tokensAfter, let reason, let summary):
            CompactionNotificationView(
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                reason: reason,
                onTap: {
                    onCompactionTap?(tokensBefore, tokensAfter, reason, summary)
                }
            )

        case .contextCleared(let tokensBefore, let tokensAfter):
            ContextClearedNotificationView(tokensBefore: tokensBefore, tokensAfter: tokensAfter)

        case .messageDeleted(let targetType):
            MessageDeletedNotificationView(targetType: targetType)

        case .skillRemoved(let skillName):
            SkillRemovedNotificationView(skillName: skillName)

        case .rulesLoaded(let count):
            RulesLoadedNotificationView(count: count)

        case .attachments(let attachments):
            // Attachments-only message (no text) - show thumbnails
            AttachedFileThumbnails(attachments: attachments)

        case .planModeEntered(let skillName, let blockedTools):
            if #available(iOS 26.0, *) {
                PlanModeEnteredView(skillName: skillName, blockedTools: blockedTools)
            } else {
                // Fallback for older iOS
                PlanModeEnteredFallbackView(skillName: skillName)
            }

        case .planModeExited(let reason, let planPath):
            if #available(iOS 26.0, *) {
                PlanModeExitedView(reason: reason, planPath: planPath)
            } else {
                // Fallback for older iOS
                PlanModeExitedFallbackView(reason: reason)
            }

        case .catchingUp:
            CatchingUpNotificationView()

        case .askUserQuestion(let data):
            if #available(iOS 26.0, *) {
                AskUserQuestionToolViewer(data: data) {
                    onAskUserQuestionTap?(data)
                }
            } else {
                // Fallback for older iOS
                AskUserQuestionFallbackView(questionCount: data.params.questions.count)
            }

        case .answeredQuestions(let count):
            AnsweredQuestionsChipView(questionCount: count)

        case .subagent(let data):
            if #available(iOS 26.0, *) {
                SubagentChip(data: data) {
                    onSubagentTap?(data)
                }
            } else {
                SubagentChipFallback(data: data) {
                    onSubagentTap?(data)
                }
            }

        case .renderAppUI(let data):
            if #available(iOS 26.0, *) {
                RenderAppUIChip(data: data) {
                    onRenderAppUITap?(data)
                }
            } else {
                RenderAppUIChipFallback(data: data) {
                    onRenderAppUITap?(data)
                }
            }
        }
    }

    // MARK: - Subagent Tool Parsing

    /// Parse SpawnSubagent tool result to create SubagentToolData for chip display
    private func createSubagentToolData(from tool: ToolUseData) -> SubagentToolData? {
        // Extract task from arguments
        let task = extractTaskFromArguments(tool.arguments)

        // Extract session ID and other info from result
        let sessionId = extractSessionId(from: tool.result) ?? tool.toolCallId
        let resultStatus = extractStatus(from: tool.result)

        // Determine status based on tool status and result
        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = resultStatus ?? .completed
        case .error:
            status = .failed
        }

        // Extract additional info from result
        let resultSummary = extractResultSummary(from: tool.result)
        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: task,
            model: nil,
            status: status,
            currentTurn: 0,
            resultSummary: resultSummary,
            fullOutput: tool.result,
            duration: tool.durationMs,
            error: error,
            tokenUsage: nil
        )
    }

    private func extractTaskFromArguments(_ args: String) -> String {
        // Try to extract "task" field from JSON arguments
        if let match = args.firstMatch(of: /"task"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return "Sub-agent task"
    }

    /// Parse WaitForSubagent tool result to create SubagentToolData for chip display
    private func createWaitForSubagentToolData(from tool: ToolUseData) -> SubagentToolData? {
        // Extract sessionId from arguments (WaitForSubagent uses sessionId parameter)
        let sessionId = extractSessionIdFromArguments(tool.arguments)
            ?? extractSessionId(from: tool.result)
            ?? tool.toolCallId

        // Determine status based on tool status
        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = .completed
        case .error:
            status = .failed
        }

        // Extract output and summary from result
        let (summary, fullOutput) = extractWaitForSubagentOutput(from: tool.result)
        let turns = extractTurns(from: tool.result)
        let duration = extractDurationMs(from: tool.result)
        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: "Sub-agent task",  // WaitForSubagent doesn't have the original task
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

    private func extractSessionIdFromArguments(_ args: String) -> String? {
        // Try to extract "sessionId" field from JSON arguments
        if let match = args.firstMatch(of: /"sessionId"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return nil
    }

    private func extractWaitForSubagentOutput(from result: String?) -> (summary: String?, fullOutput: String?) {
        guard let result = result else { return (nil, nil) }

        // Look for **Output**: section
        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n([\s\S]*)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove trailing markdown separators
            let cleaned = output.components(separatedBy: "\n---\n").first ?? output

            // Create summary from first meaningful line
            let lines = cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }
            let summary = lines.first.map { $0.count > 100 ? String($0.prefix(100)) + "..." : $0 }

            return (summary, cleaned)
        }

        // Fallback: look for "Completed" status
        if result.lowercased().contains("completed") {
            return ("Sub-agent completed", result)
        }

        return (nil, result)
    }

    private func extractTurns(from result: String?) -> Int {
        guard let result = result else { return 0 }
        // Look for "Turns: X" or "**Turns**: X"
        if let match = result.firstMatch(of: /\*?\*?Turns\*?\*?\s*[:\|]\s*(\d+)/) {
            return Int(match.1) ?? 0
        }
        return 0
    }

    private func extractDurationMs(from result: String?) -> Int? {
        guard let result = result else { return nil }
        // Look for "Duration: X.Xs" or "Xms" or "X.X seconds"
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

    private func extractSessionId(from result: String?) -> String? {
        guard let result = result else { return nil }
        // Look for sess_xxx pattern directly (most reliable)
        if let match = result.firstMatch(of: /sess_[a-zA-Z0-9_-]+/) {
            return String(match.0)
        }
        // Also try: sessionId: "..."
        if let match = result.firstMatch(of: /sessionId[:\s"]+([a-zA-Z0-9_-]+)/) {
            return String(match.1)
        }
        return nil
    }

    private func extractStatus(from result: String?) -> SubagentStatus? {
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

    private func extractResultSummary(from result: String?) -> String? {
        guard let result = result else { return nil }
        // Look for **Output**: section in WaitForSubagent results
        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n(.+)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            // Take first line or first 200 chars
            let firstLine = output.components(separatedBy: "\n").first ?? output
            return firstLine.count > 200 ? String(firstLine.prefix(200)) + "..." : firstLine
        }
        // For spawned messages, just return a simple summary
        if result.lowercased().contains("spawned") {
            return "Sub-agent spawned successfully"
        }
        return nil
    }

    // MARK: - RenderAppUI Tool Parsing

    /// Parse RenderAppUI tool arguments to create RenderAppUIChipData for chip display
    private func createRenderAppUIChipData(from tool: ToolUseData) -> RenderAppUIChipData? {
        // Extract canvasId from arguments
        let canvasId = extractCanvasId(from: tool.arguments) ?? tool.toolCallId
        let title = extractTitleFromArguments(tool.arguments)

        // Determine status based on tool status
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

    private func extractCanvasId(from args: String) -> String? {
        // Try to extract "canvasId" field from JSON arguments
        if let match = args.firstMatch(of: /"canvasId"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return nil
    }

    private func extractTitleFromArguments(_ args: String) -> String? {
        // Try to extract "title" field from JSON arguments
        if let match = args.firstMatch(of: /"title"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }

    // MARK: - TodoWrite Tool Parsing

    /// Parse TodoWrite tool result to create TodoWriteChipData for chip display
    private func createTodoWriteChipData(from tool: ToolUseData) -> TodoWriteChipData? {
        // Parse the last line of the result which has format:
        // "X completed, Y in progress, Z pending"
        guard let result = tool.result else { return nil }

        // Extract counts using regex pattern
        var completed = 0
        var inProgress = 0
        var pending = 0

        // Match pattern: "X completed, Y in progress, Z pending"
        if let match = result.firstMatch(of: /(\d+)\s+completed,\s+(\d+)\s+in\s+progress,\s+(\d+)\s+pending/) {
            completed = Int(match.1) ?? 0
            inProgress = Int(match.2) ?? 0
            pending = Int(match.3) ?? 0
        }

        let totalCount = completed + inProgress + pending
        let newCount = inProgress + pending

        return TodoWriteChipData(
            toolCallId: tool.toolCallId,
            newCount: newCount,
            doneCount: completed,
            totalCount: totalCount
        )
    }
}

// MARK: - Answered Questions Chip View

struct AnsweredQuestionsChipView: View {
    let questionCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronSuccess)

            Text("Answered agent's questions")
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurface.opacity(0.6))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            MessageBubble(message: .user("Hello, can you help me?"))
            MessageBubble(message: .assistant("Of course! I'd be happy to help."))

            // Test markdown table rendering
            MessageBubble(message: .assistant("""
            All tools working! Here's a summary:

            | Tool | Status | What it did |
            |------|--------|-------------|
            | ls | OK | Listed 8 files/folders |
            | read | OK | Read README.md |
            | edit | OK | Added a test comment |
            | grep | OK | Found 5 functions |
            | bash | OK | Ran echo command |

            Everything's working as expected!
            """))

            MessageBubble(message: .streaming("I'm currently typing..."))
            MessageBubble(message: .error("Something went wrong"))
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
