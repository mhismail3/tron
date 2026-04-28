import Foundation
import Testing
@testable import TronMobile

/// `OnboardingState` is the observable model behind the first-run
/// pairing sheet. It owns only the pairing form, the completion flag,
/// inline pairing errors, and the in-flight Connect lock.
@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    // MARK: - Defaults

    @Test("Fresh state defaults to empty pairing inputs")
    func defaultsAreSensible() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        #expect(state.currentStep == .welcome)
        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(state.hasPairedMac == false)
        #expect(state.isConnecting == false)
        #expect(state.pairingError == nil)
    }

    @Test("Step order matches the sheet flow")
    func stepOrderMatchesSheetFlow() {
        #expect(OnboardingState.Step.allCases == [
            .welcome,
            .installTailscale,
            .installMac,
            .connect,
            .workspace,
            .anthropic,
            .openAI,
            .providers,
            .services,
            .model,
        ])
    }

    @Test("Step toolbar metadata matches the sheet flow")
    func stepToolbarMetadataMatchesFlow() {
        #expect(OnboardingState.Step.welcome.toolbarTitle == "Welcome to Tron")
        #expect(OnboardingState.Step.installTailscale.toolbarTitle == "Install Tailscale")
        #expect(OnboardingState.Step.installMac.toolbarTitle == "Install Tron Server")
        #expect(OnboardingState.Step.connect.toolbarTitle == "Connect your Mac")
        #expect(OnboardingState.Step.workspace.toolbarTitle == "Default workspace")
        #expect(OnboardingState.Step.anthropic.toolbarTitle == "Anthropic")
        #expect(OnboardingState.Step.openAI.toolbarTitle == "OpenAI")
        #expect(OnboardingState.Step.providers.toolbarTitle == "Other providers")
        #expect(OnboardingState.Step.services.toolbarTitle == "Search services")
        #expect(OnboardingState.Step.model.toolbarTitle == "Default model")
    }

    @Test("complete() flips the AppStorage flag")
    func completeFlipsFlag() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.complete()
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == true)
    }

    // MARK: - Pairing payload application

    @Test("acceptPairingPayload(_:) populates host/port/token from a parsed URL")
    func acceptPairingPayload() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.7",
            port: 9847,
            token: "deadbeef",
            label: "Friend's Mac"
        )
        state.acceptPairingPayload(payload)
        #expect(state.currentStep == .connect)
        #expect(state.pairingHost == "100.64.0.7")
        #expect(state.pairingPort == "9847")
        #expect(state.pairingToken == "deadbeef")
        // Optional server name only overrides if user hasn't typed something.
        #expect(state.pairingLabel == "Friend's Mac")
    }

    @Test("acceptPairingPayload preserves user's label if already typed")
    func acceptPairingPayloadPreservesLabel() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        state.pairingLabel = "Custom Name"
        let payload = PairingURLParser.PairingPayload(
            host: "h", port: 1, token: "t", label: "From QR"
        )
        state.acceptPairingPayload(payload)
        // The user's prior label wins.
        #expect(state.pairingLabel == "Custom Name")
    }

    @Test("acceptPairingPayload clears any inline pairing error")
    func acceptPayloadClearsError() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        state.pairingError = .unauthorized
        state.acceptPairingPayload(.init(host: "h", port: 1, token: "t", label: nil))
        #expect(state.pairingError == nil)
    }

    @Test("acceptPairingPayload starts a fresh setup hydration scope")
    func acceptPairingPayloadStartsFreshSetupScope() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"server":{"defaultWorkspace":"/stale"}}"#.utf8))
        state.hasPairedMac = true
        state.hydrateSetup(serverId: "old-server", settings: settings, authState: nil)

        state.acceptPairingPayload(.init(host: "new-host", port: 9847, token: "new-token", label: "New Mac"))

        #expect(state.hasPairedMac == false)
        #expect(state.setupSnapshot.serverId == nil)
        #expect(state.setupSnapshot.defaultWorkspace == AppConstants.defaultWorkspace)
    }

    // MARK: - reset()

    @Test("reset() clears completion flag and pairing inputs")
    func resetReturnsToPairing() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.currentStep = .connect
        state.pairingHost = "h"
        state.pairingPort = "1"
        state.pairingToken = "t"
        state.pairingLabel = "L"
        state.hasPairedMac = true
        defaults.set(true, forKey: OnboardingState.completionStorageKey)

        state.reset()

        #expect(state.currentStep == .welcome)
        #expect(state.hasPairedMac == false)
        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == false)
    }

    // MARK: - setup hydration

    @Test("setup snapshot exposes existing server preferences and masked credentials")
    func setupSnapshotHydratesExistingServerState() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data("""
        {
          "server": {
            "defaultWorkspace": "/Users/example/project",
            "defaultModel": "claude-opus-4-6"
          },
          "memory": {
            "retainModel": "claude-haiku-4-5-20251001"
          }
        }
        """.utf8))
        let auth = try JSONDecoder().decode(AuthState.self, from: Data("""
        {
          "providers": {
            "anthropic": {
              "hasApiKey": true,
              "apiKeys": [{"label": "work", "keyHint": "sk-ant-...xyz"}],
              "activeCredential": {"type": "apiKey", "label": "work"}
            },
            "openai-codex": {
              "hasOAuth": true,
              "accounts": [{"label": "personal", "expiresAt": 1800000000, "isExpired": false}]
            }
          },
          "services": {
            "brave": {"hasApiKey": true, "apiKeyHint": "BSA...abc"}
          }
        }
        """.utf8))

        var snapshot = OnboardingSetupSnapshot()
        snapshot.hydrate(serverId: "server-1", settings: settings, authState: auth)

        #expect(snapshot.serverId == "server-1")
        #expect(snapshot.defaultWorkspace == "/Users/example/project")
        #expect(snapshot.defaultModel == "claude-opus-4-6")
        #expect(snapshot.retainModel == "claude-haiku-4-5-20251001")
        #expect(snapshot.providerSummary(for: "anthropic")?.title == "API key already saved")
        #expect(snapshot.providerSummary(for: "anthropic")?.detail == "work - sk-ant-...xyz")
        #expect(snapshot.providerSummary(for: "openai-codex")?.title == "OAuth already connected")
        #expect(snapshot.providerSummary(for: "openai-codex")?.detail == "personal")
        #expect(snapshot.serviceSummary(for: "brave")?.detail == "BSA...abc")
        #expect(snapshot.preferredApiKeyLabel(for: "anthropic") == "work")
    }

    @Test("reset clears hydrated setup snapshot")
    func resetClearsSetupSnapshot() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"server":{"defaultWorkspace":"/tmp"}}"#.utf8))
        state.hydrateSetup(serverId: "server-1", settings: settings, authState: nil)

        state.reset()

        #expect(state.setupSnapshot.serverId == nil)
        #expect(state.setupSnapshot.defaultWorkspace == AppConstants.defaultWorkspace)
        #expect(state.setupSnapshot.defaultModel == "")
    }

    @Test("credential refresh updates setup snapshot without losing server preferences")
    func credentialRefreshUpdatesSetupSnapshot() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data("""
        {
          "server": {
            "defaultWorkspace": "/Users/example/project",
            "defaultModel": "claude-opus-4-6"
          }
        }
        """.utf8))
        let emptyAuth = try JSONDecoder().decode(AuthState.self, from: Data(#"{"providers":{},"services":{}}"#.utf8))
        let refreshedAuth = try JSONDecoder().decode(AuthState.self, from: Data("""
        {
          "providers": {
            "anthropic": {
              "hasOAuth": true,
              "accounts": [{"label": "work", "expiresAt": 1800000000, "isExpired": false}],
              "activeCredential": {"type": "oauth", "label": "work"}
            }
          },
          "services": {
            "exa": {"hasApiKey": true, "apiKeyHint": "exa...123"}
          }
        }
        """.utf8))

        state.hydrateSetup(
            serverId: "server-1",
            settings: settings,
            authState: emptyAuth,
            authLoadError: "temporary auth failure"
        )
        state.refreshSetupAuth(refreshedAuth)

        #expect(state.setupSnapshot.serverId == "server-1")
        #expect(state.setupSnapshot.defaultWorkspace == "/Users/example/project")
        #expect(state.setupSnapshot.defaultModel == "claude-opus-4-6")
        #expect(state.setupSnapshot.providerSummary(for: "anthropic")?.title == "OAuth already connected")
        #expect(state.setupSnapshot.providerSummary(for: "anthropic")?.detail == "work")
        #expect(state.setupSnapshot.serviceSummary(for: "exa")?.detail == "exa...123")
        #expect(state.setupSnapshot.authLoadError == nil)
    }

    // MARK: - Helpers

    /// Returns an isolated UserDefaults suite so tests don't leak state into
    /// the simulator's app domain or each other.
    private func ephemeralDefaults() -> UserDefaults {
        let suiteName = "test.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
