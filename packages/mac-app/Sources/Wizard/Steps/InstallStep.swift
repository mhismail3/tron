import SwiftUI

struct InstallStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var stages: [InstallPipelineStage: StageState] = [:]
    @State private var running = false
    @State private var startedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Install the Tron server")
                .font(.largeTitle.bold())
            Text("Copies the Tron agent binary into ~/.tron/system/Tron.app, drops a LaunchAgent so the server starts at login, and waits for the first heartbeat.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(InstallPipelineStage.allCases, id: \.self) { stage in
                    stageRow(stage)
                }
            }

            if let outcome = state.installOutcome, outcome != .success, outcome != .alreadyInstalled {
                GroupBox {
                    Text(outcomeDescription(outcome))
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }

            HStack {
                if state.installOutcome != .success && state.installOutcome != .alreadyInstalled {
                    Button {
                        Task { await runPipeline() }
                    } label: {
                        Label("Retry install", systemImage: "arrow.clockwise")
                    }
                    .disabled(running)
                    .controlSize(.large)
                }
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
                .disabled(state.installOutcome == nil || running ||
                          (state.installOutcome != .success && state.installOutcome != .alreadyInstalled))
            }
        }
        .task {
            // Auto-skip if we know an existing install is fully present.
            if case .installed = state.existingInstallStatus, !startedOnce {
                state.installOutcome = .alreadyInstalled
                startedOnce = true
                return
            }
            if !startedOnce {
                startedOnce = true
                await runPipeline()
            }
        }
    }

    @ViewBuilder
    private func stageRow(_ stage: InstallPipelineStage) -> some View {
        let stateForStage = stages[stage] ?? .pending
        HStack(spacing: 12) {
            Group {
                switch stateForStage {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                case .running:
                    ProgressView().controlSize(.small)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        .help(message)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: stage))
                    .font(.body)
                if case .failed(let message) = stateForStage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
        }
    }

    enum StageState: Equatable {
        case pending, running, succeeded, failed(String)
    }

    private func label(for stage: InstallPipelineStage) -> String {
        switch stage {
        case .copyBinary: return "Copy server binary"
        case .writePlist: return "Write LaunchAgent plist"
        case .loadAgent: return "Load LaunchAgent"
        case .awaitPing: return "Wait for first heartbeat"
        }
    }

    private func outcomeDescription(_ outcome: InstallOutcome) -> String {
        switch outcome {
        case .success, .alreadyInstalled: return ""
        case .sourceBinaryMissing: return "Bundled tron-agent binary is missing — please reinstall the DMG."
        case .copyFailed(let message): return "Could not copy the server binary: \(message)"
        case .plistWriteFailed(let message): return "Could not write the LaunchAgent plist: \(message)"
        case .launchctlFailed(let message): return "launchctl rejected the agent: \(message)"
        case .awaitPingTimedOut: return "The server did not respond in time. Check Console.app or run `tron logs`."
        }
    }

    private func runPipeline() async {
        guard !running else { return }
        running = true
        defer { running = false }
        // Reset state.
        for stage in InstallPipelineStage.allCases {
            stages[stage] = .pending
        }
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
            plan = value
        }

        // 2. Copy binary.
        stages[.copyBinary] = .running
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
        if plan.requiresLoad {
            let outcome = await setup.launchAgentManager.load(plistPath: plan.plistPath, label: TronPaths.launchAgentLabel)
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
        let pingOK = await waitForPing()
        if pingOK {
            stages[.awaitPing] = .succeeded
            state.installOutcome = .success
        } else {
            stages[.awaitPing] = .failed("Server did not respond within 30 seconds")
            state.installOutcome = .awaitPingTimedOut
        }
    }

    /// Polls `system.ping` for up to 30 s on a 1 s cadence. Returns true
    /// the moment the server responds.
    private func waitForPing() async -> Bool {
        let token = setup.readBearerToken()
        for _ in 0..<30 {
            if let _ = await setup.pingServer(token) {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}

/// Pure side-effect runner for the install plan. Lives outside the
/// View so it can be invoked from a test fixture (or a background
/// CLI) without SwiftUI in scope.
enum BinaryInstaller {
    enum Failure: Error, LocalizedError, Equatable {
        case copyFailed(String)
        case plistWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let s): return "copy failed: \(s)"
            case .plistWriteFailed(let s): return "plist write failed: \(s)"
            }
        }
    }

    /// Copies the bundled binary into `plan.targetBinary`. Atomic via
    /// tempfile + rename, preserves permissions, idempotent.
    static func install(plan: InstallPlan) throws {
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

        // Write a minimal Info.plist for the inner Tron.app so TCC
        // identifies the binary by bundle ID, not raw path.
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "tron",
            "CFBundleIdentifier": TronPaths.bundleID,
            "CFBundleName": "Tron",
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            try data.write(to: bundleContents.appendingPathComponent("Info.plist", isDirectory: false), options: [.atomic])
        } catch {
            throw Failure.copyFailed("Info.plist: \(error.localizedDescription)")
        }

        let tmp = plan.targetBinary.deletingLastPathComponent().appendingPathComponent("tron.tmp.\(UUID().uuidString)")
        do {
            if fm.fileExists(atPath: tmp.path) {
                try fm.removeItem(at: tmp)
            }
            try fm.copyItem(at: plan.sourceBinary, to: tmp)
            // Mark executable.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)

            if fm.fileExists(atPath: plan.targetBinary.path) {
                _ = try fm.replaceItemAt(plan.targetBinary, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: plan.targetBinary)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure.copyFailed(error.localizedDescription)
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
