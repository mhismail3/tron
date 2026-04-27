import SwiftUI
import Darwin

/// Install step. The shell owns the icon, title, progress pill, and
/// the bottom action bar. Its primary CTA starts as "Install" and
/// only advances as "Continue" after `installOutcome ∈ {.success,
/// .alreadyInstalled}`. This view contributes the description, the
/// per-stage progress list, and an error summary on failure.
struct InstallStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var stages: [InstallPipelineStage: StageState] = [:]
    @State private var cleanupIsRunning = false
    @State private var cleanupError: String?
    @State private var showCleanupConfirmation = false
    @State private var installStatusText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: InstallStepLayout.sectionSpacing) {
            Text(InstallStepContent.intro)
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shouldUseDetectedInstallLayout {
                detectedInstallSummary
            } else {
                stageProgressArea

                if let outcome = state.installOutcome, outcome != .success, outcome != .alreadyInstalled {
                    WizardInfoCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(outcomeDescription(outcome))
                                .font(TronTypography.wizardBodySmall)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            cleanupControls(.retry)
                        }
                    }
                }

                if installIsComplete {
                    installedSummary
                }

                cleanupFeedback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(WizardLayout.transitionAnimation, value: installIsComplete)
        .task {
            // Auto-skip if we know an existing install is fully present.
            // This path is observational: it does not copy, write, or
            // touch launchd. Partial/clean states wait for explicit user
            // confirmation via the shell's Install CTA.
            prepareAlreadyInstalledStateIfNeeded()
            prepareTerminalInstallStateIfNeeded()
        }
        .task(id: state.installRequestID) {
            guard state.installRequestID > 0 else { return }
            guard state.hasUnhandledInstallRequest else {
                prepareTerminalInstallStateIfNeeded()
                return
            }
            await runPipeline(requestID: state.installRequestID)
        }
        .task(id: state.installOutcome) {
            guard installIsComplete else {
                installStatusText = nil
                return
            }
            await refreshInstallStatus()
        }
        .confirmationDialog(
            "Clean up install artifacts?",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean up install", role: .destructive) {
                runCleanup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unloads the LaunchAgent and removes the installed Tron.app plus plist. Auth, settings, sessions, and database files are preserved.")
        }
    }

    private var installIsComplete: Bool {
        if state.installOutcome == .success || state.installOutcome == .alreadyInstalled {
            return true
        }
        return currentInstallRunSucceeded
    }

    private var currentInstallRunSucceeded: Bool {
        InstallPipelineStage.allCases.allSatisfy { stage in
            stages[stage] == .succeeded
        }
    }

    private var shouldUseDetectedInstallLayout: Bool {
        state.installOutcome == .alreadyInstalled
    }

    private func resetStagesToPending() {
        for stage in InstallPipelineStage.allCases {
            stages[stage] = .pending
        }
    }

    private func markAlreadyInstalledStagesSucceeded() {
        for stage in InstallPipelineStage.allCases {
            stages[stage] = .succeeded
        }
    }

    private func prepareAlreadyInstalledStateIfNeeded() {
        if case .installed = state.existingInstallStatus, state.installOutcome == nil {
            stages.removeAll()
            state.installOutcome = .alreadyInstalled
        }
    }

    private func prepareTerminalInstallStateIfNeeded() {
        switch state.installOutcome {
        case .success:
            markAlreadyInstalledStagesSucceeded()
        case .alreadyInstalled:
            stages.removeAll()
        case nil:
            if stages.isEmpty {
                resetStagesToPending()
            }
        default:
            break
        }
    }

    private func stageState(for stage: InstallPipelineStage) -> StageState {
        if let explicitState = stages[stage] {
            return explicitState
        }
        switch state.installOutcome {
        case .success:
            // Re-entering this page after a successful install should
            // render completed rows on the first body pass. Updating
            // them later from `.task` makes the icons pop separately
            // from the page transition.
            return .succeeded
        default:
            return .pending
        }
    }

    private var visibleStages: [InstallPipelineStage] {
        if state.installOutcome == .success {
            return InstallPipelineStage.allCases
        }
        return InstallPipelineStage.allCases.filter { stage in
            stageState(for: stage) != .pending
        }
    }

    private var stageProgressArea: some View {
        Group {
            if visibleStages.isEmpty {
                Text(InstallStepContent.notStartedPlaceholder)
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            } else {
                VStack(spacing: installIsComplete ? InstallStepLayout.completedStageSpacing : InstallStepLayout.runningStageSpacing) {
                    ForEach(visibleStages, id: \.self) { stage in
                        stageRow(stage)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .animation(WizardLayout.transitionAnimation, value: visibleStages)
    }

    private func runPipeline(requestID: Int) async {
        guard !state.installIsRunning else { return }
        guard state.hasUnhandledInstallRequest else {
            prepareTerminalInstallStateIfNeeded()
            return
        }
        state.markInstallRequestHandled(requestID)
        if case .installed = state.existingInstallStatus {
            prepareAlreadyInstalledStateIfNeeded()
            return
        }

        state.installIsRunning = true
        defer { state.installIsRunning = false }
        // Reset state.
        resetStagesToPending()
        stages[.copyBinary] = .running
        state.installOutcome = nil

        // 1. Locate the bundled binary.
        guard let bundled = Bundle.main.url(forResource: "tron-agent", withExtension: nil) else {
            state.installOutcome = .sourceBinaryMissing
            stages[.copyBinary] = .failed("Bundled binary not found")
            return
        }

        let plan: InstallPlan
        let plannerResult = InstallPlanner.plan(
            sourceBinary: bundled,
            paths: InstallPlanner.TargetPaths(
                targetBundle: setup.installedBundle,
                targetBinary: setup.installedBinary,
                plistPath: setup.launchAgentPlistPath,
                label: TronPaths.launchAgentLabel,
                port: setup.serverPort,
                tronHome: setup.tronHome,
                homeDir: TronPaths.homeDirectory,
                repoRoot: nil
            ),
            existingInstall: state.existingInstallStatus
        )
        switch plannerResult {
        case .failure(.sourceBinaryMissing):
            state.installOutcome = .sourceBinaryMissing
            stages[.copyBinary] = .failed("Bundled binary missing")
            return
        case .failure(.targetParentNotWritable(let url)):
            state.installOutcome = .copyFailed("Cannot write to \(url.path)")
            stages[.copyBinary] = .failed("Target directory not writable")
            return
        case .success(let value):
            plan = InstallPlan(
                sourceBinary: value.sourceBinary,
                iconSource: Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                targetBundle: value.targetBundle,
                targetBinary: value.targetBinary,
                plistPath: value.plistPath,
                plistContents: value.plistContents,
                requiresLoad: value.requiresLoad
            )
        }

        // 2. Prepare app bundle: copy binary, write Info.plist/resources,
        // strip quarantine, and ad-hoc sign the assembled bundle so macOS
        // TCC binds grants to `com.tron.server`.
        await paceStage()
        do {
            try BinaryInstaller.install(plan: plan)
            stages[.copyBinary] = .succeeded
        } catch {
            stages[.copyBinary] = .failed(error.localizedDescription)
            state.installOutcome = .copyFailed(error.localizedDescription)
            return
        }

        // 3. Write plist.
        stages[.writePlist] = .running
        await paceStage()
        do {
            try BinaryInstaller.writePlist(plan: plan)
            stages[.writePlist] = .succeeded
        } catch {
            stages[.writePlist] = .failed(error.localizedDescription)
            state.installOutcome = .plistWriteFailed(error.localizedDescription)
            return
        }

        // 4. Load agent.
        stages[.loadAgent] = .running
        await paceStage()
        if plan.requiresLoad {
            let outcome = await InstallLaunchAgentRunner.ensureLoaded(
                manager: setup.launchAgentManager,
                plistPath: plan.plistPath,
                label: TronPaths.launchAgentLabel
            )
            switch outcome {
            case .ok, .alreadyLoaded:
                stages[.loadAgent] = .succeeded
            case .launchdRefused(let message), .unknown(let message):
                stages[.loadAgent] = .failed(message)
                state.installOutcome = .launchctlFailed(message)
                return
            case .binaryMissing(let path):
                stages[.loadAgent] = .failed("Binary missing: \(path)")
                state.installOutcome = .launchctlFailed("Binary missing: \(path)")
                return
            }
        } else {
            stages[.loadAgent] = .succeeded
        }

        // 5. Await ping.
        stages[.awaitPing] = .running
        await paceStage()
        let pingOK = await waitForPing()
        if pingOK {
            withAnimation(WizardLayout.transitionAnimation) {
                stages[.awaitPing] = .succeeded
                state.installOutcome = .success
            }
            state.existingInstallStatus = setup.detectExistingInstall()
        } else {
            stages[.awaitPing] = .failed("Server did not respond within 30 seconds")
            state.installOutcome = .awaitPingTimedOut
        }
    }

    @ViewBuilder
    private func stageRow(_ stage: InstallPipelineStage) -> some View {
        let stateForStage = stageState(for: stage)
        HStack(alignment: .center, spacing: 12) {
            stageIcon(stateForStage)
                .frame(
                    width: InstallStepLayout.stageIconColumnWidth,
                    height: InstallStepLayout.stageRowMinHeight,
                    alignment: .center
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: stage))
                    .font(TronTypography.wizardBody)
                if case .failed(let message) = stateForStage {
                    Text(message).font(TronTypography.wizardCaption).foregroundStyle(.red)
                }
            }
            .frame(minHeight: InstallStepLayout.stageRowMinHeight, alignment: .center)
            Spacer()
        }
    }

    @ViewBuilder
    private func stageIcon(_ stateForStage: StageState) -> some View {
        switch stateForStage {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: InstallStepLayout.stageIconGlyphSize, weight: .regular))
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: InstallStepLayout.stageIconGlyphSize, weight: .semibold))
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: InstallStepLayout.stageIconGlyphSize, weight: .semibold))
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func paceStage() async {
        try? await Task.sleep(nanoseconds: InstallStepContent.stagePaceDelayNanoseconds)
    }

    enum StageState: Equatable {
        case pending, running, succeeded, failed(String)
    }

    private func label(for stage: InstallPipelineStage) -> String {
        InstallStepContent.label(for: stage)
    }

    private func outcomeDescription(_ outcome: InstallOutcome) -> String {
        switch outcome {
        case .success, .alreadyInstalled: return ""
        case .sourceBinaryMissing: return "Bundled tron-agent binary is missing — please reinstall the DMG."
        case .copyFailed(let message): return "Could not copy the server binary: \(message)"
        case .plistWriteFailed(let message): return "Could not write the LaunchAgent plist: \(message)"
        case .launchctlFailed(let message): return "launchctl rejected the agent: \(message)"
        case .awaitPingTimedOut: return "The server did not respond in time. Run `tron logs` to inspect recent server output."
        }
    }

    private enum CleanupVariant {
        case retry
        case freshStart

        var title: String {
            switch self {
            case .retry: return "Clean up and retry"
            case .freshStart: return "Need a fresh start?"
            }
        }

        var body: String {
            switch self {
            case .retry:
                return "Remove only the app bundle and LaunchAgent; keep auth, settings, and database files."
            case .freshStart:
                return "Keep auth and settings; remove app and LaunchAgent."
            }
        }
    }

    @ViewBuilder
    private var detectedInstallSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            installedSummaryCards
                .padding(.top, InstallStepLayout.detectedSummaryTopPadding)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var installedSummary: some View {
        installedSummaryCards
            .padding(.top, InstallStepLayout.installedSummaryTopPadding)
            .transition(InstallStepLayout.installedSummaryTransition)
    }

    @ViewBuilder
    private var installedSummaryCards: some View {
        VStack(alignment: .leading, spacing: InstallStepLayout.installedSummarySpacing) {
            installCompleteBanner
            installCleanupCard
        }
    }

    @ViewBuilder
    private var installCleanupCard: some View {
        WizardInfoCard(verticalPadding: InstallStepLayout.cleanupCardVerticalPadding) {
            cleanupControls(.freshStart)
        }
    }

    @ViewBuilder
    private func cleanupControls(_ variant: CleanupVariant) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.title)
                    .font(TronTypography.wizardSubheadline)
                Text(variant.body)
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            switch variant {
            case .retry:
                Button {
                    showCleanupConfirmation = true
                } label: {
                    Label(cleanupIsRunning ? "Cleaning..." : "Clean up", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(cleanupIsRunning)
            case .freshStart:
                Button {
                    showCleanupConfirmation = true
                } label: {
                    Image(systemName: cleanupIsRunning ? "hourglass" : "trash.fill")
                }
                .buttonStyle(.wizardTertiary)
                .help(cleanupIsRunning ? "Cleaning up install artifacts" : "Clean up install artifacts")
                .accessibilityLabel(cleanupIsRunning ? "Cleaning up install artifacts" : "Clean up install artifacts")
                .disabled(cleanupIsRunning)
            }
        }

    }

    @ViewBuilder
    private var cleanupFeedback: some View {
        if let cleanupError {
            Text(cleanupError)
                .font(TronTypography.wizardCaption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runCleanup() {
        guard !cleanupIsRunning else { return }
        cleanupIsRunning = true
        cleanupError = nil

        Task {
            let outcome = await setup.cleanupInstallArtifacts()
            await MainActor.run {
                cleanupIsRunning = false
                switch outcome {
                case .success:
                    state.existingInstallStatus = setup.detectExistingInstall()
                    state.resetInstallRunState()
                    resetStagesToPending()
                    installStatusText = nil
                case .failed:
                    cleanupError = outcome.userMessage
                }
            }
        }
    }

    /// Polls `system.ping` for up to 30 s on a 1 s cadence. Returns true
    /// the moment the server responds. Treats `.unauthorized` as a
    /// success signal too — the server is alive; the wizard moves on
    /// and the pairing step will surface the token.
    private func waitForPing() async -> Bool {
        for _ in 0..<30 {
            let token = setup.readBearerToken()
            switch await setup.pingServer(token) {
            case .success, .unauthorized:
                return true
            case .unreachable, .timeout, .malformedResponse:
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    @ViewBuilder
    private var installCompleteBanner: some View {
        HStack(alignment: .center, spacing: WizardCardLayout.iconTextSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.tronSuccess)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: WizardCardLayout.iconColumnWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tron is installed")
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(Color.tronEmerald)
                Text("Current status: \(installStatusText ?? "Checking...")")
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, InstallStepLayout.installCompleteBannerVerticalPadding)
        .padding(.horizontal, WizardCardLayout.horizontalInset)
        .wizardGlassCard()
    }

    private func refreshInstallStatus() async {
        installStatusText = "Checking..."
        let token = setup.readBearerToken()
        switch await setup.pingServer(token) {
        case .success(let info):
            installStatusText = "Running on port \(info.port)"
        case .unauthorized:
            installStatusText = "Running; token needs refresh"
        case .unreachable:
            installStatusText = "Not reachable"
        case .timeout:
            installStatusText = "Timed out"
        case .malformedResponse:
            installStatusText = "Unexpected response"
        }
    }
}

enum InstallStepContent {
    static let intro = "Install Tron Server on this Mac. It runs quietly in the background so your iPhone can connect."
    static let notStartedPlaceholder = "Installation not started"
    static let stagePaceDelayNanoseconds: UInt64 = 350_000_000

    static func label(for stage: InstallPipelineStage) -> String {
        switch stage {
        case .copyBinary: return "Prepare server"
        case .writePlist: return "Add startup item"
        case .loadAgent: return "Start server"
        case .awaitPing: return "Confirm it's running"
        }
    }
}

enum InstallStepLayout {
    static let sectionSpacing: CGFloat = 16
    static let runningStageSpacing: CGFloat = 6
    static let completedStageSpacing: CGFloat = 4
    static let installedSummarySpacing: CGFloat = 11
    static let installedSummaryTopPadding: CGFloat = 0
    static let detectedSummaryTopPadding: CGFloat = 72
    static let installCompleteBannerVerticalPadding: CGFloat = 14
    static let cleanupCardVerticalPadding: CGFloat = 12
    static let stageIconColumnWidth: CGFloat = 24
    static let stageRowMinHeight: CGFloat = 24
    static let stageIconGlyphSize: CGFloat = 13

    static var installedSummaryTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .move(edge: .bottom))
                .combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity
        )
    }
}

/// Applies the launchd step after the plist has been written. A loaded
/// label is not enough during install: launchd may still be running an
/// older process image, so `.alreadyLoaded` is followed by `kickstart -k`.
enum InstallLaunchAgentRunner {
    static func ensureLoaded(
        manager: LaunchAgentManaging,
        plistPath: URL,
        label: String
    ) async -> LaunchAgentOutcome {
        let loadOutcome = await manager.load(plistPath: plistPath, label: label)
        guard case .alreadyLoaded = loadOutcome else {
            return loadOutcome
        }
        return await manager.restart(label: label)
    }
}

/// Pure side-effect runner for the install plan. Lives outside the
/// View so it can be invoked from a test fixture (or a background
/// CLI) without SwiftUI in scope.
enum BinaryInstaller {
    enum Failure: Error, LocalizedError, Equatable {
        case copyFailed(String)
        case signFailed(String)
        case plistWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let s): return "copy failed: \(s)"
            case .signFailed(let s): return "sign failed: \(s)"
            case .plistWriteFailed(let s): return "plist write failed: \(s)"
            }
        }
    }

    /// Copies the bundled binary into `plan.targetBinary`. Atomic via
    /// tempfile + rename, preserves permissions, idempotent.
    static func install(plan: InstallPlan, signer: AppBundleSigner = .live) throws {
        let fm = FileManager.default
        let bundleContents = plan.targetBundle.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = bundleContents.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesDir = bundleContents.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }

        // Write a minimal Info.plist for the inner Tron Server.app so TCC
        // identifies the binary by bundle ID, not raw path. The display
        // name is deliberately "Tron Server" (not "Tron") so the three
        // permission panes in System Settings can distinguish the agent
        // from the menu-bar wrapper — which the user already knows as
        // "Tron" — without forcing them to read bundle IDs.
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "tron",
            "CFBundleIdentifier": TronPaths.bundleID,
            "CFBundleName": TronPaths.agentDisplayName,
            "CFBundleDisplayName": TronPaths.agentDisplayName,
            "CFBundleIconFile": "AppIcon.icns",
            "CFBundleIconName": "AppIcon",
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": "11.0",
            "LSUIElement": true,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            try data.write(to: bundleContents.appendingPathComponent("Info.plist", isDirectory: false), options: [.atomic])
        } catch {
            throw Failure.copyFailed("Info.plist: \(error.localizedDescription)")
        }

        if let iconSource = plan.iconSource {
            let iconTarget = resourcesDir.appendingPathComponent("AppIcon.icns", isDirectory: false)
            let iconTmp = resourcesDir.appendingPathComponent("AppIcon.tmp.\(UUID().uuidString).icns")
            do {
                if fm.fileExists(atPath: iconTmp.path) {
                    try fm.removeItem(at: iconTmp)
                }
                try fm.copyItem(at: iconSource, to: iconTmp)
                if fm.fileExists(atPath: iconTarget.path) {
                    _ = try fm.replaceItemAt(iconTarget, withItemAt: iconTmp)
                } else {
                    try fm.moveItem(at: iconTmp, to: iconTarget)
                }
            } catch {
                try? fm.removeItem(at: iconTmp)
                throw Failure.copyFailed("AppIcon.icns: \(error.localizedDescription)")
            }
        }

        let tmp = plan.targetBinary.deletingLastPathComponent().appendingPathComponent("tron.tmp.\(UUID().uuidString)")
        do {
            if fm.fileExists(atPath: tmp.path) {
                try fm.removeItem(at: tmp)
            }
            try fm.copyItem(at: plan.sourceBinary, to: tmp)
            // Mark executable.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            // Strip any quarantine xattr the copy inherited from the
            // source (DMG mount, dev build copied via AirDrop, etc.).
            // Without this, Gatekeeper refuses to exec the binary at
            // launchctl bootstrap time. Best-effort — ENOATTR ("no
            // such attribute") is normal and ignored.
            clearQuarantine(at: tmp)

            if fm.fileExists(atPath: plan.targetBinary.path) {
                _ = try fm.replaceItemAt(plan.targetBinary, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: plan.targetBinary)
            }
            // After the atomic rename, the destination inode is the
            // one we cleaned. Clean again as defence-in-depth in case
            // replaceItemAt resurrected the destination's old xattrs.
            clearQuarantine(at: plan.targetBinary)
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure.copyFailed(error.localizedDescription)
        }

        do {
            try signer.sign(plan.targetBundle)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.signFailed(error.localizedDescription)
        }
    }

    /// Removes the `com.apple.quarantine` extended attribute from
    /// `path`. Internal so tests can verify the call.
    static func clearQuarantine(at path: URL) {
        _ = path.path.withCString { cPath in
            Darwin.removexattr(cPath, "com.apple.quarantine", 0)
        }
    }

    static func writePlist(plan: InstallPlan) throws {
        let fm = FileManager.default
        let parent = plan.plistPath.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw Failure.plistWriteFailed(error.localizedDescription)
            }
        }
        do {
            try plan.plistContents.data(using: .utf8)?.write(to: plan.plistPath, options: [.atomic])
        } catch {
            throw Failure.plistWriteFailed(error.localizedDescription)
        }
    }
}

/// Signs the assembled inner server app bundle. Accessibility TCC is
/// particularly strict: it will flip an enabled toggle back off when the
/// bundle's effective code identity is just the raw executable's linker
/// signature instead of the app bundle's `CFBundleIdentifier`.
struct AppBundleSigner: Sendable {
    private var signBundle: @Sendable (URL) throws -> Void

    init(_ signBundle: @escaping @Sendable (URL) throws -> Void) {
        self.signBundle = signBundle
    }

    func sign(_ bundle: URL) throws {
        try signBundle(bundle)
    }

    static let live = AppBundleSigner { bundle in
        try CodesignAppBundleSigner.sign(bundle: bundle)
    }

    static let noop = AppBundleSigner { _ in }
}

enum CodesignAppBundleSigner {
    static func sign(bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            bundle.path,
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw BinaryInstaller.Failure.signFailed("codesign could not start: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BinaryInstaller.Failure.signFailed(message?.isEmpty == false ? message! : "codesign exited \(process.terminationStatus)")
        }
    }
}
