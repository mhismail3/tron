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
        #expect(ServerSettingsCategory.engine.subtitle == "Servers, session defaults, context")
        #expect(ServerSettingsCategory.providers.icon == "circle.hexagongrid")
        #expect(ServerSettingsCategory.providers.title == "Providers")

        #expect(MainSettingsGridDestination.order == [
            .engine,
            .providers,
            .app,
        ])
        #expect(MainSettingsGridDestination.order.map(\.description) == [
            "Servers, session defaults, context",
            "OAuth and API keys",
            "Appearance, notifications, behavior",
        ])
        #expect(MainSettingsGridDestination.engine.description.contains("transcription") == false)
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

}
