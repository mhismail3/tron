import SwiftUI
import AppKit

/// Permissions step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / Continue, with Continue gated by
/// FDA + Notifications grants in `WizardShell.permissionsCanContinue`).
/// This view contributes the description, the three permission cards
/// each with their own "Open Settings" deep link, and an inline
/// Re-check link that re-runs `setup.probePermission(...)` for all
/// three categories.
struct PermissionsStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tron needs three macOS permissions. Each opens System Settings to the right pane — return here when done; the wizard re-checks automatically.")
                .font(.body)
                .foregroundStyle(.secondary)

            // Cards live in their own scroll container so they don't
            // overflow the shorter (360pt) wizard window when all
            // three are visible. The description above and the
            // Re-check button below stay pinned outside the scroller
            // so the user always sees the context + the recovery
            // affordance regardless of scroll position.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
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
                .padding(.vertical, 1) // avoid GroupBox shadow clip
            }

            // Tertiary action: lives inside the body so it slides
            // with the cards and stays visually anchored to the
            // permission list it operates on.
            Button {
                Task { await refreshAll() }
            } label: {
                Label("Re-check permissions", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.wizardLink)
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
            .padding(.vertical, 6)
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

    private func refreshAll() async {
        for permission in Permission.allCases {
            let status = await setup.probePermission(permission)
            state.permissionStatuses[permission] = status
        }
    }
}
