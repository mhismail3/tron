import Testing
import SwiftUI
@testable import TronMobile

@Suite("Agent and Context Settings Page Tests")
struct AgentContextSettingsPageTests {

    @Test("server settings categories expose only primitive settings groups")
    func serverSettingsCategoriesExposeOnlyPrimitiveGroups() {
        #expect(ServerSettingsCategory.serverBackedOrder == [
            .server,
            .providers,
            .agent,
            .context,
        ])

        #expect(ServerSettingsCategory.server.title == "Servers")
        #expect(ServerSettingsCategory.server.subtitle == "Paired servers and evidence")
        #expect(ServerSettingsCategory.providers.icon == "circle.hexagongrid")
        #expect(ServerSettingsCategory.agent.title == "Agent")
        #expect(ServerSettingsCategory.agent.subtitle == "Prompt defaults")
        #expect(ServerSettingsCategory.context.title == "Context")
        #expect(ServerSettingsCategory.context.subtitle == "Compaction for the prompt loop")

        #expect(MainSettingsGridDestination.surfaceRow == [
            .app,
            .server,
            .providers,
        ])
        #expect(MainSettingsGridDestination.surfaceRow.map(\.description) == [
            "Appearance, notifications, local behavior",
            "Paired servers and evidence",
            "OAuth login and API keys",
        ])
        #expect(MainSettingsGridDestination.behaviorRow == [
            .agent,
            .context,
        ])
        #expect(MainSettingsGridDestination.behaviorRow.map(\.description) == [
            "Prompt defaults",
            "Prompt compaction",
        ])
        #expect(MainSettingsGridDestination.visibleDestinations(serverSettingsUnavailable: false) == [
            .app,
            .server,
            .providers,
            .agent,
            .context,
        ])
        #expect(MainSettingsGridDestination.visibleDestinations(serverSettingsUnavailable: true) == [
            .app,
            .server,
        ])
        let deletedTitles = ["Hooks", "Extension Sources", "Git Workflow", "Mem" + "ory", "Ru" + "les"]
        #expect(ServerSettingsCategory.allCases.map(\.title).allSatisfy { title in
            !deletedTitles.contains(title)
        })
    }

    @Test("agent sheet keeps only quick session settings")
    func agentSheetKeepsOnlyPrimitiveSections() {
        #expect(AgentSettingsSection.allCases == [
            .quickSession,
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

    @Test("agent summary describes prompt defaults")
    func agentSummaryDescribesPromptDefaults() {
        let unloaded = AgentSettingsSummary.Context(
            isLoaded: false
        )
        #expect(AgentSettingsSummary.title(for: unloaded) == "Load agent settings")
        #expect(AgentSettingsSummary.description(for: unloaded) == "Loading prompt defaults from the active server.")

        let loaded = AgentSettingsSummary.Context(
            isLoaded: true
        )
        #expect(AgentSettingsSummary.title(for: loaded) == "Agent behavior")
        #expect(AgentSettingsSummary.description(for: loaded) == "Prompt defaults are loaded from the active server.")
    }

    @Test("context summary describes compaction only")
    func contextSummaryDescribesCompactionOnly() {
        let unloaded = ContextSettingsSummary.Context(
            isLoaded: false,
            triggerTokenThreshold: 0.70,
            preserveRecentCount: 5
        )
        #expect(ContextSettingsSummary.title(for: unloaded) == "Load context settings")
        #expect(ContextSettingsSummary.description(for: unloaded) == "Loading compaction settings from the active server.")

        let loaded = ContextSettingsSummary.Context(
            isLoaded: true,
            triggerTokenThreshold: 0.65,
            preserveRecentCount: 4
        )
        #expect(ContextSettingsSummary.title(for: loaded) == "Context management")
        #expect(ContextSettingsSummary.description(for: loaded) == "Compaction starts at 65% and keeps 4 recent turns.")
    }
}
