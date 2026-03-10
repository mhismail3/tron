import SwiftUI

struct DangerZoneSection: View {
    let hasChatSession: Bool
    let hasActiveSessions: Bool
    let isArchivingAll: Bool
    let onResetChat: () -> Void
    let onArchiveAll: () -> Void
    let onResetSettings: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive) {
                onResetChat()
            } label: {
                Label("Reset Chat Session", systemImage: "arrow.counterclockwise")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.red)
            }
            .disabled(!hasChatSession)

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

            Button(role: .destructive) {
                onResetSettings()
            } label: {
                Label("Reset All Settings", systemImage: "arrow.trianglehead.counterclockwise")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Danger Zone")
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
                .foregroundStyle(.red)
        }
    }
}
