import Testing
import SwiftUI
@testable import TronMobile

@Suite("Engine Settings Page Tests")
struct EngineSettingsOwnershipTests {

    @Test("server settings categories expose only primitive settings groups")
    func serverSettingsCategoriesExposeOnlyPrimitiveGroups() {
        #expect(ServerSettingsCategory.allCases == [
            .engine,
            .providers,
        ])

        #expect(ServerSettingsCategory.engine.title == "Engine")
        #expect(ServerSettingsCategory.engine.subtitle == "Server pairing, session defaults, context, and local transcription")
        #expect(ServerSettingsCategory.providers.icon == "circle.hexagongrid")
        #expect(ServerSettingsCategory.providers.title == "Providers")

        #expect(MainSettingsGridDestination.order == [
            .engine,
            .providers,
            .app,
        ])
        #expect(MainSettingsGridDestination.order.map(\.description) == [
            "Server pairing, session defaults, context, and local transcription",
            "OAuth login and API keys",
            "Appearance, notifications, local behavior",
        ])
        let deletedTitles = ["Hooks", "Extension Sources", "Git Workflow", "Mem" + "ory", "Ru" + "les"]
        #expect(ServerSettingsCategory.allCases.map(\.title).allSatisfy { title in
            !deletedTitles.contains(title)
        })
    }

    @Test("engine sheet owns user-configurable Engine settings")
    func engineSheetOwnsUserConfigurableEngineSettings() {
        #expect(EngineSettingsSection.allCases == [
            .defaults,
            .context,
            .transcription,
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
        #expect(EngineSettingsSummary.description(for: unloaded) == "Loading model defaults, context policy, and local transcription from the active server.")

        let loaded = EngineSettingsSummary.Context(
            isLoaded: true,
            triggerTokenThreshold: 0.65,
            preserveRecentCount: 4
        )
        #expect(EngineSettingsSummary.title(for: loaded) == "Server-owned Engine settings")
        #expect(EngineSettingsSummary.description(for: loaded) == "Session defaults, compaction at 65%, and local transcription policy are mirrored from the server.")
    }
}
