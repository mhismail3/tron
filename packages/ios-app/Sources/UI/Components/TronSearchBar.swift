import SwiftUI

/// Custom glass-pill search field matching Tron's design tokens.
///
/// Drop-in replacement for `.searchable` when the system chrome's placement
/// (bottom of list, detached from the feature) clashes with a sheet layout.
/// Renders a magnifying-glass icon on the left, a bound `TextField`, and a
/// trailing clear button that appears once text is entered.
struct TronSearchBar: View {
    @Binding var text: String
    var prompt: String = "Search"
    var accent: Color = .tronEmerald

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(accent)

            TextField(prompt, text: $text)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextPrimary)
                .tint(accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sectionFill(accent, cornerRadius: 999)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}
