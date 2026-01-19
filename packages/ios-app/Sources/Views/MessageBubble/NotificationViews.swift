import SwiftUI

// MARK: - Model Change Notification View (Pill-style in-chat notification)

struct ModelChangeNotificationView: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronEmerald)

            Text("Switched from")
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)

            Text(from.shortModelName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tronTextMuted)

            Text(to.shortModelName)
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronEmerald)

            Text("Reasoning")
                .font(.system(size: 11))
                .foregroundStyle(.tronTextMuted)

            Text(from)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tronTextMuted)

            Text(to)
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)

            Text("Session interrupted")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)

            Text("Transcription failed")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.orange)

            Text("No speech detected")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.cyan)

            Text("Context compacted")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.9))

            Text("\u{2022}")
                .font(.system(size: 8))
                .foregroundStyle(.cyan.opacity(0.5))

            Text("\(formattedSaved) tokens saved")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.7))

            Text("(\(compressionPercent)%)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cyan.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.cyan.opacity(0.3), lineWidth: 0.5)
        )
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.teal)

            Text("Context cleared")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.teal.opacity(0.9))

            Text("\u{2022}")
                .font(.system(size: 8))
                .foregroundStyle(.teal.opacity(0.5))

            Text("\(formattedFreed) tokens freed")
                .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronAmber)

            Text("Deleted \(typeLabel) from context")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronCyan)

            Text(skillName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.tronCyan.opacity(0.9))

            Text("removed from context")
                .font(.system(size: 11, design: .monospaced))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tronAmber)

            Text("Loaded \(count) \(count == 1 ? "rule" : "rules")")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
