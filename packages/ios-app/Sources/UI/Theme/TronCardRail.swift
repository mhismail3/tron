import SwiftUI

struct TronCardRail<Item, ID: Hashable, Content: View>: View {
    let items: [Item]
    let identity: KeyPath<Item, ID>
    let accent: Color
    let cornerRadius: CGFloat
    let isSelected: (Item) -> Bool
    let isEnabled: Bool
    let accessibilityLabel: (Item) -> String
    let accessibilityValue: ((Item) -> String)?
    let action: (Item) -> Void
    private let content: (Item) -> Content

    init(
        items: [Item],
        identity: KeyPath<Item, ID>,
        accent: Color,
        cornerRadius: CGFloat = 12,
        isSelected: @escaping (Item) -> Bool = { _ in false },
        isEnabled: Bool = true,
        accessibilityLabel: @escaping (Item) -> String,
        accessibilityValue: ((Item) -> String)? = nil,
        action: @escaping (Item) -> Void,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.identity = identity
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.action = action
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(items, id: identity) { item in
                    Button { action(item) } label: {
                        content(item)
                            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .tronGlassSurface(
                        accent: accent,
                        cornerRadius: cornerRadius,
                        tintOpacity: isSelected(item) ? 0.30 : 0.15,
                        interactive: true,
                        respectsSettingsTheme: false
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(item))
                    .accessibilityValue(accessibilityValue?(item) ?? "")
                }
            }
            .padding(.vertical, 4)
            .chatSecondaryScrollContent()
        }
        .scrollClipDisabled()
    }
}

struct TronRailCardLabel: View {
    let primary: String
    let secondary: String?
    var primaryLineLimit: Int = 1
    var minimumWidth: CGFloat = 92
    var selectionAccent: Color?

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronAccentText)
                    .lineLimit(primaryLineLimit)
                if let secondary {
                    Text(secondary)
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: minimumWidth, alignment: .leading)
            if let selectionAccent {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(selectionAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
