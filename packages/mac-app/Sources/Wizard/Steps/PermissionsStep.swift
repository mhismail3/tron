import AppKit
import SwiftUI

struct PermissionsStep: View {
    @Bindable var state: GatewayOnboardingModel
    @Environment(\.gatewayDependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable Full Disk Access so Tron Gateway can work with the files you choose.")
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WizardInfoCard(verticalPadding: 12) {
                WizardIconTextRow {
                    Image(systemName: status == .granted ? "checkmark.seal.fill" : "lock.shield.fill")
                        .font(.title2)
                        .foregroundStyle(status == .granted ? .green : .orange)
                        .accessibilityHidden(true)
                } content: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Full Disk Access").font(TronTypography.wizardHeadline)
                        Text(instruction)
                            .font(TronTypography.wizardBodySmall)
                            .foregroundStyle(.secondary)
                    }
                } trailing: {
                    Button {
                        NSWorkspace.shared.open(Permission.fullDiskAccess.systemSettingsURL)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.wizardTertiary)
                    .help("Open Full Disk Access settings")
                    .accessibilityLabel("Open Full Disk Access settings")
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                state.refreshPermissions()
            } label: {
                Label(state.isRefreshing ? "Checking permissions…" : "Re-check permissions", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.wizardLink)
            .disabled(state.isRefreshing)
            Spacer(minLength: 0)
        }
        .task { state.refreshPermissions() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { state.refreshPermissions() }
        }
    }

    private var status: PermissionStatus {
        state.permissionStatuses[.fullDiskAccess] ?? .notDetermined
    }

    private var instruction: String {
        let name = dependencies.configuration.applicationBundle.lastPathComponent
        return status == .granted
            ? "\(name) is enabled."
            : "Enable \"\(name)\" in System Settings."
    }
}
