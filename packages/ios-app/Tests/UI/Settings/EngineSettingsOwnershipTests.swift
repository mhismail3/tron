import Testing
import SwiftUI
@testable import TronMobile

@Suite("Engine Settings Page Tests")
struct EngineSettingsOwnershipTests {

    @Test("server settings categories expose only primitive settings groups")
    func serverSettingsCategoriesExposeOnlyPrimitiveGroups() {
        #expect(ServerSettingsCategory.serverBackedOrder == [
            .engine,
            .providers,
            .server,
        ])

        #expect(ServerSettingsCategory.engine.title == "Engine")
        #expect(ServerSettingsCategory.engine.subtitle == "Server-owned defaults, context, and evidence policy")
        #expect(ServerSettingsCategory.server.title == "Servers")
        #expect(ServerSettingsCategory.server.subtitle == "Pairing and connection")
        #expect(ServerSettingsCategory.providers.icon == "circle.hexagongrid")
        #expect(ServerSettingsCategory.providers.title == "Accounts")

        #expect(MainSettingsGridDestination.serverOwned == [
            .engine,
            .providers,
        ])
        #expect(MainSettingsGridDestination.serverOwned.map(\.description) == [
            "Server-owned defaults, context, and evidence policy",
            "OAuth login and API keys",
        ])
        #expect(MainSettingsGridDestination.deviceOwned == [
            .server,
            .app,
        ])
        #expect(MainSettingsGridDestination.deviceOwned.map(\.description) == [
            "Pairing and connection",
            "Appearance, notifications, local behavior",
        ])
        #expect(MainSettingsGridDestination.visibleDestinations(serverSettingsUnavailable: false) == [
            .engine,
            .providers,
            .server,
            .app,
        ])
        #expect(MainSettingsGridDestination.visibleDestinations(serverSettingsUnavailable: true) == [
            .server,
            .app,
        ])
        let deletedTitles = ["Hooks", "Extension Sources", "Git Workflow", "Mem" + "ory", "Ru" + "les"]
        #expect(ServerSettingsCategory.allCases.map(\.title).allSatisfy { title in
            !deletedTitles.contains(title)
        })
    }

    @Test("engine sheet keeps server-owned settings in one progressive page")
    func engineSheetKeepsServerOwnedSettingsTogether() {
        #expect(EngineSettingsSection.allCases == [
            .defaults,
            .context,
            .evidence,
        ])
    }

    @Test("context sheet splits compaction into individual settings")
    func contextSheetSplitsCompactionIntoIndividualSettings() {
        #expect(ContextCompactionSetting.allCases.map(\.title) == [
            "Threshold",
            "Keep Recent Turns",
        ])
        #expect(ContextCompactionSetting.allCases.map(\.description).allSatisfy { !$0.isEmpty })
    }

    @Test("main settings danger row exposes durable account actions")
    func mainSettingsDangerRowExposesDurableAccountActions() {
        #expect(SettingsDangerZoneAction.order == [
            .archiveAllSessions,
            .resetAllSettings,
        ])
        #expect(SettingsDangerZoneAction.archiveAllSessions.isEnabled(
            hasSessions: true,
            serverSettingsReady: false,
            serverSettingsUnavailable: true,
            isInProgress: false
        ) == false)
        #expect(SettingsDangerZoneAction.archiveAllSessions.isEnabled(
            hasSessions: true,
            serverSettingsReady: false,
            serverSettingsUnavailable: false,
            isInProgress: false
        ))
        #expect(SettingsDangerZoneAction.resetAllSettings.isEnabled(
            hasSessions: false,
            serverSettingsReady: false,
            serverSettingsUnavailable: true,
            isInProgress: true
        ))
    }

    @Test("engine summary describes server owned settings")
    func engineSummaryDescribesServerOwnedSettings() {
        let unloaded = EngineSettingsSummary.Context(
            isLoaded: false,
            triggerTokenThreshold: 0.70,
            preserveRecentCount: 5
        )
        #expect(EngineSettingsSummary.title(for: unloaded) == "Load engine settings")
        #expect(EngineSettingsSummary.description(for: unloaded) == "Loading model defaults, context, and evidence policy from the active server.")

        let loaded = EngineSettingsSummary.Context(
            isLoaded: true,
            triggerTokenThreshold: 0.65,
            preserveRecentCount: 4
        )
        #expect(EngineSettingsSummary.title(for: loaded) == "Server-owned engine policy")
        #expect(EngineSettingsSummary.description(for: loaded) == "Defaults, compaction at 65%, and evidence retention are mirrored from the server.")
    }
}
