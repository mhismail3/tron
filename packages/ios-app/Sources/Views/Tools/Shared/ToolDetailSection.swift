import SwiftUI

// MARK: - Tool Detail Section

/// Glass container with section header outside, matching SkillDetailSheet pattern.
/// Reusable across all tool detail sheets.
@available(iOS 26.0, *)
struct ToolDetailSection<Trailing: View, Content: View>: View {
    let title: String
    var accent: Color = .tronSlate
    var tint: TintedColors
    var trailing: Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
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
                    .fill(.clear)
                    .glassEffect(.regular.tint(accent.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

@available(iOS 26.0, *)
extension ToolDetailSection where Trailing == EmptyView {
    init(title: String, accent: Color = .tronSlate, tint: TintedColors, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.tint = tint
        self.trailing = EmptyView()
        self.content = content
    }
}
