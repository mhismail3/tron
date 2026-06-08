import SwiftUI

// MARK: - Status Row

/// Shared status row with horizontal scroll of pills: status badge + optional duration + additional pills.
struct CapabilityStatusRow<AdditionalPills: View>: View {
    let status: CapabilityInvocationStatus
    let durationMs: Int?
    @ViewBuilder let additionalPills: () -> AdditionalPills

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CapabilityStatusBadge(status: status)
                if let ms = durationMs {
                    CapabilityDurationBadge(durationMs: ms)
                }
                additionalPills()
            }
        }
        .scrollClipDisabled()
    }
}

extension CapabilityStatusRow where AdditionalPills == EmptyView {
    init(status: CapabilityInvocationStatus, durationMs: Int?) {
        self.status = status
        self.durationMs = durationMs
        self.additionalPills = { EmptyView() }
    }
}
