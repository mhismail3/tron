import SwiftUI
import AppKit

/// Permissions step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / Continue, with Continue gated by
/// all three grants in `WizardShell.permissionsCanContinue`). This
/// view contributes the description, the three permission cards each
/// with their own "Open Settings" deep-link (rendered as the emerald
/// tertiary icon-button), and an inline Re-check link that re-runs
/// `setup.probePermission(...)` for every category.
///
/// The three categories map 1:1 to the macOS TCC probes the Rust
/// agent runs at startup (`packages/agent/src/tools/ui/computer_use/
/// permissions.rs`). Notifications was removed once we verified the
/// Mac wrapper never posts one; Screen Recording was added because
/// the Computer-Use tool's screenshots depend on it.
struct PermissionsStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tron needs three macOS permissions for its file and Computer-Use tools. Each opens System Settings to the right pane — return here when done; the wizard re-checks automatically.")
                .font(.body)
                .foregroundStyle(.secondary)

            // The canvas grows to `WizardStep.permissions.preferredHeight`
            // so all three rows fit naturally — no scroll container
            // needed. Sparse step heights on other screens shrink the
            // window back down.
            VStack(spacing: 10) {
                permissionRow(.fullDiskAccess,
                              title: "Full Disk Access",
                              detail: "Lets Tron's file tools read and edit files outside the app sandbox.",
                              required: true)
                permissionRow(.screenRecording,
                              title: "Screen Recording",
                              detail: "Lets Tron's Computer-Use tool take screenshots of your screen.",
                              required: true)
                permissionRow(.accessibility,
                              title: "Accessibility",
                              detail: "Lets Tron's Computer-Use tool send clicks and keystrokes.",
                              required: true)
            }
            .padding(.vertical, 1) // avoid GroupBox shadow clip

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
            // `.center` vertical alignment keeps the icon button
            // optically anchored to the middle of the row regardless
            // of whether the detail copy wraps to two lines; the old
            // `.top` alignment looked off-axis on single-line rows.
            HStack(alignment: .center, spacing: 12) {
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
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.wizardTertiary)
                .help("Open Settings")
                .accessibilityLabel("Open Settings for \(title)")
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
