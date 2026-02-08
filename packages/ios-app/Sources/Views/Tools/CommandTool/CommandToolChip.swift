import SwiftUI

// MARK: - CommandToolChip (iOS 26)

/// Compact chip for command tool calls (Read, Write, Edit, Bash, etc.)
/// Shows tool icon, name, summary, status, and duration
/// Tappable to open CommandToolDetailSheet
@available(iOS 26.0, *)
struct CommandToolChip: View {
    let data: CommandToolChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(data.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(statusColor)

                if !data.summary.isEmpty {
                    Text(data.summary)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(statusColor.opacity(0.7))
                        .lineLimit(1)
                        .transition(.blurReplace)
                }

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(statusColor.opacity(0.5))
                        .transition(.blurReplace)
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(statusColor.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .animation(.smooth(duration: 0.3), value: data.summary)
            .animation(.smooth(duration: 0.3), value: data.formattedDuration)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(statusColor.opacity(0.25)).interactive(),
            in: .capsule
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        let iconSize = TronTypography.sizeBodySM
        switch data.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: iconSize, height: iconSize)
                .tint(data.iconColor)
        case .success:
            Image(systemName: data.icon)
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(data.iconColor)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .running: return data.iconColor
        case .success: return data.iconColor
        case .error: return .tronError
        }
    }
}

// MARK: - CommandToolChip Fallback (iOS < 26)

/// Fallback chip without glass effect for older iOS versions
struct CommandToolChipFallback: View {
    let data: CommandToolChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(data.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(statusColor)

                if !data.summary.isEmpty {
                    Text(data.summary)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(statusColor.opacity(0.7))
                        .lineLimit(1)
                        .transition(.blurReplace)
                }

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(statusColor.opacity(0.5))
                        .transition(.blurReplace)
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(statusColor.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(statusColor.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .strokeBorder(statusColor.opacity(0.3), lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
            .animation(.smooth(duration: 0.3), value: data.summary)
            .animation(.smooth(duration: 0.3), value: data.formattedDuration)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        let iconSize = TronTypography.sizeBodySM
        switch data.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: iconSize, height: iconSize)
                .tint(data.iconColor)
        case .success:
            Image(systemName: data.icon)
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(data.iconColor)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .running: return data.iconColor
        case .success: return data.iconColor
        case .error: return .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("CommandTool Chip States") {
    VStack(spacing: 16) {
        // Read - success
        CommandToolChip(
            data: CommandToolChipData(
                id: "call_1",
                toolName: "Read",
                normalizedName: "read",
                icon: "doc.text",
                iconColor: .tronEmerald,
                displayName: "Read",
                summary: "example.swift",
                status: .success,
                durationMs: 25,
                arguments: "{}",
                result: "content",
                isResultTruncated: false
            ),
            onTap: { }
        )

        // Bash - running
        CommandToolChip(
            data: CommandToolChipData(
                id: "call_2",
                toolName: "Bash",
                normalizedName: "bash",
                icon: "terminal",
                iconColor: .tronEmerald,
                displayName: "Bash",
                summary: "npm install",
                status: .running,
                durationMs: nil,
                arguments: "{}",
                result: nil,
                isResultTruncated: false
            ),
            onTap: { }
        )

        // Grep - success with pattern
        CommandToolChip(
            data: CommandToolChipData(
                id: "call_3",
                toolName: "Grep",
                normalizedName: "grep",
                icon: "magnifyingglass",
                iconColor: .purple,
                displayName: "Grep",
                summary: "\"TODO\" in src",
                status: .success,
                durationMs: 120,
                arguments: "{}",
                result: "5 matches",
                isResultTruncated: false
            ),
            onTap: { }
        )

        // Read - error
        CommandToolChip(
            data: CommandToolChipData(
                id: "call_4",
                toolName: "Read",
                normalizedName: "read",
                icon: "doc.text",
                iconColor: .tronEmerald,
                displayName: "Read",
                summary: "missing.txt",
                status: .error,
                durationMs: 5,
                arguments: "{}",
                result: "File not found",
                isResultTruncated: false
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
