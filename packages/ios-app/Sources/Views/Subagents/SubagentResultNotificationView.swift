import SwiftUI

/// Notification chip shown when subagent(s) complete while the parent agent is idle.
/// Adapts layout for single vs multiple results:
/// - Single: shows task preview + "Review >"
/// - Multiple: shows count summary + "Review N >"
@available(iOS 26.0, *)
struct SubagentResultNotificationView: View {
    let results: [SubagentResultEntry]
    var onTap: (() -> Void)?

    private var isSingleResult: Bool { results.count == 1 }
    private var allSucceeded: Bool { results.allSatisfy(\.success) }

    private var accentColor: Color {
        allSucceeded ? .tronSuccess : .tronError
    }

    private var iconName: String {
        allSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var titleText: String {
        if isSingleResult {
            return results[0].success ? "Agent results ready" : "Agent failed"
        }
        return "\(results.count) agent results ready"
    }

    private var subtitleText: String {
        if isSingleResult {
            return results[0].taskPreview
        }
        let succeeded = results.filter(\.success).count
        let failed = results.count - succeeded
        if failed == 0 { return "All completed successfully" }
        if succeeded == 0 { return "All failed" }
        return "\(succeeded) completed, \(failed) failed"
    }

    private var reviewText: String {
        isSingleResult ? "Review" : "Review \(results.count)"
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                // Status indicator
                Image(systemName: iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    Text(subtitleText)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                // Tap hint
                HStack(spacing: 4) {
                    Text(reviewText)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                }
                .foregroundStyle(accentColor.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(accentColor.opacity(0.15)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
