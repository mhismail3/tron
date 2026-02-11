import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onSkillTap: ((Skill) -> Void)?
    var onSpellTap: ((Skill) -> Void)?
    var onAskUserQuestionTap: ((AskUserQuestionToolData) -> Void)?
    var onThinkingTap: ((String) -> Void)?
    var onCompactionTap: ((Int, Int, String, String?) -> Void)?
    var onSubagentTap: ((SubagentToolData) -> Void)?
    var onRenderAppUITap: ((RenderAppUIChipData) -> Void)?
    var onTaskManagerTap: ((TaskManagerChipData) -> Void)?
    var onNotifyAppTap: ((NotifyAppChipData) -> Void)?
    var onCommandToolTap: ((CommandToolChipData) -> Void)?
    var onQueryAgentTap: ((QueryAgentChipData) -> Void)?
    var onWaitForAgentsTap: ((WaitForAgentsChipData) -> Void)?
    var onMemoryUpdatedTap: ((String, String) -> Void)?
    var onSubagentResultTap: ((String) -> Void)?

    private var isUserMessage: Bool {
        message.role == .user
    }

    /// Check if we have any metadata to display
    private var hasMetadata: Bool {
        message.tokenRecord != nil ||
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

            // Show spells above text for user messages (pink chips for ephemeral skills)
            if let spells = message.spells, !spells.isEmpty {
                if #available(iOS 26.0, *) {
                    MessageSpellChips(spells: spells) { spell in
                        onSpellTap?(spell)
                    }
                } else {
                    // Fallback for older iOS
                    HStack(spacing: 6) {
                        ForEach(spells) { spell in
                            SkillChipFallback(skill: spell, mode: .spell) {
                                onSpellTap?(spell)
                            }
                        }
                    }
                }
            }

            contentView

            // Show enriched metadata badge for assistant messages with metadata
            if !isUserMessage && hasMetadata {
                MessageMetadataBadge(
                    tokenRecord: message.tokenRecord,
                    model: message.shortModelName,
                    latency: message.formattedLatency,
                    hasThinking: message.hasThinking
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
                onThinkingTap?(visible)
            }

        case .toolUse(let tool):
            // Handle subagent tools specially using ToolResultParser
            switch ToolKind(toolName: tool.toolName) {
            case .spawnSubagent:
                // Convert SpawnSubagent tool to SubagentChip
                if let chipData = ToolResultParser.parseSpawnSubagent(from: tool) {
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
            case .waitForSubagent:
                // Show WaitForSubagent as completion chip with result
                if let chipData = ToolResultParser.parseWaitForSubagent(from: tool) {
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
            case .renderAppUI:
                // Show RenderAppUI as chip with canvas status
                if let chipData = ToolResultParser.parseRenderAppUI(from: tool) {
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
            case .taskManager:
                // Show TaskManager as compact chip with action/result summary
                if let chipData = ToolResultParser.parseTaskManager(from: tool) {
                    if #available(iOS 26.0, *) {
                        TaskManagerChip(data: chipData) {
                            onTaskManagerTap?(chipData)
                        }
                    } else {
                        TaskManagerChipFallback(data: chipData) {
                            onTaskManagerTap?(chipData)
                        }
                    }
                } else {
                    // Fallback to regular tool view if parsing fails
                    ToolResultRouter(tool: tool)
                }
            case .notifyApp:
                // Show NotifyApp as compact chip with notification status
                if let chipData = ToolResultParser.parseNotifyApp(from: tool) {
                    if #available(iOS 26.0, *) {
                        NotifyAppChip(data: chipData) {
                            onNotifyAppTap?(chipData)
                        }
                    } else {
                        NotifyAppChipFallback(data: chipData) {
                            onNotifyAppTap?(chipData)
                        }
                    }
                } else {
                    // Fallback to regular tool view if parsing fails
                    ToolResultRouter(tool: tool)
                }
            case .queryAgent:
                if let chipData = ToolResultParser.parseQueryAgent(from: tool) {
                    if #available(iOS 26.0, *) {
                        QueryAgentChip(data: chipData) {
                            onQueryAgentTap?(chipData)
                        }
                    } else {
                        QueryAgentChipFallback(data: chipData) {
                            onQueryAgentTap?(chipData)
                        }
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .waitForAgents:
                if let chipData = ToolResultParser.parseWaitForAgents(from: tool) {
                    if #available(iOS 26.0, *) {
                        WaitForAgentsChip(data: chipData) {
                            onWaitForAgentsTap?(chipData)
                        }
                    } else {
                        WaitForAgentsChipFallback(data: chipData) {
                            onWaitForAgentsTap?(chipData)
                        }
                    }
                } else {
                    ToolResultRouter(tool: tool)
                }
            case .askUserQuestion:
                // AskUserQuestion is handled in its own case
                ToolResultRouter(tool: tool)
            default:
                // All other tools use CommandToolChip (always succeeds, uses gear icon for unknown)
                let chipData = CommandToolChipData(from: tool)
                if #available(iOS 26.0, *) {
                    CommandToolChip(data: chipData) {
                        onCommandToolTap?(chipData)
                    }
                } else {
                    CommandToolChipFallback(data: chipData) {
                        onCommandToolTap?(chipData)
                    }
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
                SystemEventView(
                    event: event,
                    onCompactionTap: onCompactionTap,
                    onMemoryUpdatedTap: onMemoryUpdatedTap,
                    onSubagentResultTap: onSubagentResultTap
                )
            } else {
                // Fallback without subagent result notification for older iOS
                Text(event.textContent)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }

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
