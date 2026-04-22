import SwiftUI

// ARCHITECTURE: ~609 lines — 15+ notification pill types, each with distinct layout
// and interaction behavior. These are leaf views with no shared state beyond the common
// NotificationPill container. Large by variety, not complexity.

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
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "arrow.right")
                    .font(TronTypography.pill)
                    .foregroundStyle(.tronTextMuted)

                Text(to)
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
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
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "arrow.right")
                    .font(TronTypography.pill)
                    .foregroundStyle(.tronTextMuted)

                Text(to)
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
        }
    }
}

// MARK: - Interrupted Notification View

struct InterruptedNotificationView: View {
    var body: some View {
        NotificationPill(tint: .tronError) {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronError)

                Text("Session interrupted")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronError.opacity(0.9))
            }
        }
    }
}

// MARK: - Catching Up Notification View

struct CatchingUpNotificationView: View {
    var body: some View {
        NotificationPill(tint: .tronSlate) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.tronSlate)

                Text("Loading latest messages...")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronSlate)
            }
        }
    }
}

// MARK: - Transcription Failed Notification View

struct TranscriptionFailedNotificationView: View {
    var body: some View {
        NotificationPill(tint: .tronError) {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronError)

                Text("Transcription failed")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronError.opacity(0.9))
            }
        }
    }
}

// MARK: - No Speech Detected Notification View

struct TranscriptionNoSpeechNotificationView: View {
    var body: some View {
        NotificationPill(tint: .tronAmber) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(Color.tronAmber)

                Text("No speech detected")
                    .font(TronTypography.filePath)
                    .foregroundStyle(Color.tronAmber.opacity(0.9))
            }
        }
    }
}

// MARK: - Compaction Notification View (unified in-progress + completed)

struct CompactionNotificationView: View {
    let isInProgress: Bool
    var tokensBefore: Int = 0
    var tokensAfter: Int = 0
    var reason: String = ""
    var onTap: (() -> Void)? = nil

    private let iconSize: CGFloat = TronTypography.sizeBody2

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

    var body: some View {
        NotificationPill(tint: .tronSky, interactive: !isInProgress, onTap: isInProgress ? nil : onTap) {
            HStack(spacing: 8) {
                ZStack {
                    if isInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.tronSky)
                            .transition(.blurReplace)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronSky)
                            .transition(.blurReplace)
                    }
                }
                .frame(width: iconSize, height: iconSize)

                Text(isInProgress ? "Compacting context..." : "Context compacted")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronSky.opacity(0.9))
                    .contentTransition(.interpolate)

                if !isInProgress && tokensSaved > 0 {
                    Text("\u{2022}")
                        .font(TronTypography.badge)
                        .foregroundStyle(.tronSky.opacity(0.5))
                        .transition(.blurReplace)

                    Text("\(formattedSaved) tokens saved")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronSky.opacity(0.7))
                        .transition(.blurReplace)

                    Text("(\(compressionPercent)%)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronSky.opacity(0.5))
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.35), value: isInProgress)
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
        NotificationPill(tint: .tronSky) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronSky)

                Text("Context cleared")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronSky.opacity(0.9))

                Text("\u{2022}")
                    .font(TronTypography.badge)
                    .foregroundStyle(.tronSky.opacity(0.5))

                Text("\(formattedFreed) tokens freed")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronSky.opacity(0.7))
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
        NotificationPill(tint: .tronSky) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronSky)

                Text("Deleted \(typeLabel) from context")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronSky.opacity(0.9))
            }
        }
    }
}

// MARK: - Skill Deactivated Notification View

struct SkillDeactivatedNotificationView: View {
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

                Text("deactivated from context")
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

// MARK: - Rules Activated Notification View

struct RulesActivatedNotificationView: View {
    let rules: [ActivatedRuleEntry]
    let totalActivated: Int

    var body: some View {
        NotificationPill(tint: .tronIndigo) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronIndigo)

                Text("Loaded \(rules.count) nested \(rules.count == 1 ? "rule" : "rules")")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronIndigo.opacity(0.9))
            }
        }
    }
}

// MARK: - Workspace Deleted Notification View

struct WorkspaceDeletedNotificationView: View {
    var body: some View {
        NotificationPill(tint: .tronError) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronError)

                Text("Workspace deleted \u{2013} session in read-only mode")
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronError.opacity(0.9))
            }
        }
    }
}

// MARK: - Turn Failed Notification View

/// Renders a `turn.failed` notification pill. When the server marked the
/// failure `recoverable` AND the caller passes an `onRetry` closure, the
/// pill surfaces a "Retry" button (C7) that re-issues the last user prompt.
///
/// Non-recoverable failures (or surfaces that don't want to offer retry,
/// e.g. read-only history reconstruction) render the same pill without
/// the button.
struct TurnFailedNotificationView: View {
    let error: String
    let code: String?
    let recoverable: Bool
    var onRetry: (() -> Void)? = nil

