import SwiftUI

struct AdvancedSection: View {
    let onResetSettings: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive) {
                onResetSettings()
            } label: {
                Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Advanced")
                .font(TronTypography.caption)
        }
    }
}
