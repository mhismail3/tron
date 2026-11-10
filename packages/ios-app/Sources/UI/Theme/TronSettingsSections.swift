import SwiftUI

extension ContainerValues {
    @Entry var tronSettingsSection = true
}

private struct TronSettingsSectionCountKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension View {
    func tronSectionHeading() -> some View {
        modifier(TronSectionHeadingModifier())
            .containerValue(\.tronSettingsSection, false)
    }
}

private struct TronSectionHeadingModifier: ViewModifier {
    @Environment(\.tronSettingsSectionCount) private var count
    func body(content: Content) -> some View {
        if count != 1 { content.font(TronTypography.sheetSectionHeader) }
    }
}

extension EnvironmentValues {
    var tronSettingsSectionCount: Int? {
        get { self[TronSettingsSectionCountKey.self] }
        set { self[TronSettingsSectionCountKey.self] = newValue }
    }
}

struct TronSettingsSections<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat? = nil
    var lazy = false
    var hidesLoneHeading = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group(subviews: content()) { subviews in
            let count: Int? = hidesLoneHeading
                ? subviews.filter { $0.containerValues.tronSettingsSection }.count : nil
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
