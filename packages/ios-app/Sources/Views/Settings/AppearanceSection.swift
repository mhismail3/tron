import SwiftUI

struct AppearanceSection: View {
    @State private var appearanceSettings = AppearanceSettings.shared

    var body: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { appearanceSettings.mode },
                set: { appearanceSettings.mode = $0 }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.tronSurface)
        } header: {
            Text("Appearance")
                .font(TronTypography.caption)
        } footer: {
            Text("Auto follows your system appearance setting.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
