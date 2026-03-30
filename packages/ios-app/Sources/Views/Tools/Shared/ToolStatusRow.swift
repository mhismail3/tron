import SwiftUI

// MARK: - Status Row

/// Shared status row with horizontal scroll of pills: status badge + optional duration + additional pills.
/// Eliminates the duplicated ScrollView + HStack + badges pattern across 10 tool sheets.
@available(iOS 26.0, *)
struct ToolStatusRow<AdditionalPills: View>: View {
    let status: CommandToolStatus
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

@available(iOS 26.0, *)
extension ToolStatusRow where AdditionalPills == EmptyView {
    init(status: CommandToolStatus, durationMs: Int?) {
        self.status = status
        self.durationMs = durationMs
        self.additionalPills = { EmptyView() }
    }
}
