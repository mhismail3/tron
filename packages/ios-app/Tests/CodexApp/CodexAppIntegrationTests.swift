import Foundation
import Testing
@testable import TronMobile

@Suite("Codex App integration")
@MainActor
struct CodexAppIntegrationTests {
    private func clearPairings() {
        UserDefaults.standard.removeObject(forKey: PairedServerStore.serversKey)
        UserDefaults.standard.removeObject(forKey: PairedServerStore.activeIdKey)
    }

    private func server(id: String = "codex-integration-server") -> PairedServer {
        PairedServer(id: id, label: "Studio", host: "100.64.0.10", port: 9847)
    }

    @Test("Codex appears as a separate top-level navigation mode")
    func navigationModeIncludesCodex() {
        #expect(NavigationMode.allCases.contains(.codex))
        #expect(NavigationMode.codex.rawValue == "Codex")
        #expect(NavigationMode.codex.icon == "terminal")
    }

    @Test("failed managed Codex status stays in the dashboard flow")
    func failedManagedStatusStaysInDashboardFlow() {
        let failedStatus = CodexAppServerStatusResult(
            state: "failed",
            endpoint: nil,
            listenUrl: "ws://0.0.0.0:4500",
            pid: nil,
            lastError: "managed Codex App Server exited during startup"
        )

        #expect(CodexAppModePresentation.content(
            activeServer: server(),
            serverStatus: failedStatus,
            activeEndpoint: nil
        ) == .dashboard)
    }

    @Test("Codex setup flow is only for missing paired server")
    func setupFlowIsOnlyForMissingPairedServer() {
        #expect(CodexAppModePresentation.content(
            activeServer: nil,
            serverStatus: nil,
            activeEndpoint: nil
        ) == .noActiveServerSetup)
    }

    @Test("configuring Codex mode does not recreate the Tron RPC client")
    func codexConfigureDoesNotTouchTronRPC() {
        clearPairings()
        let server = server()
        let container = DependencyContainer()
        container.replacePairedServers([server], activeServer: server)
        let rpcClient = container.rpcClient

        container.codexAppViewModel.configure(activeServer: server)

        #expect(container.rpcClient === rpcClient)
    }

    @Test("forgetting a paired server clears Codex mode without local Codex secrets")
    func forgetServerClearsCodexModeWithoutLocalSecrets() async throws {
        clearPairings()
        let server = server(id: "codex-forget-\(UUID().uuidString)")
        let container = DependencyContainer()
        container.replacePairedServers([server], activeServer: server)
        container.codexAppViewModel.configure(activeServer: server, serverStatusProvider: {
            CodexAppServerStatusResult(
                endpoint: .init(port: 4500, bearerToken: "server-owned-token"),
                listenUrl: "ws://0.0.0.0:4500"
            )
        })
        try await Task.sleep(for: .milliseconds(25))

        _ = container.forgetPairedServer(server)

        #expect(container.codexAppViewModel.activeEndpoint == nil)
        #expect(container.codexAppViewModel.serverStatus == nil)
        clearPairings()
    }
}
