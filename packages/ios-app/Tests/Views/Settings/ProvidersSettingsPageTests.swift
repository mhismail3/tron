import Testing
import Foundation

@testable import TronMobile

@Suite("Providers Page Tests")
struct ProvidersSettingsPageTests {

    @Test("settings copy matches current labels")
    func settingsCopyMatchesCurrentLabels() {
        #expect(SettingsLabels.providers == "Providers")
        #expect(SettingsLabels.connectToNewServer == "Connect to a new server")
        #expect(SettingsLabels.transcriptionSidecar == "Transcription Sidecar")
    }

    @Test("server-backed settings show transcription before security")
    func serverBackedSettingsOrder() {
        #expect(ConnectionSettingsServerBackedSection.loadedOrder == [
            .transcriptionSidecar,
            .advancedSecurity,
        ])
        #expect(ConnectionSettingsServerBackedSection.transcriptionSidecar.title == "Transcription Sidecar")
        #expect(ConnectionSettingsServerBackedSection.advancedSecurity.title == "Advanced Security")
    }

    @Test("paired server menu uses server-specific actions")
    func pairedServerMenuUsesServerSpecificActions() {
        #expect(PairedServerMenuAction.allCases.map(\.title) == [
            "Reconnect",
            "Set Up",
            "Forget",
        ])
        #expect(PairedServerMenuAction.allCases.map(\.systemImage) == [
            "arrow.clockwise",
            "gearshape.2",
            "trash",
        ])
        #expect(PairedServerMenuAction.allCases.filter(\.isDestructive) == [.forget])
    }

    @Test("paired server menu reserves only the ellipsis hit target")
    func pairedServerMenuReservesOnlyEllipsisHitTarget() {
        #expect(PairedServerMenuLayout.hitTargetSize == 36)
    }

    @Test("server onboarding userInfo carries paired server id")
    func serverOnboardingUserInfoCarriesServerId() {
        #expect(ServerOnboardingLauncher.userInfo(serverId: "studio") == [
            ServerOnboardingLauncher.serverIdUserInfoKey: "studio",
        ])
        #expect(ServerOnboardingLauncher.userInfo(serverId: nil).isEmpty)
    }

    @Test("server onboarding posts target active server id")
    func serverOnboardingPostsTargetActiveServerId() async {
        let notificationCenter = NotificationCenter()
        let server = PairedServer(id: "studio", label: "Studio", host: "studio.local", port: 1984)

        let posted: [String: String] = await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = notificationCenter.addObserver(
                forName: .startServerOnboarding,
                object: nil,
                queue: nil
            ) { notification in
                if let observer {
                    notificationCenter.removeObserver(observer)
                }
                continuation.resume(returning: notification.userInfo as? [String: String] ?? [:])
            }

            ServerOnboardingLauncher.post(prefill: server, notificationCenter: notificationCenter)
        }

        #expect(posted == [
            ServerOnboardingLauncher.serverIdUserInfoKey: "studio",
        ])
    }

    @Test("provider auth action result only commits local form changes after success")
    func providerAuthActionResultCommitsLocalFormChangesOnlyAfterSuccess() {
        #expect(ProviderAuthActionResult.succeeded.shouldCommitLocalFormChanges)
        #expect(!ProviderAuthActionResult.failed.shouldCommitLocalFormChanges)
    }

    @Test("credential row ids are stable and credential-type scoped")
    func credentialRowIdsAreStableAndCredentialTypeScoped() {
        let oauth = ProviderCredentialRowItem(kind: .oauth, label: "work")
        let apiKey = ProviderCredentialRowItem(kind: .apiKey, label: "work")

        #expect(oauth.id == "oauth:work")
        #expect(apiKey.id == "apiKey:work")
        #expect(oauth.id != apiKey.id)
    }

    @Test("modelProviders array contains the five expected providers")
    func providerArrayShape() {
        let ids = ProviderInfo.modelProviders.map(\.id)
        #expect(ids == ["anthropic", "openai-codex", "google", "minimax", "kimi"])
    }

    @Test("services array contains Brave and Exa")
    func serviceArrayShape() {
        let ids = ProviderInfo.services.map(\.id)
        #expect(ids == ["brave", "exa"])
    }

    @Test("only Anthropic, OpenAI, and Google support OAuth")
    func oauthFlags() {
        let oauthIds = Set(ProviderInfo.modelProviders.filter(\.supportsOAuth).map(\.id))
        #expect(oauthIds == ["anthropic", "openai-codex", "google"])
    }

    @Test("MiniMax and Kimi do not support OAuth")
    func apiKeyOnlyProviders() {
        let apiKeyOnly = ProviderInfo.modelProviders.filter { !$0.supportsOAuth }.map(\.id)
        #expect(Set(apiKeyOnly) == ["minimax", "kimi"])
    }

    @Test("service system icon dispatches by id")
    func serviceSystemIcons() {
        let brave = ProviderInfo.services.first { $0.id == "brave" }!
        let exa = ProviderInfo.services.first { $0.id == "exa" }!
        #expect(brave.serviceSystemIcon == "magnifyingglass")
        #expect(exa.serviceSystemIcon == "doc.text.magnifyingglass")
    }
}
