import SwiftUI

// MARK: - Loading & Empty States for Session History View

/// Loading spinner for session history view
struct LoadingHistoryView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.tronPurple)
            Text("Loading history...")
                .font(TronTypography.mono(size: TronTypography.sizeBody3))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Empty state for session history view
struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(TronTypography.sans(size: 36, weight: .light))
                .foregroundStyle(.tronTextMuted.opacity(0.5))

            Text("No History")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)

            Text("Events will appear as you chat")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
