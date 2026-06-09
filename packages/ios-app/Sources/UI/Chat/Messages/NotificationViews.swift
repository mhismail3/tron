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
            content
                .glassEffect(
                    .regular.tint(tint.opacity(0.35)).interactive(),
                    in: .capsule
                )
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
        case "capability.invocation.completed":
            return "capability result"
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
        case "capability.invocation.completed":
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
        case "auth",
             "authentication": base = "Auth Error"
        case "authorization": base = "Access Denied"
        case "rate_limit": base = "Rate Limited"
        case "network": base = "Network Error"
        case "server": base = "Server Error"
        case "invalid_request": base = "Invalid Request"
        case "invalid_model": base = "Invalid Model"
        case "not_found": base = "Not Found"
        case "unavailable": base = "Unavailable"
        case "conflict": base = "Conflict"
        case "api": base = "API Error"
        case "parse": base = "Parse Error"
        case "cancelled": base = "Cancelled"
        case "capability": base = "Capability Error"
        case "engine": base = "Engine Error"
        case "persistence": base = "Persistence Error"
        case "internal": base = "Internal Error"
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
        case "auth",
             "authentication": return "lock.fill"
        case "authorization": return "lock.shield.fill"
        case "rate_limit": return "clock.fill"
        case "network": return "wifi.slash"
        case "server": return "exclamationmark.icloud.fill"
        case "invalid_request": return "xmark.circle.fill"
        case "invalid_model": return "cpu"
        case "not_found": return "questionmark.folder.fill"
        case "unavailable": return "exclamationmark.icloud.fill"
        case "conflict": return "arrow.triangle.branch"
        case "api": return "network"
        case "parse": return "curlybraces"
        case "cancelled": return "xmark.circle"
        case "capability": return "wrench.and.screwdriver.fill"
        case "engine": return "gearshape.2.fill"
        case "persistence": return "externaldrive.fill"
        case "internal": return "exclamationmark.octagon.fill"
        case "quota": return "creditcard.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}
