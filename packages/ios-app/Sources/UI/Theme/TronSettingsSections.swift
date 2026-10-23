import SwiftUI

extension ContainerValues {
    @Entry var tronSettingsSection = true
}

private struct TronSettingsSectionCountKey: EnvironmentKey {
    static let defaultValue = 1
}

extension View {
    /// Custom section labels obey the same structural count as grouped cards.
    func tronSectionHeading() -> some View {
        modifier(TronSectionHeadingModifier())
            .containerValue(\.tronSettingsSection, false)
    }
}

private struct TronSectionHeadingModifier: ViewModifier {
    @Environment(\.tronSettingsSectionCount) private var count
    func body(content: Content) -> some View {
        if count > 1 { content.font(TronTypography.sheetSectionHeader) }
    }
}

extension EnvironmentValues {
    var tronSettingsSectionCount: Int {
        get { self[TronSettingsSectionCountKey.self] }
        set { self[TronSettingsSectionCountKey.self] = newValue }
    }
}

/// Counts structural sections before lazy layout, never just the currently visible
/// cards. A lone group needs no heading; a multi-section layout keeps its headings.
/// Each direct section-level subview owns one slot. Standalone explanatory
/// captions opt out with a container value; lazy visibility never changes count.
struct TronSettingsSections<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat? = nil
    var lazy = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group(subviews: content()) { subviews in
            let count = subviews.filter { $0.containerValues.tronSettingsSection }.count
            if lazy {
                LazyVStack(alignment: alignment, spacing: spacing) { content() }
                    .environment(\.tronSettingsSectionCount, count)
            } else {
                VStack(alignment: alignment, spacing: spacing) { content() }
                    .environment(\.tronSettingsSectionCount, count)
            }
        }
    }
}
