import SwiftUI

struct ToolInvocationChip: View {
    let data: ToolInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var display: ToolInvocationDisplayModel { data.display }
    private var evidence: ToolEvidencePresentation { ToolEvidencePresentation(data: data) }
    private var brief: ToolInvocationBriefPresentation { ToolInvocationBriefPresentation(data: data) }
    private var accent: Color {
        ToolPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 7) {
                leadingAccessory

                Text(evidence.chipText)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                inlineStatusView

                trailingAccessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(chipTint, tintOpacity: colorScheme == .light ? 0.30 : 0.38)
        .contextMenu {
            if data.status == .running || data.status == .generating {
                Button(role: .destructive) {
                    onCancel?()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(accessibilityLabel)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: data.status)
        .animation(.easeInOut(duration: 0.18), value: data.formattedDuration)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if data.status == .running || data.status == .generating {
            ProgressView()
                .controlSize(.small)
                .tint(textColor.opacity(0.72))
                .frame(width: 18, height: 18)
        } else if brief.isBackgroundHandoff {
            Image(systemName: "arrow.up.forward.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        Image(systemName: "chevron.right")
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(textColor.opacity(0.56))
    }

    @ViewBuilder
    private var inlineStatusView: some View {
        if data.status == .running || data.status == .generating {
            TimelineView(.periodic(from: data.startedAt ?? data.generatedAt ?? Date(), by: 0.25)) { context in
                if let elapsed = data.formattedElapsed(at: context.date) {
                    inlineStatusText(elapsed)
                }
            }
        } else if brief.isBackgroundHandoff {
            inlineStatusText("background")
        } else if let duration = data.formattedDuration {
            inlineStatusText(duration)
        } else if let status = terminalStatusText {
            inlineStatusText(status)
        }
    }

    private func inlineStatusText(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(textColor.opacity(0.68))
            .lineLimit(1)
            .monospacedDigit()
            .frame(minWidth: 38, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var terminalStatusText: String? {
        switch data.status {
        case .error:
            return "failed"
        case .unavailable:
            return "unavailable"
        case .generating, .running, .success:
            return nil
        }
    }

    private var chipTint: Color {
        accent
    }

    private var textColor: Color {
        accent
    }

    private var accessibilityLabel: String {
        [
            evidence.title,
            evidence.qualifier,
            evidence.statusLabel,
            evidence.duration
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct ToolInvocationGroupChip: View {
    let data: ToolInvocationGroupData
    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        switch data.displayStatus {
        case .error, .unavailable:
            return .tronError
        default:
            return .tronEmerald
        }
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 7) {
                leadingAccessory

                Text(data.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if let status = data.inlineStatusText {
                    Text(status)
                        .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.68))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.56))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(accent, tintOpacity: colorScheme == .light ? 0.30 : 0.38)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(accessibilityLabel)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: data.displayStatus)
        .animation(.easeInOut(duration: 0.18), value: data.count)
        .animation(.easeInOut(duration: 0.18), value: data.runningCount)
        .animation(.easeInOut(duration: 0.18), value: data.failedCount)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if data.isActive {
            ProgressView()
                .controlSize(.small)
                .tint(accent.opacity(0.72))
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: data.displayStatus.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
        }
    }

    private var accessibilityLabel: String {
        [
            data.title,
            data.inlineStatusText
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
