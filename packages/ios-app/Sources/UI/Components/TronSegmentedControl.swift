import SwiftUI

/// Horizontal chip-button segmented control with equal-width segments.
/// Replaces system `Picker(.segmented)` with the app's glass design language.
struct TronSegmentedControl<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var accent: Color = .tronEmerald
    var animatesSelection: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                Button {
                    select(option.value)
                } label: {
                    Text(option.label)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
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

    private func select(_ value: T) {
        guard selection != value else { return }
        if animatesSelection {
            withAnimation(.easeOut(duration: 0.12)) {
                selection = value
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                selection = value
            }
        }
    }
}
