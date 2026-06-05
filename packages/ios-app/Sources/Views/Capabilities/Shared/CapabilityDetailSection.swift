import SwiftUI

// MARK: - Capability Detail Section

/// Solid detail container with the section header outside.
/// Reusable across capability detail sheets where payload readability matters.
@available(iOS 26.0, *)
struct CapabilityDetailSection<Trailing: View, Content: View>: View {
    let title: String
    var accent: Color = .tronSlate
    var tint: TintedColors
    var trailing: Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                trailing
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.tronSurface.opacity(0.86))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accent.opacity(0.16), lineWidth: 1)
                    }
            }
        }
    }
}

@available(iOS 26.0, *)
extension CapabilityDetailSection where Trailing == EmptyView {
    init(title: String, accent: Color = .tronSlate, tint: TintedColors, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.tint = tint
        self.trailing = EmptyView()
        self.content = content
    }
}
