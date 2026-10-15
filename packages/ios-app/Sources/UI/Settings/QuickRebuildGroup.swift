import SwiftUI
import TronMobileCore

/// What one quick rebuild row can do right now. Availability mirrors the owning
/// detail sheets: the Gateway source rebuild needs the update helper and a
/// configured source repository; the device install needs the installer and a
/// configured source repository for this device.
enum QuickRebuildRowState: Equatable {
    case ready
    case running
    case unavailable(String)

    static func gateway(supported: Bool, configured: Bool, active: Bool) -> Self {
        guard supported else { return .unavailable("Not supported by this Gateway") }
        if active { return .running }
        return configured ? .ready : .unavailable("Set a source repository in server details")
    }

    static func device(supported: Bool, configured: Bool, active: Bool) -> Self {
        guard supported else { return .unavailable("Not supported by this Gateway") }
        if active { return .running }
        return configured ? .ready : .unavailable("Set a source repository in device details")
    }
}

/// What the Replace Mac App row offers: the path the Mac would take, a running
/// replacement, or why it is unavailable (#984).
enum MacReplacementRowState: Equatable {
    case ready(String)
    case running(String)
    case unavailable(String)

    static func resolve(supported: Bool, plan: Result<MacReplacementPlan, GatewayFailure>?,
                        operation: MacReplacementOperation?, requested: Bool) -> Self {
        guard supported else { return .unavailable("Not supported by this Gateway") }
        if let operation, !operation.isTerminal {
            let step = operation.steps.first { $0.name == operation.currentStep }?.title ?? "Starting"
            return .running("\(MacReplacementPresentation.stateTitle(operation)) · \(step)")
        }
        if requested { return .running("Starting") }
        switch plan {
        case .none: return .unavailable("Checking what changed…")
        case .failure(let failure): return .unavailable(failure.message)
        case .success(let plan):
            guard plan.startable else { return .unavailable("Only the Stable Mac app can be replaced from here") }
            return plan.path == "none" ? .unavailable(plan.reason) : .ready(plan.reason)
        }
    }
}

