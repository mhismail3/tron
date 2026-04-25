import SwiftUI
import AppKit

/// Permissions step. The shell owns the icon, title, progress pill,
/// and the bottom action bar (Back / Continue, with Continue gated by
/// all three grants in `WizardShell.permissionsCanContinue`). This
/// view contributes the description, the three permission cards each
/// with their own "Open Settings" deep-link, and an inline Re-check
/// link.
///
/// This step runs AFTER Install (see `WizardStep.allCases` ordering
/// test) on purpose. macOS ties sandbox/TCC extensions to the process
/// that was launched when the grant was made, so granting FDA to the
/// agent before it exists would prompt the user for a permission they
/// can't satisfy. By the time the wizard gets here the agent bundle
/// is already on disk at `~/.tron/system/Tron.app` and the LaunchAgent
/// is running — the user grants permissions to "Tron Server" in
/// System Settings. When they return from a Settings pane opened via
/// this step, we consume that single round-trip, `launchctl kickstart
/// -k` the agent when the permission was previously missing, and then
/// re-probe so the new grant takes effect without a visible restart
/// prompt.
///
/// The three categories map 1:1 to the macOS TCC probes exposed by the
/// agent's `system.probePermissions` RPC. The wizard polls that RPC
/// (rather than probing the wrapper's own TCC state) because the agent
/// is the binary that actually runs the Computer-Use tool and the file
/// tools — the wrapper itself never touches FDA / Screen Recording /
/// Accessibility at runtime.
struct PermissionsStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var appActivationObserver: NSObjectProtocol?
    @State private var pollTask: Task<Void, Never>?
    @State private var restarting = false
    @State private var pendingSettingsReturn: PermissionSettingsReturn?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Grant these three permissions to \(TronPaths.agentDisplayName) in System Settings. Come back here when you're done — Tron picks up the grants automatically.")
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                permissionRow(.fullDiskAccess,
                              title: "Full Disk Access",
                              detail: "Lets Tron read and edit files outside the sandbox.")
                permissionRow(.screenRecording,
                              title: "Screen Recording",
                              detail: "Lets Tron take screenshots for its Computer-Use tool.")
                permissionRow(.accessibility,
                              title: "Accessibility",
                              detail: "Lets Tron send clicks and keystrokes.")
            }
            .padding(.vertical, 1)

            Button {
                Task { await refreshAll(kickstart: false) }
            } label: {
                Label(restarting ? "Restarting Tron Server…" : "Re-check permissions",
                      systemImage: restarting ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.wizardLink)
            .padding(.leading, PermissionsStepLayout.recheckLeadingPadding)
            .disabled(restarting)
        }
        .task { await startPolling() }
        .onAppear { installAppActivationObserver() }
        .onDisappear { teardown() }
    }

    // MARK: - Row + badge

    @ViewBuilder
    private func permissionRow(_ permission: Permission, title: String, detail: String) -> some View {
        let status = state.permissionStatuses[permission] ?? .notDetermined
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                statusBadge(status)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(TronTypography.wizardHeadline)
                    Text(detail).font(TronTypography.wizardBodySmall).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    pendingSettingsReturn = PermissionSettingsReturn(
                        permission: permission,
                        statusBeforeOpen: status
                    )
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

    // MARK: - Polling + kickstart lifecycle

    /// Starts the 2 s agent-probe poll loop. Runs until the view
    /// disappears or all three grants are observed, whichever comes
    /// first. The loop is re-entrant — calling this twice is a no-op
    /// thanks to the `pollTask` guard.
    private func startPolling() async {
        // Seed the state with an immediate probe so the UI doesn't
        // render three orange "?" badges for 2 s on first display.
        await refreshAll(kickstart: false)

        guard pollTask == nil else { return }
        pollTask = Task { [weak state = self.state] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                if Task.isCancelled { break }
                let snapshot = await setup.probeAgentPermissions()
                await MainActor.run {
                    guard let state else { return }
                    for (permission, status) in snapshot {
                        state.permissionStatuses[permission] = status
                    }
                }
                // Stop polling once everything is granted — no point
                // hammering the RPC when the user is still on this
                // step admiring their green badges.
                let allGranted = await MainActor.run { [weak state] in
                    Permission.allCases.allSatisfy { p in
                        (state?.permissionStatuses[p]) == .granted
                    }
                }
                if allGranted { break }
            }
        }
    }

    /// Installs an observer on `NSApp.didBecomeActiveNotification`.
    /// When the user comes back to the wrapper, we first check whether
    /// that activation corresponds to a Settings pane opened by this
    /// view. Plain app activation is only a recheck; otherwise clicking
    /// around System Settings can repeatedly restart the server.
    ///
    /// The observer is stored as a `@State` token so `onDisappear` can
    /// remove it — SwiftUI will recreate the view each time the user
    /// navigates to this step, so leaving the observer attached would
    /// leak one per visit.
    private func installAppActivationObserver() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await handleAppActivation()
            }
        }
    }

    private func teardown() {
        pollTask?.cancel()
        pollTask = nil
        if let token = appActivationObserver {
            NotificationCenter.default.removeObserver(token)
            appActivationObserver = nil
        }
    }

    /// One-shot agent probe. When `kickstart` is true, we first
    /// `launchctl kickstart -k` the agent — this is the seamless
    /// restart that lets a freshly-granted FDA extension take effect
    /// without the user ever seeing the "Tron Server must quit"
    /// dialog. Best-effort: if kickstart fails (launchd refuses for
    /// any reason), we fall through to a plain probe so the UI still
    /// reflects real state.
    private func refreshAll(kickstart: Bool) async {
        if kickstart {
            restarting = true
            defer { restarting = false }
            _ = await setup.launchAgentManager.restart(label: TronPaths.launchAgentLabel)
            // Wait for the first successful ping after restart. The
            // agent comes up in ~500 ms on warm starts but we budget
            // generously so a slow first launch doesn't show a false
            // "denied" flash while the RPC socket is still reopening.
            let token = setup.readBearerToken()
            for _ in 0..<20 {
                switch await setup.pingServer(token) {
                case .success, .unauthorized:
                    // Agent is up (even on auth error, the process is
                    // running and answering RPCs).
                    let snapshot = await setup.probeAgentPermissions()
                    for (permission, status) in snapshot {
                        state.permissionStatuses[permission] = status
                    }
                    return
                case .unreachable, .timeout, .malformedResponse:
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        let snapshot = await setup.probeAgentPermissions()
        for (permission, status) in snapshot {
            state.permissionStatuses[permission] = status
        }
    }

    /// Wrapper for the app-activation path. The pending Settings
    /// round-trip is consumed before awaiting so repeated activation
    /// notifications from the same System Settings visit cannot enqueue
    /// repeated `launchctl kickstart -k` calls.
    private func handleAppActivation() async {
        guard state.step == .permissions else { return }
        let pendingReturn = pendingSettingsReturn
        pendingSettingsReturn = nil

        switch PermissionSettingsReturnPolicy.action(for: pendingReturn) {
        case .recheckOnly:
            await refreshAll(kickstart: false)
        case .restartAndRecheck:
            await refreshAll(kickstart: true)
        }
    }
}

enum PermissionsStepLayout {
    static let recheckLeadingPadding: CGFloat = 12
}
