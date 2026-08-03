import SwiftUI

// MARK: - Status Row

/// Shared status row with horizontal scroll of pills: status badge + optional duration + additional pills.
struct ToolStatusRow<AdditionalPills: View>: View {
    let status: ToolInvocationStatus
    let durationMs: Int?
    @ViewBuilder let additionalPills: () -> AdditionalPills

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: status)
                if let ms = durationMs {
                    ToolDurationBadge(durationMs: ms)
                }
                additionalPills()
            }
        }
        .scrollClipDisabled()
    }
}

extension ToolStatusRow where AdditionalPills == EmptyView {
    init(status: ToolInvocationStatus, durationMs: Int?) {
        self.status = status
        self.durationMs = durationMs
        self.additionalPills = { EmptyView() }
    }
}
