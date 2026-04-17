import SwiftUI

// MARK: - Fork Point Indicator

/// Visual indicator showing where a session was forked from
struct ForkPointIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.tronPurple.opacity(0.3))
                .frame(height: 1)

            HStack(spacing: 4) {
                Image(systemName: "tuningfork")
                    .font(TronTypography.sans(size: TronTypography.sizeSM))
                Text("FORKED HERE")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .bold))
            }
            .foregroundStyle(.tronPurple)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.tronPurple.opacity(0.12))
            .clipShape(Capsule())

            Rectangle()
                .fill(Color.tronPurple.opacity(0.3))
                .frame(height: 1)
        }
    }
}
