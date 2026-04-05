import SwiftUI

/// Horizontal chip-button segmented control with equal-width segments.
/// Replaces system `Picker(.segmented)` with the app's glass design language.
struct TronSegmentedControl<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var accent: Color = .tronEmerald

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(isSelected ? .tronSurface : accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? accent : accent.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
