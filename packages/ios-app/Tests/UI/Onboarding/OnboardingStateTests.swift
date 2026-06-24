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
        #expect(state.pairingPrefilledServerId == nil)
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

    @Test("Preparation page copy matches the sheet flow")
    func preparationPageCopyMatchesFlow() {
        #expect(OnboardingCopy.welcomeSubtitle == "Pair this iPhone with the Mac running Tron.")
        #expect(OnboardingCopy.welcomeRows.map(\.title) == [
            "Run Tron on Mac",
            "Use your private network",
            "Scan or paste the code",
        ])
        #expect(OnboardingCopy.welcomeRows.map(\.subtitle) == [
            "The server stays local to your machine",
            "Tailscale links this iPhone to the Mac",
            "The pairing token is stored in Keychain",
        ])

        #expect(OnboardingCopy.tailscaleSubtitle == "Use the same Tailscale account on this iPhone and the Mac.")
        #expect(OnboardingCopy.tailscaleRows.map(\.title) == [
            "Install Tailscale",
            "Sign in",
            "Return connected",
        ])
        #expect(OnboardingCopy.tailscaleRows.map(\.subtitle) == [
            "Open the App Store if it is not already installed",
            "Use the account connected to your Mac",
            "Tron verifies reachability before saving the pairing",
        ])

        #expect(OnboardingCopy.installMacSubtitle == "Install Tron on the Mac, then use the pairing screen shown by the Mac app.")
        #expect(OnboardingCopy.installMacCopyButtonTitle == "Copy Link")
        #expect(OnboardingCopy.installMacCopiedButtonTitle == "Copied")
        #expect(OnboardingCopy.installMacReleasesButtonTitle == "Open Releases page")
    }

    @Test("Page dots use compact low sheet metrics")
    func pageDotsUseCompactLowSheetMetrics() {
        #expect(OnboardingPageDotsMetrics.bottomPadding == 10)
        #expect(OnboardingPageDotsMetrics.spacing == 6)
        #expect(OnboardingPageDotsMetrics.activeWidth == 16)
        #expect(OnboardingPageDotsMetrics.inactiveWidth == 6)
        #expect(OnboardingPageDotsMetrics.dotHeight == 6)
        #expect(OnboardingPageDotsMetrics.horizontalPadding == 10)
        #expect(OnboardingPageDotsMetrics.verticalPadding == 6)
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
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/stale"}}"#))
        state.hasPairedMac = true
        state.hydrateSetup(serverId: "old-server", settings: ServerSettingsSnapshot(settings), authState: nil)

        state.acceptPairingPayload(.init(host: "new-host", port: 9847, token: "new-token", label: "New Mac"))

        #expect(state.hasPairedMac == false)
        #expect(state.setupSnapshot.serverId == nil)
        #expect(state.setupSnapshot.defaultWorkspace == AppConstants.defaultWorkspace)
    }

    @Test("prepareFirstRunOnboarding returns to the intro without changing form values")
    func prepareFirstRunOnboardingReturnsToIntro() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/stale"}}"#))
        state.prepareServerOnboarding(prefill: .init(id: "studio", label: "Studio", host: "100.64.0.7", port: 9847))
        state.pairingToken = "stored-token"
        state.currentStep = .model
        state.hasPairedMac = true
        state.isConnecting = true
        state.pairingError = .unauthorized
        state.hydrateSetup(serverId: "old-server", settings: ServerSettingsSnapshot(settings), authState: nil)

        state.prepareFirstRunOnboarding()

        #expect(state.currentStep == .welcome)
        #expect(state.hasPairedMac == false)
        #expect(state.pairingHost == "")
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken == "")
        #expect(state.pairingLabel == "My Mac")
        #expect(state.isConnecting == false)
        #expect(state.pairingError == nil)
        #expect(state.pairingPrefilledServerId == nil)
        #expect(state.completesAfterPairing == false)
        #expect(state.setupSnapshot.serverId == nil)
    }

    @Test("prepareServerOnboarding starts Settings-launched onboarding at connect")
    func prepareServerOnboardingStartsAtConnect() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/stale"}}"#))
        state.currentStep = .model
        state.hasPairedMac = true
        state.pairingHost = "stale.example.com"
        state.pairingPort = "1111"
        state.pairingToken = "stale-token"
        state.pairingLabel = "Stale"
        state.hydrateSetup(serverId: "old-server", settings: ServerSettingsSnapshot(settings), authState: nil)

        state.prepareServerOnboarding(prefill: nil)

        #expect(state.currentStep == .connect)
        #expect(state.hasPairedMac == false)
        #expect(state.pairingHost == "")
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken == "")
        #expect(state.pairingLabel == "My Mac")
        #expect(state.pairingPrefilledServerId == nil)
        #expect(state.canAttemptPairing == false)
        #expect(state.setupSnapshot.serverId == nil)
        #expect(state.setupSnapshot.defaultWorkspace == AppConstants.defaultWorkspace)
    }

    @Test("prepareServerOnboarding can prefill a paired server and reuse its stored token")
    func prepareServerOnboardingPrefillsExistingServer() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let server = PairedServer(
            id: "studio",
            label: "Studio",
            host: "100.64.0.7",
            port: 9847
        )

        state.prepareServerOnboarding(prefill: server)

        #expect(state.currentStep == .connect)
        #expect(state.pairingHost == "100.64.0.7")
        #expect(state.pairingPort == "9847")
        #expect(state.pairingToken == "")
        #expect(state.pairingLabel == "Studio")
        #expect(state.pairingPrefilledServerId == "studio")
        #expect(state.completesAfterPairing == true)
        #expect(state.canAttemptPairing == true)
        #expect(state.validatedPairingPayload == nil)
        #expect(state.validatedPairingPayload(storedToken: "stored-token")?.token == "stored-token")
    }

    @Test("fresh server onboarding stays blocked until a token is scanned or entered")
    func freshServerOnboardingRequiresToken() {
        let state = OnboardingState(defaults: ephemeralDefaults())

        state.prepareServerOnboarding(prefill: nil)
        state.pairingHost = "100.64.0.7"
        state.pairingPort = "9847"
        state.pairingLabel = "Studio"

        #expect(state.pairingPrefilledServerId == nil)
        #expect(state.completesAfterPairing == false)
        #expect(state.validatedPairingPayload(storedToken: "ignored-token") == nil)
        #expect(state.canAttemptPairing == false)

        state.pairingToken = "fresh-token"

        #expect(state.validatedPairingPayload?.token == "fresh-token")
        #expect(state.canAttemptPairing == true)
    }

    @Test("editing a prefilled server origin requires a fresh token")
    func editingPrefilledOriginRequiresFreshToken() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let server = PairedServer(
            id: "studio",
            label: "Studio",
            host: "studio.tailnet.ts.net",
            port: 9847
        )

        state.prepareServerOnboarding(prefill: server)
        state.pairingHost = "other.tailnet.ts.net"

        #expect(state.completesAfterPairing == true)
        #expect(state.canAttemptPairing == false)
        #expect(state.validatedPairingPayload(storedToken: "stored-token") == nil)

        state.pairingToken = "fresh-token"

        #expect(state.validatedPairingPayload?.host == "other.tailnet.ts.net")
        #expect(state.validatedPairingPayload?.token == "fresh-token")
        #expect(state.canAttemptPairing == true)

        state.beginPairingAttempt(for: state.validatedPairingPayload!)

        #expect(state.completesAfterPairing == false)
    }

    @Test("pairing attempt preserves Settings repair mode for retry")
    func pairingAttemptPreservesSettingsRepairModeForRetry() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let server = PairedServer(
            id: "studio",
            label: "Studio",
            host: "studio.tailnet.ts.net",
            port: 9847
        )

        state.prepareServerOnboarding(prefill: server)
        state.beginPairingAttempt(for: state.validatedPairingPayload(storedToken: "stored-token")!)

        #expect(state.currentStep == .connect)
        #expect(state.pairingPrefilledServerId == "studio")
        #expect(state.completesAfterPairing == true)
        #expect(state.canAttemptPairing == true)
    }

    @Test("scanned token for same prefilled server completes repair after pairing")
    func scannedTokenForSamePrefilledServerCompletesRepairAfterPairing() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let server = PairedServer(
            id: "studio",
            label: "Studio",
            host: "Studio.Tailnet.TS.Net",
            port: 9847
        )
        state.prepareServerOnboarding(prefill: server)

        state.acceptPairingPayload(.init(
            host: "studio.tailnet.ts.net",
            port: 9847,
            token: "fresh-token",
            label: "Studio"
        ))

        #expect(state.completesAfterPairing == true)
        #expect(state.validatedPairingPayload?.token == "fresh-token")
    }

    @Test("scanned token for different server keeps setup flow")
    func scannedTokenForDifferentServerKeepsSetupFlow() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let server = PairedServer(
            id: "studio",
            label: "Studio",
            host: "studio.tailnet.ts.net",
            port: 9847
        )
        state.prepareServerOnboarding(prefill: server)

        state.acceptPairingPayload(.init(
            host: "new.tailnet.ts.net",
            port: 9847,
            token: "fresh-token",
            label: "New"
        ))

        #expect(state.completesAfterPairing == false)
    }

    @Test("setup steps cannot be selected before a fresh pairing succeeds")
    func setupStepsStayLockedUntilPairingSucceeds() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        state.currentStep = .connect

        state.selectStep(.workspace)

        #expect(state.currentStep == .connect)

        state.hasPairedMac = true
        state.selectStep(.workspace)

        #expect(state.currentStep == .workspace)
    }

    @Test("explicit navigation advances through unlocked pages and stops at locked setup")
    func explicitNavigationHonorsSetupLock() {
        let state = OnboardingState(defaults: ephemeralDefaults())

        #expect(state.canNavigateBackward == false)
        #expect(state.canNavigateForward == true)

        state.goForward()
        #expect(state.currentStep == .installTailscale)
        #expect(state.canNavigateBackward == true)

        state.goForward()
        state.goForward()
        #expect(state.currentStep == .connect)
        #expect(state.canNavigateForward == false)

        state.goForward()
        #expect(state.currentStep == .connect)

        state.hasPairedMac = true
        #expect(state.canNavigateForward == true)

        state.goForward()
        #expect(state.currentStep == .workspace)

        state.goBack()
        #expect(state.currentStep == .connect)
    }

    @Test("explicit navigation reaches model only after pairing and never runs past the final step")
    func explicitNavigationStopsAtModel() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        state.hasPairedMac = true

        while state.canNavigateForward {
            state.goForward()
        }

        #expect(state.currentStep == .model)
        #expect(state.canNavigateForward == false)

        state.goForward()
        #expect(state.currentStep == .model)
    }

    @Test("pairing connect eligibility follows the current form values")
    func pairingConnectEligibilityFollowsFormValues() {
        let state = OnboardingState(defaults: ephemeralDefaults())

        #expect(state.validatedPairingPayload == nil)
        #expect(state.canAttemptPairing == false)

        state.pairingHost = "100.64.0.7"
        state.pairingPort = "9847"
        state.pairingToken = "pair-token"
        state.pairingLabel = "Studio"

        #expect(state.validatedPairingPayload?.host == "100.64.0.7")
        #expect(state.canAttemptPairing == true)

        state.isConnecting = true
        #expect(state.canAttemptPairing == false)
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
        state.prepareServerOnboarding(prefill: .init(id: "server-1", label: "Studio", host: "h", port: 1))
        state.hasPairedMac = true
        defaults.set(true, forKey: OnboardingState.completionStorageKey)

        state.reset()

        #expect(state.currentStep == .welcome)
        #expect(state.hasPairedMac == false)
        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(state.pairingPrefilledServerId == nil)
        #expect(state.completesAfterPairing == false)
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == false)
    }

    // MARK: - setup hydration

    @Test("setup snapshot exposes existing server preferences and masked credentials")
    func setupSnapshotHydratesExistingServerState() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data("""
        {
          "server": {
            "defaultWorkspace": "/tmp/tron-fixtures/example/project",
            "defaultModel": "claude-opus-4-6"
          }
        }
        """))
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
            },
            "google": {
              "hasClientId": true,
              "hasClientSecret": true,
              "projectId": "tron-project"
            }
          },
          "services": {
            "brave": {"hasApiKey": true, "apiKeyHint": "BSA...abc"}
          }
        }
        """.utf8))

        var snapshot = OnboardingSetupSnapshot()
        snapshot.hydrate(serverId: "server-1", settings: ServerSettingsSnapshot(settings), authState: AuthSnapshot(auth))

        #expect(snapshot.serverId == "server-1")
        #expect(snapshot.defaultWorkspace == "/tmp/tron-fixtures/example/project")
        #expect(snapshot.defaultModel == "claude-opus-4-6")
        #expect(snapshot.providerSummary(for: "anthropic")?.title == "API key saved")
        #expect(snapshot.providerSummary(for: "anthropic")?.detail == "work - sk-ant-...xyz")
        #expect(snapshot.providerSummary(for: "anthropic")?.credentialLabel == "work")
        #expect(snapshot.providerSummary(for: "anthropic")?.keyPreview == "sk-ant-...xyz")
        #expect(snapshot.providerSummary(for: "openai-codex")?.title == "OpenAI signed in")
        #expect(snapshot.providerSummary(for: "openai-codex")?.detail == "personal")
        #expect(snapshot.providerSummary(for: "openai-codex")?.credentialLabel == "personal")
        #expect(snapshot.providerSummary(for: "openai-codex")?.keyPreview == nil)
        #expect(snapshot.providerSummary(for: "google")?.title == "Google Cloud configured")
        #expect(snapshot.providerSummary(for: "google")?.detail == "tron-project")
        #expect(snapshot.serviceSummary(for: "brave")?.title == "API key saved")
        #expect(snapshot.serviceSummary(for: "brave")?.detail == "BSA...abc")
        #expect(snapshot.serviceSummary(for: "brave")?.keyPreview == "BSA...abc")
        #expect(snapshot.preferredApiKeyLabel(for: "anthropic") == "work")
        #expect(snapshot.preferredApiKeyLabel(for: "minimax") == "Default")
    }

    @Test("reset clears hydrated setup snapshot")
    func resetClearsSetupSnapshot() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/tmp"}}"#))
        state.hydrateSetup(serverId: "server-1", settings: ServerSettingsSnapshot(settings), authState: nil)

        state.reset()

        #expect(state.setupSnapshot.serverId == nil)
        #expect(state.setupSnapshot.defaultWorkspace == AppConstants.defaultWorkspace)
        #expect(state.setupSnapshot.defaultModel == "")
    }

    @Test("credential refresh updates setup snapshot without losing server preferences")
    func credentialRefreshUpdatesSetupSnapshot() throws {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data("""
        {
          "server": {
            "defaultWorkspace": "/tmp/tron-fixtures/example/project",
            "defaultModel": "claude-opus-4-6"
          }
        }
        """))
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
            settings: ServerSettingsSnapshot(settings),
            authState: AuthSnapshot(emptyAuth),
            authLoadError: "temporary auth failure"
        )
        state.refreshSetupAuth(AuthSnapshot(refreshedAuth))

        #expect(state.setupSnapshot.serverId == "server-1")
        #expect(state.setupSnapshot.defaultWorkspace == "/tmp/tron-fixtures/example/project")
        #expect(state.setupSnapshot.defaultModel == "claude-opus-4-6")
        #expect(state.setupSnapshot.providerSummary(for: "anthropic")?.title == "Anthropic signed in")
        #expect(state.setupSnapshot.providerSummary(for: "anthropic")?.detail == "work")
        #expect(state.setupSnapshot.providerSummary(for: "anthropic")?.credentialLabel == "work")
        #expect(state.setupSnapshot.providerSummary(for: "anthropic")?.keyPreview == nil)
        #expect(state.setupSnapshot.serviceSummary(for: "exa")?.title == "API key saved")
        #expect(state.setupSnapshot.serviceSummary(for: "exa")?.detail == "exa...123")
        #expect(state.setupSnapshot.serviceSummary(for: "exa")?.keyPreview == "exa...123")
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
