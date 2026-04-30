import Testing
@preconcurrency import Foundation

@testable import TronMobile

@Suite("Server Settings Page Tests")
struct ServerSettingsPageTests {

    @Test("server settings copy matches current labels")
    func serverSettingsCopyMatchesCurrentLabels() {
        #expect(SettingsLabels.connectToNewServer == "Connect to a new server")
        #expect(SettingsLabels.transcriptionSidecar == "Transcription Sidecar")
        #expect(SettingsLabels.updates == "Updates")
    }

    @Test("server-backed settings show transcription then updates")
    func serverBackedSettingsOrder() {
        #expect(ConnectionSettingsServerBackedSection.loadedOrder == [
            .transcriptionSidecar,
            .updates,
        ])
        #expect(ConnectionSettingsServerBackedSection.transcriptionSidecar.title == "Transcription Sidecar")
        #expect(ConnectionSettingsServerBackedSection.updates.title == "Updates")
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
            _ = notificationCenter.addObserver(
                forName: .startServerOnboarding,
                object: nil,
                queue: nil
            ) { notification in
                continuation.resume(returning: notification.userInfo as? [String: String] ?? [:])
            }

            ServerOnboardingLauncher.post(prefill: server, notificationCenter: notificationCenter)
        }

        #expect(posted == [
            ServerOnboardingLauncher.serverIdUserInfoKey: "studio",
        ])
    }

    @Test("server summary prompts pairing when no local servers exist")
    func serverSummaryPromptsPairingWhenNoLocalServersExist() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: nil,
            pairedServerCount: 0,
            isLoaded: false,
            loadError: nil,
            transcriptionEnabled: false,
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Connect a Mac")
        #expect(ServerSettingsSummary.description(for: context) == "Pair a Mac to manage server-backed transcription and update settings from this iPhone.")
    }

    @Test("server summary explains unavailable active server settings")
    func serverSummaryExplainsUnavailableActiveServerSettings() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 1,
            isLoaded: false,
            loadError: "Connection timed out",
            transcriptionEnabled: false,
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Manage Test Server")
        #expect(ServerSettingsSummary.description(for: context) == "Test Server is paired, but settings are unavailable: Connection timed out")
    }

    @Test("server summary reflects loaded security transcription and update settings")
    func serverSummaryReflectsLoadedSettings() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 2,
            isLoaded: true,
            loadError: nil,
            transcriptionEnabled: true,
            updateEnabled: true,
            updateChannel: "beta",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Manage Test Server")
        #expect(ServerSettingsSummary.description(for: context) == "Test Server is connected. Local transcription is on. Update checks run daily on the beta channel.")
    }

    @Test("server summary reflects disabled automatic update checks")
    func serverSummaryReflectsDisabledUpdateChecks() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 1,
            isLoaded: true,
            loadError: nil,
            transcriptionEnabled: false,
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "weekly"
        )

        #expect(ServerSettingsSummary.description(for: context) == "Test Server is connected. Local transcription is off. Automatic update checks are off.")
    }

    @Test("loaded server settings put update controls at the bottom")
    func loadedServerSettingsPutUpdateControlsAtBottom() {
        #expect(ConnectionSettingsServerBackedSection.loadedOrder.last == .updates)
    }

    @Test("update settings share one section header with separate controls")
    func updateSettingsShareOneSectionHeaderWithSeparateControls() {
        #expect(ServerUpdateSettingsItem.sectionTitle == ConnectionSettingsServerBackedSection.updates.title)
        #expect(ServerUpdateSettingsItem.allCases.map(\.title) == [
            "Automatically check for updates",
            "Release channel",
            "Check for updates",
            "Check now",
        ])
        #expect(ServerUpdateSettingsItem.allCases.map(\.icon) == [
            "arrow.down.app",
            "shippingbox",
            "clock.arrow.2.circlepath",
            "arrow.clockwise",
        ])
        #expect(ServerUpdateSettingsItem.allCases.map(\.description).allSatisfy { !$0.isEmpty })
    }
}
