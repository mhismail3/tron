import SwiftUI

struct PackageSourceField: View {
    @Binding var source: String
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    var body: some View {
        let accent = settingsTheme?.accent ?? .tronBlue
        TextField("Package source", text: $source)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .tronField(
                monospaced: true,
                compact: true,
                dense: true,
                surfaceTint: accent.opacity(0.14),
                border: accent.opacity(0.42)
            )
    }
}
