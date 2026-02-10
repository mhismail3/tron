import SwiftUI

struct DataSection: View {
    @Binding var confirmArchive: Bool
    let sessionCount: Int
    let hasActiveSessions: Bool
    let isArchivingAll: Bool
    let onArchiveAll: () -> Void

    var body: some View {
        Section {
            Toggle(isOn: $confirmArchive) {
                Label("Confirm before archiving", systemImage: "questionmark.circle")
                    .font(TronTypography.subheadline)
            }

            Button(role: .destructive) {
                onArchiveAll()
            } label: {
                HStack {
                    Label("Archive All Sessions", systemImage: "archivebox")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.red)
                    Spacer()
                    if isArchivingAll {
                        ProgressView()
                            .tint(.red)
                    }
                }
            }
            .disabled(!hasActiveSessions || isArchivingAll)
        } header: {
            Text("Session Management")
                .font(TronTypography.caption)
        } footer: {
            Text("Removes all sessions from your device. Session data on the server will remain.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
