import SwiftUI

// MARK: - Memory Section (auto-injected memories, non-expandable)

@available(iOS 26.0, *)
struct MemorySection: View {
    let memory: LoadedMemory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.purple)
                .frame(width: 18)
            Text("Memory")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.purple)

            // Count badge
            Text("\(memory.count)")
                .font(TronTypography.pillValue)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.7))
                .clipShape(Capsule())

            Spacer()

            Text(TokenFormatter.format(memory.tokens))
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.purple.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
