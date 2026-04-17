import SwiftUI

/// Result viewer for ManageProcess tool calls (expanded chip content).
/// Shows the action performed and result output.
struct ManageProcessResultViewer: View {
    let action: String
    let result: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gear")
                    .font(.caption)
                    .foregroundStyle(.tronSlate)
                Text(action)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronSlate)
            }
            if !result.isEmpty {
                Text(result)
                    .font(TronTypography.codeContentSM)
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 8)
            }
        }
    }
}
