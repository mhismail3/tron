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
            .notifications,
            .app,
        ])
        #expect(MainSettingsGridDestination.order.map(\.description) == [
            "Servers, session defaults, context",
            "OAuth and API keys",
            "Permission, delivery readiness, inbox",
            "Appearance and behavior",
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
            .stopAllWorkers,
            .archiveAllSessions,
            .resetAllSettings,
        ])
        #expect(SettingsDangerZoneAction.stopAllWorkers.isEnabled(
            hasSessions: false,
            workerDispatchReady: true,
            serverSettingsReady: false,
            serverSettingsUnavailable: false,
            isInProgress: false
        ))
        #expect(
            SettingsDangerZoneAction.stopAllWorkers.displayTitle(workersStopped: false)
                == "Stop All Workers"
        )
        #expect(
            SettingsDangerZoneAction.stopAllWorkers.displayTitle(workersStopped: true)
                == "Resume All Workers"
        )
        #expect(SettingsDangerZoneAction.archiveAllSessions.isEnabled(
            hasSessions: true,
            workerDispatchReady: false,
            serverSettingsReady: false,
            serverSettingsUnavailable: true,
            isInProgress: false
        ) == false)
        #expect(SettingsDangerZoneAction.archiveAllSessions.isEnabled(
            hasSessions: true,
            workerDispatchReady: false,
            serverSettingsReady: false,
            serverSettingsUnavailable: false,
            isInProgress: false
        ))
        #expect(SettingsDangerZoneAction.resetAllSettings.isEnabled(
            hasSessions: false,
            workerDispatchReady: false,
            serverSettingsReady: false,
            serverSettingsUnavailable: true,
            isInProgress: true
        ))
    }

}