/// Last group in Connections: two-tap rebuilds of the selected server and of
/// this iPhone's optimized build from that server, and the one-tap Mac app
/// replacement. Commands go through the same model owners as the server and
/// device detail sheets.
struct QuickRebuildGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity

    let profile: GatewayProfile
    /// This iPhone's authorization on `profile`, when the device list has it.
    let thisDevice: GatewayAuthorizedDevice?
    /// Presents the replacement progress sheet, owned by Connections so it
    /// stays up while this group's Gateway is down for the swap.
    let showReplacement: () -> Void

    @State private var gatewayConfigured = false
    @State private var gatewayStatus: GatewayUpdateStatus?
    @State private var gatewayCommandID: String?
    @State private var installConfigured = false
    @State private var installStatus: IosDeviceInstallStatus?
    @State private var requesting = false
    @State private var replacementPlan: Result<MacReplacementPlan, GatewayFailure>?
    @State private var replacement: MacReplacementOperation?
    @State private var replacementRequested = false
    @State private var loadGeneration = 0

    private var capabilities: [String] { model.gatewayInfo?.capabilities ?? [] }

    private var gatewayState: QuickRebuildRowState {
        .gateway(
            supported: AppModel.supportsGatewayUpdate(capabilities: capabilities),
            configured: gatewayConfigured,
            active: gatewayCommandID != nil || gatewayStatus?.isActive == true
        )
    }

    private var deviceState: QuickRebuildRowState {
        .device(
            supported: thisDevice != nil && AppModel.supportsIosDeviceInstall(capabilities: capabilities),
            configured: installConfigured,
            active: installStatus?.state.isActive == true
        )
    }

    private var replacementState: MacReplacementRowState {
        .resolve(
            supported: AppModel.supportsMacReplacement(capabilities: capabilities),
            plan: replacementPlan,
            operation: replacement,
            requested: replacementRequested
        )
    }

    private var replacementRunning: Bool {
        if case .running = replacementState { return true }
        return false
    }

    /// Part of the load task identity, so an accepted command starts following
    /// its progress immediately.
    private var isRunning: Bool { gatewayState == .running || deviceState == .running || replacementRunning }

    var body: some View {
        TronSettingsGroup("Quick Rebuild", detail: "Rebuild from source on \(profile.label).", accent: .tronEmerald) {
            VStack(spacing: 0) {
                row(
                    icon: "desktopcomputer",
                    title: "Rebuild Gateway",
                    readyDetail: profile.label,
                    state: gatewayState,
                    accessibilityName: "Gateway"
                ) { await rebuildGateway() }
                TronSettingsDivider(accent: .tronEmerald)
                row(
                    icon: "iphone",
                    title: "Rebuild iPhone App",
                    readyDetail: "Optimized build for this iPhone",
                    state: deviceState,
                    accessibilityName: "iPhone app"
                ) { await rebuildDevice() }
                if AppModel.supportsMacReplacement(capabilities: capabilities) {
                    TronSettingsDivider(accent: .tronEmerald)
                    replacementRow
                }
            }
        }
        .task(id: PresentationActivityTaskID(
            source: "\(profile.id):\(model.connectionState == .connected):\(thisDevice?.id ?? "none"):\(model.foregroundReconciliationGeneration):\(scenePhase == .active):\(isRunning)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard admitsRead else { return }
            await load()
            // Follow accepted work until it settles; the task restarts when the
            // Gateway reconnects after its own rebuild.
            while isRunning {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard admitsRead else { return }
                await load()
            }
        }
        .onDisappear { loadGeneration &+= 1 }
    }

    private func row(
        icon: String,
        title: String,
        readyDetail: String,
        state: QuickRebuildRowState,
        accessibilityName: String,
        confirm: @escaping () async -> Void
    ) -> some View {
        let detail: String
        switch state {
        case .ready: detail = readyDetail
        case .running: detail = "Rebuild in progress"
        case .unavailable(let reason): detail = reason
        }
        return TronValueRow(icon: icon, title: title, detail: detail, accent: .tronEmerald) {
            // One tap opens the menu, a second confirms; Cancel or tapping
            // outside dismisses without a command.
            Menu {
                Button("Confirm") { Task { await confirm() } }
                Button("Cancel", role: .cancel) {}
            } label: {
                TronInlineActionLabel("Restart", isWorking: state == .running, accent: .tronEmerald)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .disabled(state != .ready || requesting)
            .accessibilityLabel("Restart \(accessibilityName)")
        }
    }

    private var replacementRow: some View {
        let detail: String
        switch replacementState {
        case .ready(let reason), .running(let reason), .unavailable(let reason): detail = reason
        }
        return TronValueRow(icon: "macwindow", title: "Replace Mac App", detail: detail, accent: .tronEmerald) {
            if replacementRunning {
                Button(action: showReplacement) {
                    TronInlineActionLabel("Progress", isWorking: true, accent: .tronEmerald)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Mac app replacement progress")
            } else {
                // Same two-tap pattern as the rebuild rows; the last journal
                // stays one tap away after it settles.
                Menu {
                    if case .ready = replacementState {
                        Button("Confirm") { Task { await replaceMacApp() } }
                    }
                    if replacement != nil {
                        Button("Show Last Replacement") { showReplacement() }
                    }
                    Button("Cancel", role: .cancel) {}
                } label: {
                    TronInlineActionLabel("Replace", accent: .tronEmerald)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .disabled(requesting || (replacement == nil && { if case .ready = replacementState { return false }; return true }()))
                .accessibilityLabel("Replace Mac app")
            }
        }
    }

    private var admitsRead: Bool {
        !Task.isCancelled
            && presentationActivity.allowsPresentationPublication
            && scenePhase == .active
            && model.profiles.selected?.id == profile.id
            && model.connectionState == .connected
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        func current() -> Bool { generation == loadGeneration && admitsRead }

        if AppModel.supportsGatewayUpdate(capabilities: capabilities) {
            let config = await model.loadGatewayUpdateConfig(for: profile)
            guard current() else { return }
            gatewayConfigured = config != nil
            if let status = await model.loadGatewayUpdateStatus(for: profile), current() {
                gatewayStatus = status
                if let commandID = gatewayCommandID,
                   GatewayUpdatePollingDecision.decide(status, commandID: commandID) == .terminal {
                    gatewayCommandID = nil
                }
            }
        }
        if AppModel.supportsMacReplacement(capabilities: capabilities) {
            let status = await model.loadMacReplacementStatus(for: profile)
            guard current() else { return }
            replacement = status?.operation
            if replacement.map({ !$0.isTerminal }) == true { replacementRequested = false }
            // The plan runs git on the Mac; refresh it only when nothing is running.
            if !replacementRunning || replacementPlan == nil {
                let plan = await model.loadMacReplacementPlan(for: profile)
                guard current() else { return }
                replacementPlan = plan
            }
        }
        guard current(), let thisDevice,
              AppModel.supportsIosDeviceInstall(capabilities: capabilities) else { return }
        do {
            let config = try await model.loadIosDeviceInstallConfig(for: thisDevice)
            guard current() else { return }
            installConfigured = config?.sourceRoot != nil
            let status = try await model.loadIosDeviceInstallStatus(for: thisDevice)
            guard current() else { return }
            installStatus = status
        } catch {
            // Disposable read: keep the last published state. The device
            // detail sheet surfaces install read errors.
            return
        }
    }

    private func rebuildGateway() async {
        guard !requesting, gatewayState == .ready else { return }
        requesting = true
        defer { requesting = false }
        if let commandID = await model.requestGatewayUpdate(for: profile, mode: "source") {
            gatewayCommandID = commandID
        }
    }

    private func replaceMacApp() async {
        guard !requesting, case .ready = replacementState else { return }
        requesting = true
        defer { requesting = false }
        if await model.startMacReplacement(for: profile) != nil {
            replacementRequested = true
            showReplacement()
        }
    }

    private func rebuildDevice() async {
        guard !requesting, deviceState == .ready, let thisDevice else { return }
        requesting = true
        defer { requesting = false }
        do {
            _ = try await model.requestIosDeviceInstall(for: thisDevice, buildMode: .optimized)
            installStatus = try await model.loadIosDeviceInstallStatus(for: thisDevice)
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }
}
