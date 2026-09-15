import Foundation

/// One user Quit owns acceptance, actual Gateway exit, native retirement, and
/// unregister in that order. A failed stage leaves the wrapper alive for retry.
@MainActor
final class MacQuitCoordinator {
    enum Failure: Error, LocalizedError {
        case unmanaged, registrationUpdateRequired, ownership, observation, replaced, abnormalExit, unregister(String)
        var errorDescription: String? {
            switch self {
            case .unmanaged: "This wrapper does not own the installed Gateway."
            case .registrationUpdateRequired: "Quit requires the current Gateway and LaunchAgent registration. Finish the Mac/Gateway update first."
            case .ownership: "Could not verify the Gateway owned by this app. No shutdown was requested."
            case .observation: "Could not confirm Gateway shutdown. Tron remains open; check its status before retrying Quit."
            case .replaced: "The Gateway changed while Quit was waiting. Tron has not assumed the replacement is stopped."
            case .abnormalExit: "The Gateway did not report a clean shutdown. Tron remains open."
            case .unregister(let message): "Services stopped, but Gateway unregister did not finish: \(message)"
            }
        }
    }
    static func shouldCoordinate(mode: MacStartupMode, ownsLock: Bool, canManage: Bool) -> Bool {
        ownsLock && canManage && (mode == .onboarded || mode == .wizard)
    }
    private struct Identity: Equatable { let pid: Int; let start: String; let runs: Int }
    private var attempt: (identity: Identity, commandID: String)?
    private var pending: Task<Void, Error>?
    private let setup: EnvironmentSetup
    private let wait: @Sendable () async throws -> Void
    init(setup: EnvironmentSetup, wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.setup = setup; self.wait = wait
    }
    func quit() async throws {
        if let pending { return try await pending.value }
        let task = Task { @MainActor [self] in try await perform() }
        pending = task
        do { try await task.value }
        catch { pending = nil; throw error }
    }
    private func perform() async throws {
        guard setup.canManageLaunchAgent else { throw Failure.unmanaged }
        var quitIdentity: Identity?
        let initial = try await setup.readGatewayForQuit()
        if let initial, initial.pid == nil {
            guard initial.lastExitCode == 0,
                  LiveLaunchAgentManager.registeredProfileOwnsProfile(
                      runtimeInfo: initial,
                      profile: setup.profile,
                      expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
                      expectedHelperPath: setup.serverHelperBinaryPath.path
                  ) else { throw Failure.ownership }
        }
        if let initial, let pid = initial.pid {
            guard initial.gatewayExitPolicy == "stop-on-success" else { throw Failure.registrationUpdateRequired }
            guard let start = initial.processStartIdentity, let runs = initial.launchCount,
                  await setup.runtimeOwnershipHealthy() else { throw Failure.ownership }
            let identity = Identity(pid: pid, start: start, runs: runs)
            quitIdentity = identity
            if attempt?.identity != identity { attempt = (identity, "mac-quit-\(UUID().uuidString.lowercased())") }
            // Retry uses the same command receipt only for this exact runtime.
            // A timeout/lost response is never interpreted as acceptance.
            let accepted = try await setup.shutdownGateway(attempt!.commandID)
            guard accepted.stopping else { throw Failure.observation }
            var incomplete = 0
            while true {
                guard let current = try await setup.readGatewayForQuit(),
                      current.launchCount == identity.runs,
                      current.gatewayExitPolicy == "stop-on-success" else { throw Failure.replaced }
                if current.pid == nil {
                    guard current.lastExitCode == 0 else { throw Failure.abnormalExit }
                    break
                }
                guard current.pid == identity.pid else { throw Failure.replaced }
                if let start = current.processStartIdentity {
                    guard start == identity.start else { throw Failure.replaced }
                    incomplete = 0
                } else {
                    incomplete += 1
                    guard incomplete < 3 else { throw Failure.observation }
                }
                try await wait()
            }
        }
        try await setup.suspendNativeHostForQuit()
        // Native retirement can await an arbitrary in-flight callback. A
        // successor may therefore have appeared after the clean Gateway exit;
        // prove the same stopped runtime immediately before unregistering it.
        try await verifyGatewayStillStopped(initial: initial, identity: quitIdentity)
        switch await setup.launchAgentManager.unload(label: setup.launchAgentLabel) {
        case .ok, .alreadyLoaded: break
        case .requiresApproval(let message), .launchdRefused(let message), .unknown(let message): throw Failure.unregister(message)
        case .binaryMissing(let path): throw Failure.unregister("Missing service binary: \(path)")
        }
        guard try await setup.readGatewayForQuit() == nil else { throw Failure.observation }
    }

    private func verifyGatewayStillStopped(initial: LaunchAgentRuntimeInfo?, identity: Identity?) async throws {
        let current = try await setup.readGatewayForQuit()
        guard let current else {
            // A missing service is safe only when it was already absent before
            // this quit attempt. A runtime observed as stopped must remain
            // observable until its registration is explicitly unloaded.
            guard initial == nil else { throw Failure.replaced }
            return
        }
        guard current.pid == nil,
              current.lastExitCode == 0,
              LiveLaunchAgentManager.registeredProfileOwnsProfile(
                  runtimeInfo: current,
                  profile: setup.profile,
                  expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
                  expectedHelperPath: setup.serverHelperBinaryPath.path
              ) else {
            if current.pid != nil { throw Failure.replaced }
            if current.lastExitCode != 0 { throw Failure.abnormalExit }
            throw Failure.ownership
        }
        if let identity {
            guard current.launchCount == identity.runs else { throw Failure.replaced }
        } else if let launchCount = initial?.launchCount {
            guard current.launchCount == launchCount else { throw Failure.replaced }
        }
    }
}
