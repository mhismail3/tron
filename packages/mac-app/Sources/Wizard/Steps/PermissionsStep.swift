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
    var onContentHeight: ((CGFloat) -> Void)? = nil
    @Environment(\.environmentSetup) private var setup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activationObserver: NSObjectProtocol?
    @State private var settingsWatch: Task<Void, Never>?
    @State private var active = false
    @State private var checking = false
    @State private var busy = false
    @State private var actionID = UUID()
    @State private var probeID = UUID()
    // A missing value is intentional: service status is unknown until the
    // first read completes, so the UI cannot briefly imply Enable is needed.
    @State private var serviceState: NativeHostServiceState?
    @State private var actionError: String?

    private var stateAnimation: Animation? {
        reduceMotion ? nil : PermissionsStepContent.stateAnimation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(PermissionsStepContent.intro)
                    .font(TronTypography.wizardBody).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                permissionRow(.fullDiskAccess, title: "Full Disk Access", detail: "Lets Tron read and edit files.")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(serviceState == .enabled
                             ? "Native helper enabled"
                             : serviceState == nil
                                ? "Checking helper status…"
                                : "Optional: prepare computer control")
                            .font(TronTypography.wizardHeadline)
                        Spacer(minLength: 8)
                    }
                    HStack(spacing: 8) {
                        Button(serviceActionTitle) { changeService() }
                            .buttonStyle(.wizardSecondary)
                            .fixedSize()
                            .disabled(busy || serviceState == nil || !setup.canManageLaunchAgent)
                        if serviceState == .enabled {
                            Button("Disable Helper") { changeService(disable: true) }
                                .buttonStyle(.wizardSecondary)
                                .fixedSize()
                                .disabled(busy || !setup.canManageLaunchAgent)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .animation(stateAnimation, value: serviceState)
                if serviceState == .enabled {
                    Text("Quitting Tron safely stops the enabled helper and restores it when Tron launches again. Use Disable Helper when you want it to remain disabled.")
                        .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                permissionRow(.screenRecording, title: "Screen Recording", detail: "Prepares viewing of selected app windows.")
                if serviceState == .enabled, let screenStatus = statuses[.screenRecording], screenStatus != .granted {
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onContentHeight?(height)
            }
        }
        .onAppear { active = true; installActivationObserver() }
        .task(id: active) {
            guard active else { return }
            await refresh(showActivity: false)
        }
        .onDisappear { retirePresentation() }
    }

    private var serviceActionTitle: String {
        PermissionsStepContent.serviceActionTitle(for: serviceState)
    }
    private func permissionRow(_ permission: Permission, title: String, detail: String) -> some View {
        let status = statuses[permission]
        return WizardInfoCard(verticalPadding: PermissionsStepLayout.cardVerticalPadding,
                              horizontalPadding: PermissionsStepLayout.cardHorizontalPadding) {
            WizardIconTextRow(iconColumnWidth: PermissionsStepLayout.statusIconColumnWidth,
                              iconTextSpacing: PermissionsStepLayout.iconTextSpacing) {
                statusBadge(status).font(.system(size: PermissionsStepLayout.statusIconSize, weight: .semibold))
            } content: {
                VStack(alignment: .leading, spacing: PermissionsStepLayout.textLineSpacing) {
                    Text(title).font(TronTypography.wizardHeadline)
                    Text(detail).font(TronTypography.wizardBodySmall).foregroundStyle(.secondary)
                    Text(status == .granted ? "Access granted." : status == nil ? "Checking access…" : permission == .fullDiskAccess
                         ? "Enable \"\(PermissionsStepContent.appDisplayName(for: setup.applicationBundle))\" in Full Disk Access."
                         : "Press Allow, then follow the macOS prompt for Tron.")
                        .font(TronTypography.wizardCaption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                HStack(spacing: 8) {
                    if permission != .fullDiskAccess, let status, status != .granted {
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

    @ViewBuilder private func statusBadge(_ status: PermissionStatus?) -> some View {
        switch status {
        case nil: ProgressView().controlSize(.small)
        case .some(.granted): Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .some(.denied): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .some(.notDetermined): Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .some(.probeUnavailable): Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
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
                guard PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: actionID) else { return }
                withAnimation(stateAnimation) {
                    serviceState = result
                    busy = false
                }
                await refresh(showActivity: true)
                guard PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: actionID) else { return }
                if serviceState == .needsApproval { watchSettings(permission: nil) }
            } catch {
                guard PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: actionID) else { return }
                withAnimation(stateAnimation) {
                    busy = false
                    actionError = String(error.localizedDescription.prefix(512))
                }
                await refresh(showActivity: false)
            }
        }
    }

    @MainActor private func request(_ permission: Permission) {
        guard active, !busy, serviceState == .enabled, setup.canManageLaunchAgent else { return }
        let id = UUID(); actionID = id; probeID = UUID(); busy = true; checking = false
        Task { @MainActor in
            _ = await setup.requestPermission(permission)
            guard PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: actionID) else { return }
            withAnimation(stateAnimation) { busy = false }
            await refresh(showActivity: true)
            guard PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: actionID) else { return }
            if statuses[permission] != .granted { watchSettings(permission: permission) }
        }
    }

    @MainActor private func refresh(showActivity: Bool) async {
        guard active, !busy, !Task.isCancelled else { return }
        let id = UUID(); probeID = id; checking = showActivity
        defer { if probeID == id { checking = false } }
        let native = await setup.nativeHostServiceState()
        guard !Task.isCancelled,
              PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: probeID) else { return }
        withAnimation(stateAnimation) { serviceState = native }
        let result = await setup.probePermissions()
        guard !Task.isCancelled,
              PermissionsStepContent.presentationIsCurrent(active: active, requestID: id, currentID: probeID) else { return }
        withAnimation(stateAnimation) {
            serviceState = native
            statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, result[$0] ?? .probeUnavailable) })
        }
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
    static let intro = "Full Disk Access is required for core setup. Optional computer-control permissions can be prepared here after enabling the helper."
    static let stateAnimation = Animation.easeInOut(duration: 0.2)
    static let settingsGrantWatchAttempts = 24
    static func serviceActionTitle(for state: NativeHostServiceState?) -> String {
        switch state {
        case nil: "Checking Helper…"
        case .some(.enabled): "Restart Helper"
        case .some(.needsApproval): "Open Login Items"
        case .some(.needsRegistration), .some(.unavailable): "Enable Helper"
        }
    }
    static func presentationIsCurrent(active: Bool, requestID: UUID, currentID: UUID) -> Bool {
        active && requestID == currentID
    }
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