    var body: some View {
        NotificationPill(tint: .tronError) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronError)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Request failed")
                        .font(TronTypography.filePath)
                        .foregroundStyle(.tronError.opacity(0.9))

                    Text(error)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                }

                if recoverable, let onRetry {
                    Spacer(minLength: 4)

                    Button(action: onRetry) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(TronTypography.codeCaption)
                            Text("Retry")
                                .font(TronTypography.badge)
                        }
                        .foregroundStyle(.tronError)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.tronError.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry failed turn")
                    .accessibilityHint("Re-sends the last user prompt")
                }
            }
        }
    }
}

// MARK: - Provider Error Notification View

struct ProviderErrorNotificationView: View {
    let data: ProviderErrorDetailData
    var onTap: (() -> Void)? = nil

    var body: some View {
        NotificationPill(tint: .tronError, interactive: true, onTap: onTap) {
            HStack(spacing: 8) {
                Image(systemName: ErrorCategoryDisplay.icon(for: data.category))
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronError)

                Text(ErrorCategoryDisplay.label(for: data.category, provider: data.provider))
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronError.opacity(0.9))

                Text("\u{2022}")
                    .font(TronTypography.badge)
                    .foregroundStyle(.tronError.opacity(0.5))

                Text(data.message)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .baselineOffset(0.5)
            }
        }
    }
}

// MARK: - Error Category Display

enum ErrorCategoryDisplay {
    static func providerDisplayName(for provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "Anthropic"
        case "openai-codex", "openai": return "OpenAI"
        case "google": return "Google"
        case "minimax": return "MiniMax"
        case "kimi": return "Kimi"
        default: return provider.capitalized
        }
    }

    static func label(for category: String, provider: String? = nil) -> String {
        let base: String
        switch category {
        case "authentication": base = "Auth Error"
        case "authorization": base = "Access Denied"
        case "rate_limit": base = "Rate Limited"
        case "network": base = "Network Error"
        case "server": base = "Server Error"
        case "invalid_request": base = "Invalid Request"
        case "quota": base = "Quota Exceeded"
        default: base = "Error"
        }
        if let provider, !provider.isEmpty, provider != "unknown" {
            return "\(providerDisplayName(for: provider)) \(base)"
        }
        return base
    }

    static func icon(for category: String) -> String {
        switch category {
        case "authentication": return "lock.fill"
        case "authorization": return "lock.shield.fill"
        case "rate_limit": return "clock.fill"
        case "network": return "wifi.slash"
        case "server": return "exclamationmark.icloud.fill"
        case "invalid_request": return "xmark.circle.fill"
        case "quota": return "creditcard.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Memory Retained Notification View (unified in-progress + completed)

struct MemoryRetainedNotificationView: View {
    let isInProgress: Bool
    var title: String?
    var nothingNew: Bool = false
    /// True when the retain was fired automatically by the auto-retain policy.
    /// Changes the in-progress pill text to "Auto-retaining memory...".
    var isAuto: Bool = false
    /// Non-nil signals that an auto-retain attempt failed mid-pipeline (H3).
    /// When present, the pill renders in an error tint with the provided reason
    /// rather than the success/in-progress states.
    var failureReason: String? = nil
    var onTap: (() -> Void)? = nil

    private let iconSize: CGFloat = TronTypography.sizeBody2

    /// Single source of truth for the pill tint — error when the retain
    /// failed, pink otherwise.
    private var tint: Color { failureReason == nil ? .tronPink : .tronError }

    var body: some View {
        NotificationPill(
            tint: tint,
            interactive: !isInProgress && (title != nil || failureReason != nil),
            onTap: isInProgress ? nil : onTap
        ) {
            HStack(spacing: 8) {
                ZStack {
                    if isInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(tint)
                            .transition(.blurReplace)
                    } else if failureReason != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(tint)
                            .transition(.blurReplace)
                    } else {
                        Image(systemName: "brain")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(tint)
                            .transition(.blurReplace)
                    }
                }
                .frame(width: iconSize, height: iconSize)

                if let failureReason {
                    Text("Auto-retain failed")
                        .font(TronTypography.filePath)
                        .foregroundStyle(tint.opacity(0.9))
                        .contentTransition(.interpolate)

                    Text("\u{2022}")
                        .font(TronTypography.badge)
                        .foregroundStyle(tint.opacity(0.5))
                        .transition(.blurReplace)

                    Text(failureReason)
                        .font(TronTypography.filePath)
                        .foregroundStyle(tint.opacity(0.7))
                        .lineLimit(1)
                        .transition(.blurReplace)
                } else if isInProgress {
                    Text(isAuto ? "Auto-retaining memory..." : "Retaining memory...")
                        .font(TronTypography.filePath)
                        .foregroundStyle(tint.opacity(0.9))
                        .contentTransition(.interpolate)
                } else if let title {
                    Text("Memory saved")
                        .font(TronTypography.filePath)
                        .foregroundStyle(tint.opacity(0.9))
                        .contentTransition(.interpolate)

                    Text("\u{2022}")
                        .font(TronTypography.badge)
                        .foregroundStyle(tint.opacity(0.5))
                        .transition(.blurReplace)

                    Text(inlineMarkdown(from: title, size: TronTypography.sizeBody2))
                        .foregroundStyle(tint.opacity(0.7))
                        .lineLimit(1)
                        .transition(.blurReplace)
                } else {
                    Text("Nothing new to retain")
                        .font(TronTypography.filePath)
                        .foregroundStyle(tint.opacity(0.6))
                        .contentTransition(.interpolate)
                }
            }
            .animation(.smooth(duration: 0.35), value: isInProgress)
        }
    }
}

