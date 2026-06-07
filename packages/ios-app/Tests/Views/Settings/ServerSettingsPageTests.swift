import Testing
@preconcurrency import Foundation

@testable import TronMobile

@Suite("Server Settings Page Tests")
struct ServerSettingsPageTests {

    @Test("server settings copy matches current labels")
    func serverSettingsCopyMatchesCurrentLabels() {
        #expect(SettingsLabels.connectToNewServer == "Connect to a new server")
        #expect(SettingsLabels.connectedServerUnavailableDescription == "The connected server can't be reached.")
        #expect(SettingsLabels.loadingServerSettingsDescription == "Loading server settings from the active server.")
        #expect(SettingsLabels.updates == "Updates")
    }

    @Test("server-backed settings show updates then diagnostics")
    func serverBackedSettingsOrder() {
        #expect(ConnectionSettingsServerBackedSection.loadedOrder == [
            .updates,
            .diagnostics,
        ])
        #expect(ConnectionSettingsServerBackedSection.updates.title == "Updates")
        #expect(ConnectionSettingsServerBackedSection.diagnostics.title == "Engine Diagnostics")
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

    @Test("deferred onboarding launch preserves nil prefill until settings dismiss")
    func deferredOnboardingLaunchPreservesNilPrefill() {
        var launch = DeferredServerOnboardingLaunch()

        launch.request(prefill: nil)

        let request = launch.consume()
        #expect(request != nil)
        #expect(request?.prefill == nil)
        #expect(launch.consume() == nil)
    }

    @Test("deferred onboarding launch preserves paired server until settings dismiss")
    func deferredOnboardingLaunchPreservesPairedServer() {
        var launch = DeferredServerOnboardingLaunch()
        let server = PairedServer(id: "studio", label: "Studio", host: "studio.local", port: 1984)

        launch.request(prefill: server)

        #expect(launch.consume()?.prefill == server)
        #expect(launch.consume() == nil)
    }

    @Test("server summary prompts pairing when no local servers exist")
    func serverSummaryPromptsPairingWhenNoLocalServersExist() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: nil,
            pairedServerCount: 0,
            activeServerUnavailable: false,
            isLoaded: false,
            loadError: nil,
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Connect a Mac")
        #expect(ServerSettingsSummary.description(for: context) == "Pair a Mac to manage server-backed update and diagnostics settings from this iPhone.")
    }

    @Test("server summary explains unavailable active server settings")
    func serverSummaryExplainsUnavailableActiveServerSettings() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 1,
            activeServerUnavailable: false,
            isLoaded: false,
            loadError: "Connection timed out",
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Manage Test Server")
        #expect(ServerSettingsSummary.description(for: context) == "Test Server is paired, but settings are unavailable: Connection timed out")
    }

    @Test("server summary explains connected loading state")
    func serverSummaryExplainsConnectedLoadingState() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 1,
            activeServerUnavailable: false,
            isLoaded: false,
            loadError: nil,
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Manage Test Server")
        #expect(ServerSettingsSummary.description(for: context) == "Test Server is connected. Loading update and diagnostics settings.")
    }

    @Test("server summary warns when active server cannot be reached")
    func serverSummaryWarnsWhenActiveServerCannotBeReached() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 1,
            activeServerUnavailable: true,
            isLoaded: false,
            loadError: "Connection timed out",
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Test Server not available")
        #expect(ServerSettingsSummary.description(for: context) == SettingsLabels.connectedServerUnavailableDescription)
    }

    @Test("server controls status hides when no active server exists")
    func serverControlsStatusHidesWhenNoActiveServerExists() {
        let status = ConnectionSettingsServerControlsStatus.resolve(
            hasActiveServer: false,
            activeServerUnavailable: false,
            loadError: nil
        )

        #expect(status == nil)
    }

    @Test("server controls status shows unavailable copy for disconnected active server")
    func serverControlsStatusShowsUnavailableCopyForDisconnectedActiveServer() throws {
        let status = try #require(ConnectionSettingsServerControlsStatus.resolve(
            hasActiveServer: true,
            activeServerUnavailable: true,
            loadError: nil
        ))

        #expect(status.title == "Server settings unavailable")
        #expect(status.description == SettingsLabels.connectedServerUnavailableDescription)
        #expect(status.icon == "wifi.exclamationmark")
    }

    @Test("server controls status keeps explicit load error")
    func serverControlsStatusKeepsExplicitLoadError() throws {
        let status = try #require(ConnectionSettingsServerControlsStatus.resolve(
            hasActiveServer: true,
            activeServerUnavailable: false,
            loadError: "Connection timed out"
        ))

        #expect(status.title == "Server settings unavailable")
        #expect(status.description == "Connection timed out")
        #expect(status.icon == "wifi.exclamationmark")
    }

    @Test("server controls status shows loading for connected active server before settings load")
    func serverControlsStatusShowsLoadingForConnectedActiveServerBeforeSettingsLoad() throws {
        let status = try #require(ConnectionSettingsServerControlsStatus.resolve(
            hasActiveServer: true,
            activeServerUnavailable: false,
            loadError: nil
        ))

        #expect(status.title == "Loading server settings")
        #expect(status.description == SettingsLabels.loadingServerSettingsDescription)
        #expect(status.icon == "hourglass")
    }

    @Test("server summary reflects loaded update settings")
    func serverSummaryReflectsLoadedSettings() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 2,
            activeServerUnavailable: false,
            isLoaded: true,
            loadError: nil,
            updateEnabled: true,
            updateChannel: "beta",
            updateFrequency: "daily"
        )

        #expect(ServerSettingsSummary.title(for: context) == "Manage Test Server")
        #expect(ServerSettingsSummary.description(for: context) == "Test Server is connected. Update checks run daily on the beta channel.")
    }

    @Test("server summary reflects disabled automatic update checks")
    func serverSummaryReflectsDisabledUpdateChecks() {
        let context = ServerSettingsSummary.Context(
            activeServerLabel: "Test Server",
            pairedServerCount: 1,
            activeServerUnavailable: false,
            isLoaded: true,
            loadError: nil,
            updateEnabled: false,
            updateChannel: "stable",
            updateFrequency: "weekly"
        )

        #expect(ServerSettingsSummary.description(for: context) == "Test Server is connected. Automatic update checks are off.")
    }

    @Test("active unreachable row overrides stale connected status")
    func activeUnreachableRowOverridesStaleConnectedStatus() {
        let presentation = PairedServerRowPresentation.resolve(
            isSelected: true,
            activeServerUnavailable: true,
            lastKnownStatus: "Connected"
        )

        #expect(presentation.status == "Unavailable")
        #expect(presentation.statusTone == .warning)
        #expect(presentation.menuEntries.map(\.action) == [.reconnect, .forget])
        #expect(presentation.menuEntries.map(\.title) == ["Retry", "Forget"])
    }

    @Test("active connected row shows live connected status")
    func activeConnectedRowShowsLiveConnectedStatus() {
        let presentation = PairedServerRowPresentation.resolve(
            isSelected: true,
            activeServerUnavailable: false,
            lastKnownStatus: nil
        )

        #expect(presentation.status == "Connected")
        #expect(presentation.statusTone == .success)
        #expect(presentation.menuEntries.map(\.title) == [
            "Reconnect",
            "Set Up",
            "Forget",
        ])
    }

    @Test("inactive rows preserve local status metadata")
    func inactiveRowsPreserveLocalStatusMetadata() {
        let presentation = PairedServerRowPresentation.resolve(
            isSelected: false,
            activeServerUnavailable: true,
            lastKnownStatus: "Connected"
        )

        #expect(presentation.status == "Connected")
        #expect(presentation.statusTone == .success)
        #expect(presentation.menuEntries.map(\.title) == [
            "Reconnect",
            "Set Up",
            "Forget",
        ])
    }

    @Test("loaded server settings keep diagnostics after update controls")
    func loadedServerSettingsKeepDiagnosticsAfterUpdateControls() {
        #expect(ConnectionSettingsServerBackedSection.loadedOrder.suffix(2) == [
            .updates,
            .diagnostics,
        ])
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
