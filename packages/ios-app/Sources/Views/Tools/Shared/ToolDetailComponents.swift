import SwiftUI

// MARK: - Shared Tool Detail Components (iOS 26 Liquid Glass)

/// Glass container with section header outside, matching SkillDetailSheet pattern.
/// Reusable across all tool detail sheets.
@available(iOS 26.0, *)
struct ToolDetailSection<Trailing: View, Content: View>: View {
    let title: String
    var accent: Color = .tronSlate
    var tint: TintedColors
    var trailing: Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                trailing
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accent.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

@available(iOS 26.0, *)
extension ToolDetailSection where Trailing == EmptyView {
    init(title: String, accent: Color = .tronSlate, tint: TintedColors, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.tint = tint
        self.trailing = EmptyView()
        self.content = content
    }
}

// MARK: - Status Badge

/// Glass pill for tool status (completed/running/failed)
@available(iOS 26.0, *)
struct ToolStatusBadge: View {
    let status: CommandToolStatus

    private var statusColor: Color {
        switch status {
        case .running: return .tronAmber
        case .success: return .tronSuccess
        case .error: return .tronError
        }
    }

    private var statusText: String {
        switch status {
        case .running: return "Running"
        case .success: return "Completed"
        case .error: return "Failed"
        }
    }

    private var statusIcon: String {
        switch status {
        case .running: return ""
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .running {
                ProgressView()
                    .scaleEffect(0.55)
                    .tint(statusColor)
            } else {
                Image(systemName: statusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
            }
            Text(statusText)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(statusColor.opacity(0.25)), in: Capsule())
        }
    }
}

// MARK: - Duration Badge

/// Glass pill with clock icon + formatted duration
@available(iOS 26.0, *)
struct ToolDurationBadge: View {
    let durationMs: Int

    private var formattedDuration: String {
        if durationMs < 1000 {
            return "\(durationMs)ms"
        } else {
            return String(format: "%.1fs", Double(durationMs) / 1000.0)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 11))
            Text(formattedDuration)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
        }
        .foregroundStyle(.tronTextMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronSlate.opacity(0.15)), in: Capsule())
        }
    }
}

// MARK: - Info Pill

/// Generic glass pill (icon + label + color), reusable for line counts, truncation, etc.
@available(iOS 26.0, *)
struct ToolInfoPill: View {
    let icon: String
    let label: String
    var color: Color = .tronSlate

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: Capsule())
        }
    }
}

// MARK: - Error View

/// Structured error display with icon, title, path, error code badge, and suggestion
@available(iOS 26.0, *)
struct ToolErrorView: View {
    let icon: String
    let title: String
    let path: String
    let errorCode: String?
    let suggestion: String
    var tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(.tronError)

                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronError)
            }

            if !path.isEmpty {
                Text(path)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.secondary)
                    .textSelection(.enabled)
            }

            if let code = errorCode {
                ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
            }

            Text(suggestion)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.subtle)
        }
    }
}
