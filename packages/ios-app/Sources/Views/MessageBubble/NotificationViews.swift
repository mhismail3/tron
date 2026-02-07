import SwiftUI

// MARK: - Model Change Notification View (Pill-style in-chat notification)

struct ModelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurface.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Reasoning Level Change Notification View (Pill-style in-chat notification)

struct ReasoningLevelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronSurface.opacity(0.6))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Interrupted Notification View (Red pill-style in-chat notification)

struct InterruptedNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle.fill")
                .font(TronTypography.codeSM)
                .foregroundStyle(.red)

            Text("Session interrupted")
                .font(TronTypography.filePath)
                .foregroundStyle(.red.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Catching Up Notification View (Gray pill-style in-chat notification)

struct CatchingUpNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.gray)

            Text("Loading latest messages...")
                .font(TronTypography.filePath)
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Transcription Failed Notification View (Red pill-style in-chat notification)

struct TranscriptionFailedNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .font(TronTypography.codeSM)
                .foregroundStyle(.red)

            Text("Transcription failed")
                .font(TronTypography.filePath)
                .foregroundStyle(.red.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - No Speech Detected Notification View (Amber pill-style in-chat notification)

struct TranscriptionNoSpeechNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(TronTypography.codeSM)
                .foregroundStyle(Color.orange)

            Text("No speech detected")
                .font(TronTypography.filePath)
                .foregroundStyle(Color.orange.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Compaction In Progress Notification View (spinning cyan pill)

struct CompactionInProgressNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(.cyan)

            Text("Compacting context...")
                .font(TronTypography.filePath)
                .foregroundStyle(.cyan.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(InteractiveCapsuleGlass(tint: .cyan))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Compaction Notification View (Cyan pill-style in-chat notification)

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
        switch reason {
        case "pre_turn_guardrail":
            return "auto"
        case "threshold_exceeded":
            return "threshold"
        case "manual":
            return "manual"
        default:
            return reason
        }
    }

    var body: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(InteractiveCapsuleGlass(tint: .cyan))
        .contentShape(Capsule())
        .onTapGesture {
            onTap?()
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Context Cleared Notification View (Teal pill-style in-chat notification)

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.teal.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.teal.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Message Deleted Notification View (Orange pill-style in-chat notification)

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
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronAmber)

            Text("Deleted \(typeLabel) from context")
                .font(TronTypography.filePath)
                .foregroundStyle(.tronAmber.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronAmber.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronAmber.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Skill Removed Notification View (Teal pill-style in-chat notification)

struct SkillRemovedNotificationView: View {
    let skillName: String

    var body: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronCyan.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronCyan.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Rules Loaded Notification View (Amber pill-style in-chat notification)

struct RulesLoadedNotificationView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronAmber)

            Text("Loaded \(count) \(count == 1 ? "rule" : "rules")")
                .font(TronTypography.filePath)
                .foregroundStyle(.tronAmber.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronAmber.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronAmber.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Workspace Deleted Notification View (Red pill-style in-chat notification)

/// Notification shown when workspace folder was deleted
struct WorkspaceDeletedNotificationView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(TronTypography.codeSM)
                .foregroundStyle(.red)

            Text("Workspace deleted – session in read-only mode")
                .font(TronTypography.filePath)
                .foregroundStyle(.red.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Turn Failed Notification View (Red pill-style in-chat notification)

/// Notification shown when a turn fails due to errors
struct TurnFailedNotificationView: View {
    let error: String
    let code: String?
    let recoverable: Bool

    var body: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Memory Updated Notification View (Purple pill-style in-chat notification)

struct MemoryUpdatedNotificationView: View {
    let title: String
    let entryType: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.fill")
                .font(TronTypography.codeSM)
                .foregroundStyle(.purple)

            Text("Memory updated")
                .font(TronTypography.filePath)
                .foregroundStyle(.purple.opacity(0.9))

            Text("\u{2022}")
                .font(TronTypography.badge)
                .foregroundStyle(.purple.opacity(0.5))

            Text(title)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.purple.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(InteractiveCapsuleGlass(tint: .purple))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Interactive Capsule Glass Modifier

/// Applies interactive liquid glass on iOS 26+, falls back to tinted background + stroke on older iOS
private struct InteractiveCapsuleGlass: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint.opacity(0.35)).interactive(),
                    in: .capsule
                )
        } else {
            content
                .background(tint.opacity(0.1))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}
