import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onTap: ((MessageBubbleTapAction) -> Void)?

    private var isUserMessage: Bool {
        message.role == .user
    }

    /// Check if we have any metadata to display
    private var hasMetadata: Bool {
        message.tokenRecord != nil ||
        message.shortModelName != nil ||
        message.formattedLatency != nil
    }

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
            // Show attachments above skills for user messages (thumbnails at top)
            if let attachments = message.attachments, !attachments.isEmpty {
                AttachedFileThumbnails(attachments: attachments)
            }

            // Show skills above text for user messages
            if let skills = message.skills, !skills.isEmpty {
                MessageSkillChips(skills: skills) { skill in
                    onTap?(.skill(skill))
                }
            }

            // Show spells above text for user messages (pink chips for ephemeral skills)
            if let spells = message.spells, !spells.isEmpty {
                MessageSpellChips(spells: spells) { spell in
                    onTap?(.spell(spell))
                }
            }

            contentView

            // Show enriched metadata badge for assistant messages with metadata
            if !isUserMessage && hasMetadata {
                MessageMetadataBadge(
                    tokenRecord: message.tokenRecord,
                    model: message.shortModelName,
                    latency: message.formattedLatency
                )
            } else if let record = message.tokenRecord {
                // Fallback to simple token badge for user messages
                TokenBadge(record: record)
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

        case .thinking(let visible, let isExpanded, let isStreaming):
            ThinkingContentView(content: visible, isExpanded: isExpanded, isStreaming: isStreaming) {
                onTap?(.thinking(visible))
            }

        case .toolUse(let tool):
            // Handle subagent tools specially using ToolResultParser
            switch ToolKind(toolName: tool.toolName) {
            case .spawnSubagent:
                if let chipData = ToolResultParser.parseSpawnSubagent(from: tool) {
                    SubagentChip(data: chipData) {
                        onTap?(.subagent(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .waitForSubagent:
                if let chipData = ToolResultParser.parseWaitForSubagent(from: tool) {
                    SubagentChip(data: chipData) {
                        onTap?(.subagent(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .renderAppUI:
                if let chipData = ToolResultParser.parseRenderAppUI(from: tool) {
                    RenderAppUIChip(data: chipData) {
                        onTap?(.renderAppUI(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .taskManager:
                if let chipData = ToolResultParser.parseTaskManager(from: tool) {
                    TaskManagerChip(data: chipData) {
                        onTap?(.taskManager(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .notifyApp:
                if let chipData = ToolResultParser.parseNotifyApp(from: tool) {
                    NotifyAppChip(data: chipData) {
                        onTap?(.notifyApp(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .queryAgent:
                if let chipData = ToolResultParser.parseQueryAgent(from: tool) {
                    QueryAgentChip(data: chipData) {
                        onTap?(.queryAgent(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .waitForAgents:
                if let chipData = ToolResultParser.parseWaitForAgents(from: tool) {
                    WaitForAgentsChip(data: chipData) {
                        onTap?(.waitForAgents(chipData))
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .askUserQuestion:
                ToolResultRouter(tool: tool)
            default:
                let chipData = CommandToolChipData(from: tool)
                CommandToolChip(data: chipData) {
                    onTap?(.commandTool(chipData))
                }
            }

        case .toolResult(let result):
            StandaloneToolResultView(result: result)

        case .error(let errorMessage):
            ErrorContentView(message: errorMessage)

        case .images(let images):
            ImagesContentView(images: images)

        case .attachments(let attachments):
            // Attachments-only message (no text) - show thumbnails
            AttachedFileThumbnails(attachments: attachments)

        case .systemEvent(let event):
            if #available(iOS 26.0, *) {
                SystemEventView(event: event, onTap: onTap)
            } else {
                // Fallback without subagent result notification for older iOS
                Text(event.textContent)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }

        case .askUserQuestion(let data):
            if #available(iOS 26.0, *) {
                AskUserQuestionToolViewer(data: data) {
                    onTap?(.askUserQuestion(data))
                }
            } else {
                // Fallback for older iOS
                AskUserQuestionFallbackView(questionCount: data.params.questions.count)
            }

        case .answeredQuestions(let count):
            AnsweredQuestionsChipView(questionCount: count)

        case .subagent(let data):
            SubagentChip(data: data) {
                onTap?(.subagent(data))
            }

        case .renderAppUI(let data):
            RenderAppUIChip(data: data) {
                onTap?(.renderAppUI(data))
            }
        }
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
}
