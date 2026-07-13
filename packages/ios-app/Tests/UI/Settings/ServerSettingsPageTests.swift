import Testing
@preconcurrency import Foundation

@testable import TronMobile

@Suite("Server Settings Page Tests")
struct ServerSettingsPageTests {

    @Test("server settings copy matches current labels")
    func serverSettingsCopyMatchesCurrentLabels() {
        #expect(SettingsLabels.connectToNewServer == "Connect to a new server")
        #expect(SettingsLabels.repairActiveServerPairing == "Re-pair this server")
        #expect(SettingsLabels.connectedServerUnavailableDescription == "The connected server can't be reached.")
        #expect(SettingsLabels.loadingServerSettingsDescription == "Loading server settings from the active server.")
    }

    @Test("server onboarding CTAs keep label and prefill semantics aligned")
    func serverOnboardingCTAsKeepLabelAndPrefillSemanticsAligned() throws {
        let mainSection = try source(pathComponents: [
            "Sources",
            "UI",
            "Settings",
            "Shell",
            "SettingsView+MainSection.swift",
        ])
        let serverUnavailableCard = try section(
            in: mainSection,
            from: "var serverUnavailableCard: some View {",
            to: "var settingsFooterDockView: some View {"
        )

        #expect(serverUnavailableCard.contains("Button(SettingsLabels.repairActiveServerPairing)"))
        #expect(serverUnavailableCard.contains("startOnboarding(prefill: dependencies.pairedServerStore.activeServer)"))
        #expect(!serverUnavailableCard.contains("Button(SettingsLabels.connectToNewServer)"))

        let serverSection = try source(pathComponents: [
            "Sources",
            "UI",
            "Settings",
            "Pages",
            "EngineServersSection.swift",
        ])
        let onboardRow = try section(
            in: serverSection,
            from: "private var onboardRow: some View {",
            to: "private func manageServerMenu("
        )

        #expect(onboardRow.contains("startServerOnboarding(nil)"))
        #expect(onboardRow.contains("Text(SettingsLabels.connectToNewServer)"))
        #expect(!onboardRow.contains("dependencies.pairedServerStore.activeServer"))
    }

    @Test("engine server section does not duplicate the settings toolbar log viewer")
    func engineServerSectionDoesNotDuplicateSettingsToolbarLogViewer() throws {
        let serverSection = try source(pathComponents: [
            "Sources",
            "UI",
            "Settings",
            "Pages",
            "EngineServersSection.swift",
        ])

        #expect(!serverSection.contains("showLogs"))
        #expect(!serverSection.contains("LogViewer"))
        #expect(!serverSection.contains("logsSection"))
        #expect(!serverSection.contains("Diagnostics"))
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

    @Test("server rows keep intrinsic height across sheet detents")
    func serverRowsKeepIntrinsicHeightAcrossSheetDetents() throws {
        let serverSection = try source(pathComponents: [
            "Sources",
            "UI",
            "Settings",
            "Pages",
            "EngineServersSection.swift",
        ])
        let pairedRow = try section(
            in: serverSection,
            from: "private func pairedServerRow(_ server: PairedServer) -> some View {",
            to: "private var onboardRow: some View {"
        )
        let onboardRow = try section(
            in: serverSection,
            from: "private var onboardRow: some View {",
            to: "private func manageServerMenu("
        )

        #expect(pairedRow.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(onboardRow.contains(".fixedSize(horizontal: false, vertical: true)"))
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

    private func source(pathComponents: [String]) throws -> String {
        var url = try projectRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        return fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source[startRange.upperBound...].range(of: end) else {
            throw NSError(domain: "ServerSettingsPageTests", code: 1)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
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

}
