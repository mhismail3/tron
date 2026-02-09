import SwiftUI

@available(iOS 26.0, *)
struct QuickSessionSection: View {
    let displayWorkspace: String
    let selectedModelDisplayName: String
    let onWorkspaceTap: () -> Void
    let onModelTap: () -> Void

    var body: some View {
        Section {
            HStack {
                Label("Workspace", systemImage: "folder")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(displayWorkspace)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onWorkspaceTap() }

            HStack {
                Label("Model", systemImage: "cpu")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(selectedModelDisplayName)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onModelTap() }
        } header: {
            Text("Quick Session")
                .font(TronTypography.caption)
        } footer: {
            Text("Long-press the + button to instantly start a session with these defaults.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
