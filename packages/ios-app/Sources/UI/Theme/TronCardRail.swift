import SwiftUI

/// One horizontally scrolling rail of tinted Liquid Glass cards. Every rail in
/// the app uses this view so card chrome, tint, and press behavior stay
/// identical; callers supply the accent, the label, and the selection.
///
/// The rail adds no horizontal inset: place it inside the surrounding content's
/// existing padding so its first card lines up with the rows below it.
struct TronCardRail<Item, ID: Hashable, Content: View>: View {
    let title: String?
    let items: [Item]
    /// Cards are keyed by an explicitly unique identity: a model's display name
    /// repeats across providers, so `Identifiable` alone would collide.
    let identity: KeyPath<Item, ID>
    let accent: Color
    let isSelected: (Item) -> Bool
    let accessibilityLabel: (Item) -> String
    let accessibilityValue: ((Item) -> String)?
    let action: (Item) -> Void
    private let content: (Item) -> Content

    init(
        title: String? = nil,
        items: [Item],
        identity: KeyPath<Item, ID>,
        accent: Color,
        isSelected: @escaping (Item) -> Bool = { _ in false },
        accessibilityLabel: @escaping (Item) -> String,
        accessibilityValue: ((Item) -> String)? = nil,
        action: @escaping (Item) -> Void,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.title = title
        self.items = items
        self.identity = identity
        self.accent = accent
        self.isSelected = isSelected
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: identity) { item in
                        Button { action(item) } label: {
                            content(item)
                        }
                        .buttonStyle(.plain)
                        // Callers resolve the accent from their own theme, so the
                        // card never re-derives a different one from the ambient
                        // settings theme.
                        .tronGlassSurface(
                            accent: accent,
                            cornerRadius: 12,
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
            }
            .scrollClipDisabled()
        }
    }
}

/// The standard rail-card label: a leading name with an optional secondary
/// detail line, plus the shared selected-state checkmark.
struct TronRailCardLabel: View {
    let primary: String
    let secondary: String?
    var primaryLineLimit: Int = 1
    var minimumWidth: CGFloat = 92
    /// Non-nil paints the selected checkmark in that accent; nil leaves the
    /// trailing space to the text, which is what a selection-free rail wants.
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
