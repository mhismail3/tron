import SwiftUI

/// A shared value row for generic renderer controls and existing configuration
/// surfaces. Compact contexts use the standard settings row; full contexts keep
/// the value-row presentation.
struct AgentConfigurationValueRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var information: String? = nil
    let value: String
    let accent: Color
    @ViewBuilder let control: () -> Control
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if controlSize == .small {
            TronSettingsRow(icon: icon, title: title, subtitle: information, accent: accent) {
                control()
            }
        } else {
            TronValueRow(icon: icon, title: title, detail: detail, value: value, accent: accent) {
                control()
            }
        }
    }
}
