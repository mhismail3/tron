import Foundation

/// Immutable I/O ownership selected once at the composition boundary.
struct DependencyContainerRuntimeIO {
    let sessionAttemptDirective: (URLRequest) -> EngineSessionAttemptDirective
    let pairedServerTokenStore: PairedServerTokenStore
    let makePairingProbe: @MainActor () -> any PairingProbing

    static func production() -> Self {
        Self(
            sessionAttemptDirective: { _ in .openLiveSession },
            pairedServerTokenStore: PairedServerTokenStore(),
            makePairingProbe: { URLSessionPairingProbe() }
        )
    }
}

extension DependencyContainer {

    var chatSessionServices: ChatSessionServices {
        ChatSessionServices(
            connection: connectionRepository,
            events: sessionEventRepository,
            sessions: sessionRepository,
            agent: agentRepository,
            models: modelRepository,
            messages: messageRepository,
            workerKernel: workerKernelRepository
        )
    }

    // MARK: - Application Connection Lifecycle

    /// Set background state for battery optimization
    func setBackgroundState(_ inBackground: Bool) {
        engineClient.setBackgroundState(inBackground)
    }

    /// Resume the one shared engine transport and let every projection observe
    /// the resulting continuity generation.
    func resumeConnectionFromBackground() async {
        guard pairedServerStore.activeServer != nil else { return }
        await engineClient.resumeFromBackground()
    }

    /// Verify connection is alive
    func verifyConnection() async -> Bool {
        guard pairedServerStore.activeServer != nil else { return false }
        return await engineClient.verifyConnection()
    }

    /// Manual retry triggered from UI
    func manualRetry() async {
        guard pairedServerStore.activeServer != nil else { return }
        await engineClient.manualRetry()
    }
}
