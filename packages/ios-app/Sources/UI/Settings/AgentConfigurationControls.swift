import SwiftUI

/// Shared model and reasoning controls used by both persisted defaults and a
/// live session. Keeping the sheet link and inline menu here prevents the
/// Manage Session surface from drifting back to stock menus.
struct TronModelSelectionRow: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    let navigationTitle: String
    var accent: Color = .tronPurple

    var body: some View {
        TronProgressiveSheetLink(accessibilityLabel: navigationTitle) {
            ModelPicker(selection: $selection, models: models)
                .tronNavigationTitle(navigationTitle, accent: accent)
        } label: {
            TronValueRow(
                icon: "cpu",
                title: "Model",
                value: selection?.displayDescription ?? "Choose model",
                accent: accent
            )
        }
    }
}

struct TronThinkingSelectionRow: View {
    @Binding var selection: String
    let levels: [String]
    var accent: Color = .tronPurple

    var body: some View {
        TronValueRow(
            icon: "brain",
            title: "Thinking",
            value: selection.capitalized,
            accent: accent
        ) {
            TronInlineMenu("Change", accent: accent) {
                ForEach(levels, id: \.self) { level in
                    Button(level.capitalized) { selection = level }
                }
            }
        }
    }
}
