import SwiftUI

// MARK: - Message Bubble (Terminal-style matching web UI)

struct MessageBubble: View {
    let message: ChatMessage
    var onSkillTap: ((Skill) -> Void)?
    var onAskUserQuestionTap: ((AskUserQuestionToolData) -> Void)?

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
            ToolResultRouter(tool: tool)

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

        case .compaction(let tokensBefore, let tokensAfter, let reason):
            CompactionNotificationView(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason)

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
        }
    }
}

// MARK: - Answered Questions Chip View

struct AnsweredQuestionsChipView: View {
    let questionCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tronSuccess)

            Text("Answered agent's questions")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
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
