import SwiftUI

// MARK: - NotificationPill

struct NotificationPill<Content: View>: View {
    let tint: Color
    var interactive: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let onTap {
                pillContent.onTapGesture { onTap() }
            } else {
                pillContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var pillContent: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(PillBackground(tint: tint, interactive: interactive))
            .contentShape(Capsule())
    }
}

// MARK: - PillBackground

private struct PillBackground: ViewModifier {
    let tint: Color
    let interactive: Bool

    func body(content: Content) -> some View {
        if interactive {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        .regular.tint(tint.opacity(0.35)).interactive(),
                        in: .capsule
                    )
            } else {
                solidBackground(content)
            }
        } else {
            solidBackground(content)
        }
    }

    private func solidBackground(_ content: Content) -> some View {
        content
            .background(tint.opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// MARK: - Model Change Notification View

struct ModelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
        NotificationPill(tint: .tronEmerald) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronEmerald)

                Text("Switched from")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                Text(from)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "arrow.right")
                    .font(TronTypography.pill)
                    .foregroundStyle(.tronTextMuted)

                Text(to)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
        }
    }
}

// MARK: - Reasoning Level Change Notification View

struct ReasoningLevelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
        NotificationPill(tint: .tronEmerald) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronEmerald)

                Text("Reasoning")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                Text(from)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "arrow.right")
                    .font(TronTypography.pill)
                    .foregroundStyle(.tronTextMuted)

                Text(to)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
        }
    }
}

// MARK: - Interrupted Notification View

struct InterruptedNotificationView: View {
    var body: some View {
        NotificationPill(tint: .red) {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.red)

                Text("Session interrupted")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
    }
}

// MARK: - Catching Up Notification View

struct CatchingUpNotificationView: View {
    var body: some View {
        NotificationPill(tint: .gray) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.gray)

                Text("Loading latest messages...")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.gray)
            }
        }
    }
}

// MARK: - Transcription Failed Notification View

struct TranscriptionFailedNotificationView: View {
    var body: some View {
        NotificationPill(tint: .red) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.red)

                Text("Transcription failed")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
    }
}

// MARK: - No Speech Detected Notification View

struct TranscriptionNoSpeechNotificationView: View {
    var body: some View {
        NotificationPill(tint: .orange) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(Color.orange)

                Text("No speech detected")
                    .font(TronTypography.filePath)
                    .foregroundStyle(Color.orange.opacity(0.9))
            }
        }
    }
}

// MARK: - Compaction In Progress Notification View

struct CompactionInProgressNotificationView: View {
    var body: some View {
        NotificationPill(tint: .cyan, interactive: true) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.cyan)

                Text("Compacting context...")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.cyan.opacity(0.9))
            }
        }
    }
}

// MARK: - Compaction Notification View

struct CompactionNotificationView: View {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String
    var onTap: (() -> Void)? = nil

    private var tokensSaved: Int {
        tokensBefore - tokensAfter
    }

    private var formattedSaved: String {
        if tokensSaved >= 1000 {
            return String(format: "%.1fk", Double(tokensSaved) / 1000.0)
        }
        return "\(tokensSaved)"
    }

    private var compressionPercent: Int {
        guard tokensBefore > 0 else { return 0 }
        return Int(Double(tokensSaved) / Double(tokensBefore) * 100)
    }

    private var reasonDisplay: String {
        CompactionReason(rawValue: reason)?.displayText ?? reason
    }

    var body: some View {
        NotificationPill(tint: .cyan, interactive: true, onTap: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.cyan)

                Text("Context compacted")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.cyan.opacity(0.9))

                Text("\u{2022}")
                    .font(TronTypography.badge)
                    .foregroundStyle(.cyan.opacity(0.5))

                Text("\(formattedSaved) tokens saved")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.cyan.opacity(0.7))

                Text("(\(compressionPercent)%)")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.cyan.opacity(0.5))
            }
        }
    }
}

// MARK: - Context Cleared Notification View

struct ContextClearedNotificationView: View {
    let tokensBefore: Int
    let tokensAfter: Int

    private var tokensFreed: Int {
        tokensBefore - tokensAfter
    }

    private var formattedFreed: String {
        if tokensFreed >= 1000 {
            return String(format: "%.1fk", Double(tokensFreed) / 1000.0)
        }
        return "\(tokensFreed)"
    }

