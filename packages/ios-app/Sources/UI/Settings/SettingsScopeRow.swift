import SwiftUI

/// The one "Every Project / Current Project" scope row. Locations and Overrides
/// owns the first use; the Hooks sheet reuses it so the two scopes can never be
/// spelled or offered differently. Current Project is only offered when the
/// caller has a project path to read.
struct SettingsScopeRow: View {
    let icon: String
    let title: String
    let scope: SettingsScope
    let allowsProjectScope: Bool
    let accent: Color
    let select: (SettingsScope) -> Void

    init(
        icon: String,
        title: String,
        scope: SettingsScope,
        allowsProjectScope: Bool,
        accent: Color = .tronEmerald,
        select: @escaping (SettingsScope) -> Void
    ) {
        self.icon = icon
        self.title = title
        self.scope = scope
        self.allowsProjectScope = allowsProjectScope
        self.accent = accent
        self.select = select
    }

    var body: some View {
        if allowsProjectScope {
            TronSelectionRow(
                icon: icon,
                title: title,
                value: scope == .project ? "Current Project" : "Every Project",
                accent: accent
            ) {
                Button("Every Project") { select(.global) }
                Button("Current Project") { select(.project) }
            }
        } else {
            TronValueRow(
                icon: icon,
                title: title,
                value: "Every Project",
                accent: accent
            )
        }
    }
}
