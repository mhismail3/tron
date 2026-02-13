import SwiftUI

struct DataSection: View {
    @Binding var confirmArchive: Bool
    @Binding var maxConcurrentSessions: Int
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void
    let sessionCount: Int
    let hasActiveSessions: Bool
    let isArchivingAll: Bool
    let onArchiveAll: () -> Void

    var body: some View {
        Section {
            HStack {
                Label("Max Sessions", systemImage: "square.stack.3d.up")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(maxConcurrentSessions)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                TronStepper(value: $maxConcurrentSessions, range: 1...50)
            }
            .onChange(of: maxConcurrentSessions) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(server: .init(maxConcurrentSessions: newValue))
                }
            }

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
                .font(TronTypography.bodySM)
        } footer: {
            Text("Removes all sessions from your device. Session data on the server will remain.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