    var body: some View {
        NotificationPill(tint: .teal) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.teal)

                Text("Context cleared")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.teal.opacity(0.9))

                Text("\u{2022}")
                    .font(TronTypography.badge)
                    .foregroundStyle(.teal.opacity(0.5))

                Text("\(formattedFreed) tokens freed")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.teal.opacity(0.7))
            }
        }
    }
}

// MARK: - Message Deleted Notification View

struct MessageDeletedNotificationView: View {
    let targetType: String

    private var typeLabel: String {
        switch targetType {
        case "message.user":
            return "user message"
        case "message.assistant":
            return "assistant message"
        case "tool.result":
            return "tool result"
        default:
            return "message"
        }
    }

    private var icon: String {
        switch targetType {
        case "message.user":
            return "person.fill.xmark"
        case "message.assistant":
            return "sparkles"
        case "tool.result":
            return "hammer.fill"
        default:
            return "trash.fill"
        }
    }

    var body: some View {
        NotificationPill(tint: .tronAmber) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronAmber)

                Text("Deleted \(typeLabel) from context")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronAmber.opacity(0.9))
            }
        }
    }
}

// MARK: - Skill Removed Notification View

struct SkillRemovedNotificationView: View {
    let skillName: String

    var body: some View {
        NotificationPill(tint: .tronCyan) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronCyan)

                Text(skillName)
                    .font(TronTypography.filePath)
                    .foregroundStyle(Color.tronCyan.opacity(0.9))

                Text("removed from context")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(Color.tronCyan.opacity(0.6))
            }
        }
    }
}

// MARK: - Rules Loaded Notification View

struct RulesLoadedNotificationView: View {
    let count: Int

    var body: some View {
        NotificationPill(tint: .tronIndigo) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronIndigo)

                Text("Loaded \(count) \(count == 1 ? "rule" : "rules")")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronIndigo.opacity(0.9))
            }
        }
    }
}

// MARK: - Workspace Deleted Notification View

struct WorkspaceDeletedNotificationView: View {
    var body: some View {
        NotificationPill(tint: .red) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.red)

                Text("Workspace deleted \u{2013} session in read-only mode")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
    }
}

// MARK: - Turn Failed Notification View

struct TurnFailedNotificationView: View {
    let error: String
    let code: String?
    let recoverable: Bool

    var body: some View {
        NotificationPill(tint: .red) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Request failed")
                        .font(TronTypography.filePath)
                        .foregroundStyle(.red.opacity(0.9))

                    Text(error)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Memory Notification View (unified in-progress → completed)

struct MemoryNotificationView: View {
    let isInProgress: Bool
    var title: String = ""
    var entryType: String = ""
    var onTap: (() -> Void)? = nil

    private let iconSize: CGFloat = TronTypography.sizeBody2
    private var isSkipped: Bool { entryType == "skipped" }

    var body: some View {
        NotificationPill(tint: .purple, interactive: true, onTap: isInProgress || isSkipped ? nil : onTap) {
            HStack(spacing: 8) {
                ZStack {
                    if isInProgress {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.purple)
                            .transition(.blurReplace)
                    } else {
                        Image(systemName: isSkipped ? "brain" : "brain.fill")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.purple.opacity(isSkipped ? 0.5 : 1))
                            .transition(.blurReplace)
                    }
                }
                .frame(width: iconSize, height: iconSize)

                Text(isInProgress ? "Retaining memory..." : isSkipped ? "Nothing new to retain" : "Memory updated")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.purple.opacity(isSkipped ? 0.5 : 0.9))
                    .contentTransition(.interpolate)

                if !isInProgress && !isSkipped && !title.isEmpty {
                    Text("\u{2022}")
                        .font(TronTypography.badge)
                        .foregroundStyle(.purple.opacity(0.5))
                        .transition(.blurReplace)

                    Text(title)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.purple.opacity(0.7))
                        .lineLimit(1)
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.35), value: isInProgress)
            .animation(.smooth(duration: 0.35), value: isSkipped)
        }
    }
}

// MARK: - Memories Loaded Notification View

struct MemoriesLoadedNotificationView: View {
    let count: Int

    var body: some View {
        NotificationPill(tint: .purple) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.purple)

                Text("Loaded \(count) \(count == 1 ? "memory" : "memories")")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.purple.opacity(0.9))
            }
        }
    }
}