// MARK: - Skills Cleared Notification View (M6)

/// Renders the `skills.cleared` event emitted on the first prompt after a
/// compaction boundary when active skills were cleared.
///
/// The `mode` discriminator controls layout:
///
/// - `.clearAll`: informational banner — single horizontal pill listing the
///   cleared skill names. Non-interactive; user can re-add skills manually
///   via `@skill-name` or the sidebar. Flat styling to mirror the other
///   informational pills (compaction, rules).
///
/// - `.askUser`: interactive picker — a header line ("Re-activate N skills?")
///   above a wrapped row of tappable chips. Tapping a chip fires
///   `onReactivate(skillName)` which percolates up as
///   `MessageBubbleTapAction.reactivateSkill` and ultimately invokes the
///   `skill.activate` RPC. Tapped chips greying-out is tracked locally via
///   `activatedSkills` — the server-emitted `skill.activated` event is the
///   source of truth, but local feedback is needed for tap responsiveness.
///
/// Empty `clearedSkills` is not rendered (caller drops the message), so the
/// view always has at least one skill to display.
struct SkillsClearedNotificationView: View {
    let clearedSkills: [String]
    let mode: SkillsClearedMode
    /// Invoked when the user taps a skill chip (AskUser mode only). Nil in
    /// ClearAll mode; the informational banner has no interaction.
    var onReactivate: ((String) -> Void)? = nil

    /// Skills the user has tapped this render cycle. Kept local to the view
    /// so the chip greys out immediately; the authoritative state comes back
    /// via the server-emitted `skill.activated` event, which clears the
    /// skill from the `inputBarState.selectedSkills` set elsewhere.
    @State private var activatedSkills: Set<String> = []

    var body: some View {
        switch mode {
        case .clearAll:
            clearAllBanner
        case .askUser:
            askUserPicker
        }
    }

    // MARK: ClearAll — informational banner

    private var clearAllBanner: some View {
        NotificationPill(tint: .tronCyan) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronCyan)

                Text(clearAllPrefix)
                    .font(TronTypography.filePath)
                    .foregroundStyle(Color.tronCyan.opacity(0.9))

                Text(clearedSkills.joined(separator: ", "))
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(Color.tronCyan.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var clearAllPrefix: String {
        let noun = clearedSkills.count == 1 ? "skill" : "skills"
        return "Cleared \(clearedSkills.count) \(noun) on compaction:"
    }

    // MARK: AskUser — interactive picker

    private var askUserPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronCyan)
                Text(askUserHeader)
                    .font(TronTypography.filePath)
                    .foregroundStyle(Color.tronCyan.opacity(0.9))
            }

            // Wrapping row of chips. `FlowLayout` would be nicer but SwiftUI
            // doesn't ship one — fall back to horizontal ScrollView to avoid
            // pulling in a third-party layout for a rare UI element.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(clearedSkills, id: \.self) { name in
                        chip(for: name)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tronCyan.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronCyan.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var askUserHeader: String {
        let noun = clearedSkills.count == 1 ? "skill" : "skills"
        return "Re-activate \(clearedSkills.count) \(noun)?"
    }

    @ViewBuilder
    private func chip(for name: String) -> some View {
        let isActivated = activatedSkills.contains(name)
        Button {
            guard !isActivated else { return }
            activatedSkills.insert(name)
            onReactivate?(name)
        } label: {
            HStack(spacing: 4) {
                if isActivated {
                    Image(systemName: "checkmark")
                        .font(TronTypography.codeSM)
                        .transition(.blurReplace)
                } else {
                    Image(systemName: "plus")
                        .font(TronTypography.codeSM)
                        .transition(.blurReplace)
                }
                Text(name)
                    .font(TronTypography.codeCaption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isActivated ? Color.tronCyan.opacity(0.5) : .tronCyan)
            .background(Color.tronCyan.opacity(isActivated ? 0.05 : 0.15))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.tronCyan.opacity(isActivated ? 0.2 : 0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isActivated)
        .animation(.smooth(duration: 0.25), value: isActivated)
    }
}

