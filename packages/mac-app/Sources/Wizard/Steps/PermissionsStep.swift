import SwiftUI
import AppKit

struct PermissionsStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Grant permissions")
                .font(.largeTitle.bold())
            Text("Tron needs three macOS permissions. Each opens System Settings to the right pane — return here when done; the wizard re-checks automatically.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                permissionRow(.fullDiskAccess,
                              title: "Full Disk Access",
                              detail: "Lets Tron's tools read files outside its sandbox (Read, Edit, search). Required.",
                              required: true)
                permissionRow(.notifications,
                              title: "Notifications",
                              detail: "Surfaces agent-completion alerts. Required for hands-off use.",
                              required: true)
                permissionRow(.accessibility,
                              title: "Accessibility",
                              detail: "Reserved for the upcoming Computer-Use tool. Skippable today.",
                              required: false)
            }

            HStack {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
                Spacer()
                Button {
                    state.advance()
                } label: {
                    Text("Continue")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .task { await refreshAll() }
    }

    @ViewBuilder
    private func permissionRow(_ permission: Permission, title: String, detail: String, required: Bool) -> some View {
        let status = state.permissionStatuses[permission] ?? .notDetermined
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                statusBadge(status)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.headline)
                        if required {
                            Text("Required")
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red.opacity(0.15), in: Capsule())
                                .foregroundStyle(.red)
                        }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(PermissionDeepLink.url(for: permission))
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.octagon.fill").font(.title).foregroundStyle(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle.fill").font(.title).foregroundStyle(.orange)
        case .probeUnavailable:
            Image(systemName: "minus.circle.fill").font(.title).foregroundStyle(.secondary)
        }
    }

    private var canContinue: Bool {
        // Required perms must be granted; Accessibility is skippable.
        let fda = state.permissionStatuses[.fullDiskAccess] ?? .notDetermined
        let notif = state.permissionStatuses[.notifications] ?? .notDetermined
        return fda == .granted && notif == .granted
    }

    private func refreshAll() async {
        for permission in Permission.allCases {
            let status = await setup.probePermission(permission)
            state.permissionStatuses[permission] = status
        }
    }
}
