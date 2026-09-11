import SwiftUI
import AppKit

/// Core onboarding still requires FDA only. The same permission surface is also
/// reachable after onboarding without changing the wizard's persisted position.
struct PermissionsStep: View {
    @Bindable var state: WizardState
    var body: some View { PermissionSetupView(statuses: $state.permissionStatuses) }
}

struct PermissionSetupView: View {
    @Binding var statuses: [Permission: PermissionStatus]
    @Environment(\.environmentSetup) private var setup
    @State private var activationObserver: NSObjectProtocol?
    @State private var settingsWatch: Task<Void, Never>?
    @State private var active = false
    @State private var checking = false
    @State private var busy = false
    @State private var actionID = UUID()
    @State private var probeID = UUID()
    @State private var serviceState = NativeHostServiceState.unavailable
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(PermissionsStepContent.intro)
                    .font(TronTypography.wizardBody).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                permissionRow(.fullDiskAccess, title: "Full Disk Access", detail: "Lets Tron read and edit files.")
                HStack {
                    Text(serviceState == .enabled ? "Native helper enabled" : "Optional: prepare computer control")
                        .font(TronTypography.wizardHeadline)
                    Spacer()
                    Button(serviceActionTitle) { changeService() }
                        .buttonStyle(.wizardSecondary)
                        .fixedSize()
                        .disabled(busy || !setup.canManageLaunchAgent)
                }
                if serviceState == .enabled {
                    Button("Disable Helper for Update") { changeService(disable: true) }
                        .buttonStyle(.wizardLink)
                        .disabled(busy || !setup.canManageLaunchAgent)
                    Text("Before replacing Tron.app, disable this helper using the current app. This joins capture before unregistering; it does not revoke permissions or stop the Gateway.")
                        .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                }
                if let actionError {
                    Text(actionError)
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Native helper setup failed: \(actionError)")
                }
                Text("Grant the permissions below after the helper is enabled.")
                    .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                permissionRow(.accessibility, title: "Accessibility", detail: "Prepares inspection and control of approved apps.")
                permissionRow(.inputMonitoring, title: "Input Monitoring", detail: "Prepares detection of user-session input.")
                permissionRow(.screenRecording, title: "Screen Recording", detail: "Prepares viewing of selected app windows.")
                if serviceState == .enabled, statuses[.screenRecording] != .granted {
                    Text("Screen Recording may be listed under Tron.app in macOS Settings. If it is enabled there but not here, restart the helper, then re-check. This does not restart the Gateway.")
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { Task { await refresh(showActivity: true) } } label: {
                    Label(checking ? "Checking permissions…" : "Re-check permissions",
                          systemImage: checking ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.wizardLink)
                .padding(.leading, PermissionsStepLayout.recheckLeadingPadding)
                .disabled(checking || busy)
            }
        }
        .onAppear { active = true; installActivationObserver() }
        .task(id: active) {
            guard active else { return }
            if statuses.isEmpty { try? await Task.sleep(nanoseconds: PermissionsStepContent.initialProbeDelayNanoseconds) }
            await refresh(showActivity: false)
        }
        .onDisappear { retirePresentation() }
    }

    private var serviceActionTitle: String {
        switch serviceState {
        case .enabled: "Restart Helper"
        case .needsApproval: "Open Login Items"
        case .needsRegistration, .unavailable: "Enable Helper"
        }
    }
    private func permissionRow(_ permission: Permission, title: String, detail: String) -> some View {
        let status = statuses[permission] ?? .notDetermined
        return WizardInfoCard(verticalPadding: PermissionsStepLayout.cardVerticalPadding,
                              horizontalPadding: PermissionsStepLayout.cardHorizontalPadding) {
            WizardIconTextRow(iconColumnWidth: PermissionsStepLayout.statusIconColumnWidth,
                              iconTextSpacing: PermissionsStepLayout.iconTextSpacing) {
                statusBadge(status).font(.system(size: PermissionsStepLayout.statusIconSize, weight: .semibold))
            } content: {
                VStack(alignment: .leading, spacing: PermissionsStepLayout.textLineSpacing) {
                    Text(title).font(TronTypography.wizardHeadline)
                    Text(detail).font(TronTypography.wizardBodySmall).foregroundStyle(.secondary)
                    Text(permission == .fullDiskAccess
                         ? "Enable \"\(PermissionsStepContent.appDisplayName(for: setup.applicationBundle))\" in Full Disk Access."
                         : "Press Allow, then follow the macOS prompt for Tron.")
                        .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                HStack(spacing: 8) {
                    if permission != .fullDiskAccess, status != .granted {
                        Button("Allow") { request(permission) }
                            .buttonStyle(.wizardSecondary)
                            .fixedSize()
                            .disabled(busy || serviceState != .enabled || !setup.canManageLaunchAgent)
                    }
                    Button { openSettings(permission) } label: { Image(systemName: "gearshape.fill") }
                        .buttonStyle(.wizardTertiary)
                        .accessibilityLabel("Open Settings for \(title)")
                }
            }
        }
    }

    @ViewBuilder private func statusBadge(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .denied: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .notDetermined: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .probeUnavailable: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    @MainActor private func changeService(disable: Bool = false) {
        guard active, !busy, setup.canManageLaunchAgent else { return }
        let id = UUID(); actionID = id; probeID = UUID(); busy = true; checking = false
        actionError = nil
        let restart = serviceState == .enabled
        Task { @MainActor in
            do {
                let result: NativeHostServiceState
                if disable {
                    try await setup.unregisterNativeHost()
                    result = await setup.nativeHostServiceState()
                } else if restart { result = try await setup.refreshNativeHost() }
                else { result = try await setup.enableNativeHost() }
                guard active, actionID == id else { return }
                serviceState = result
                busy = false
                await refresh(showActivity: true)
                if serviceState == .needsApproval { watchSettings(permission: nil) }
            } catch {
                guard active, actionID == id else { return }
                busy = false
                actionError = String(error.localizedDescription.prefix(512))
                await refresh(showActivity: false)
            }
        }
    }

    @MainActor private func request(_ permission: Permission) {
        guard active, !busy, serviceState == .enabled, setup.canManageLaunchAgent else { return }
        let id = UUID(); actionID = id; probeID = UUID(); busy = true; checking = false
        Task { @MainActor in
            _ = await setup.requestPermission(permission)
            guard active, actionID == id else { return }
            busy = false
            await refresh(showActivity: true)
            if statuses[permission] != .granted { watchSettings(permission: permission) }
        }
    }

    @MainActor private func refresh(showActivity: Bool) async {
        guard active, !busy, !Task.isCancelled else { return }
        let id = UUID(); probeID = id; checking = showActivity
        defer { if probeID == id { checking = false } }
        let native = await setup.nativeHostServiceState()
        guard active, !Task.isCancelled, probeID == id else { return }
        let result = await setup.probePermissions()
        guard active, !Task.isCancelled, probeID == id else { return }
        serviceState = native
        statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, result[$0] ?? .probeUnavailable) })
    }

    @MainActor private func openSettings(_ permission: Permission) {
        NSWorkspace.shared.open(permission.systemSettingsURL)
        watchSettings(permission: permission)
    }
    @MainActor private func watchSettings(permission: Permission?) {
        settingsWatch?.cancel()
        settingsWatch = Task { @MainActor in
            for _ in 0..<PermissionsStepContent.settingsGrantWatchAttempts {
                do { try await Task.sleep(nanoseconds: PermissionsStepContent.settingsGrantWatchIntervalNanoseconds) } catch { return }
                guard active else { return }
                await refresh(showActivity: false)
                if let permission, statuses[permission] == .granted { return }
                if permission == nil, serviceState == .enabled { return }
            }
        }
    }
    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { _ in
            Task { @MainActor in await refresh(showActivity: true) }
        }
    }
    private func retirePresentation() {
        active = false; probeID = UUID(); actionID = UUID(); checking = false; busy = false
        settingsWatch?.cancel(); settingsWatch = nil
        if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
        activationObserver = nil
        // The coordinator, not this view, still owns any accepted consent work.
    }
}

enum PermissionsStepContent {
    static let intro = "Full Disk Access is required for core setup. You can also prepare computer-control permissions here: enable the helper first, approve its background item if asked, then grant access. Computer control is not enabled by completing this page alone."
    static let initialProbeDelayNanoseconds: UInt64 = 520_000_000
    static let settingsGrantWatchAttempts = 24
    static let settingsGrantWatchIntervalNanoseconds: UInt64 = 750_000_000
    static func appDisplayName(for applicationBundle: URL) -> String {
        let name = applicationBundle.lastPathComponent
        return name.isEmpty ? "Tron.app" : name
    }
}

enum PermissionsStepLayout {
    static let cardHorizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 9
    static let statusIconColumnWidth: CGFloat = 26
    static let statusIconSize: CGFloat = 23
    static let iconTextSpacing: CGFloat = 9
    static let textLineSpacing: CGFloat = 2
    static let recheckLeadingPadding = cardHorizontalPadding + ((statusIconColumnWidth - 16) / 2)
}
