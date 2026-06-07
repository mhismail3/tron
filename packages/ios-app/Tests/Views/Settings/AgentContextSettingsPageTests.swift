import Testing
import SwiftUI
@testable import TronMobile

@Suite("Agent and Context Settings Page Tests")
struct AgentContextSettingsPageTests {

    @Test("server settings categories split agent and context and retire git workflow route")
    func serverSettingsCategoriesSplitAgentAndContext() {
        #expect(ServerSettingsCategory.serverBackedOrder == [
            .server,
            .providers,
            .agent,
            .context,
            .mcpServers,
        ])

        #expect(ServerSettingsCategory.server.title == "Servers")
        #expect(ServerSettingsCategory.providers.icon == "circle.hexagongrid")
        #expect(ServerSettingsCategory.agent.title == "Agent")
        #expect(ServerSettingsCategory.agent.subtitle == "Hooks, prompts, queueing, and branch safety")
        #expect(ServerSettingsCategory.agent.subtitle.count <= 44)
        #expect(ServerSettingsCategory.context.title == "Context")
        #expect(ServerSettingsCategory.context.icon == "gauge.with.dots.needle.67percent")
        #expect(ServerSettingsCategory.context.subtitle == "Compaction, memory retention, and rules")
        #expect(ServerSettingsCategory.mcpServers.title == "Plugin Sources")
        #expect(MainSettingsGridDestination.surfaceRow == [
            .app,
            .server,
            .providers,
        ])
        #expect(MainSettingsGridDestination.surfaceRow.map(\.title) == [
            "App",
            "Server",
            "Providers",
        ])
        #expect(MainSettingsGridDestination.surfaceRow.map(\.description) == [
            "Appearance, notifications, local behavior",
            "Paired servers, transcription, updates",
            "OAuth login and API keys",
        ])
        #expect(MainSettingsGridDestination.behaviorRow == [
            .agent,
            .context,
            .mcpServers,
        ])
        #expect(MainSettingsGridDestination.behaviorRow.map(\.title) == [
            "Agent",
            "Context",
            "Plugin Sources",
        ])
        #expect(MainSettingsGridDestination.behaviorRow.map(\.description) == [
            "Hooks, prompts, queueing",
            "Compaction, memory, rules",
            "External capability sources",
        ])
        #expect(MainSettingsGridDestination.unavailableRow == [
            .app,
            .server,
        ])
        #expect(MainSettingsGridDestination.visibleDestinations(serverSettingsUnavailable: false) == [
            .app,
            .server,
            .providers,
            .agent,
            .context,
            .mcpServers,
        ])
        #expect(MainSettingsGridDestination.visibleDestinations(serverSettingsUnavailable: true) == [
            .app,
            .server,
        ])
        #expect(MainSettingsGridLayout.columnCount == 3)
        #expect(MainSettingsGridLayout.unavailableColumnCount == 2)
        #expect(MainSettingsGridLayout.destinationColumnCount(serverSettingsUnavailable: false) == 3)
        #expect(MainSettingsGridLayout.destinationColumnCount(serverSettingsUnavailable: true) == 2)
        #expect(MainSettingsGridLayout.columnSpacing == 8)
        #expect(MainSettingsGridLayout.rowSpacing == 8)
        #expect(MainSettingsGridLayout.destinationTileMinHeight == 98)
        #expect(MainSettingsGridLayout.dangerTileMinHeight == 0)
        #expect(MainSettingsGridLayout.dividerHeight == 1)
        #expect(MainSettingsGridLayout.dividerHorizontalPadding == 2)
        #expect(MainSettingsGridLayout.dividerVerticalPadding == 6)
        #expect(MainSettingsGridLayout.dividerOpacity == 0.22)
        #expect(MainSettingsGridLayout.iconSize == TronTypography.sizeLargeTitle)
        #expect(MainSettingsGridLayout.iconFrameSize == 22)
        #expect(MainSettingsGridLayout.destinationTitleSize == TronTypography.sizeTitle)
        #expect(MainSettingsGridLayout.destinationDescriptionSize == TronTypography.sizeSM)
        #expect(MainSettingsGridLayout.destinationDescriptionTopPadding == 6)
        #expect(MainSettingsGridLayout.destinationDescriptionOpacity == 0.68)
        #expect(MainSettingsGridLayout.dangerTitleSize == TronTypography.sizeBodySM)
        #expect(MainSettingsFooterLayout.horizontalPadding == 20)
        #expect(MainSettingsFooterLayout.textLeadingPadding == 8)
        #expect(MainSettingsFooterLayout.topPadding == 10)
        #expect(MainSettingsFooterLayout.bottomPadding == 10)
        #expect(MainSettingsFooterLayout.feedbackButtonCornerRadius == 13)
        #expect(MainSettingsFooterLayout.feedbackButtonGlassTintOpacity == 0.14)
        #expect(MainSettingsLocalCategoryStyle.accent == .tronEmerald)
        #expect(MainSettingsLocalCategoryStyle.appIcon == "paintbrush")
        #expect(!ServerSettingsCategory.serverBackedOrder.map(\.title).contains("Hooks"))
        #expect(ServerSettingsCategory.serverBackedOrder.map(\.title).allSatisfy { !$0.contains("Prompt") })
        #expect(!ServerSettingsCategory.serverBackedOrder.map(\.title).contains("Git Workflow"))
    }

    @Test("builtin hook catalog is shared by the agent sheet")
    func builtinHookCatalogIsSharedByAgentSheet() {
        #expect(BuiltinHookCatalog.all.map(\.id) == [
            "builtin:title-gen",
            "builtin:suggest-prompts",
        ])
        #expect(BuiltinHookCatalog.all.map(\.label) == [
            "Generate Session Title",
            "Suggest Follow-up Prompts",
        ])
    }

    @Test("agent sheet groups hook settings under one hooks header")
    func agentSheetGroupsHookSettingsUnderOneHooksHeader() {
        #expect(AgentSettingsSection.hooks.rawValue == "Hooks")
        #expect(AgentHookSetting.allCases.map(\.title) == [
            "LLM Hook Model",
            "Hook error policy",
            "Built-in lifecycle hooks",
            "User hook directory",
        ])
        #expect(AgentHookSetting.allCases.map(\.description).allSatisfy { !$0.isEmpty })
    }

    @Test("user hook directory card shows path and empty state copy")
    func userHookDirectoryCardShowsPathAndEmptyStateCopy() {
        #expect(UserHookDirectoryDisplay.path == "~/.tron/hooks/")
        #expect(UserHookDirectoryDisplay.emptyState == "No user added hooks found")
    }

    @Test("agent sheet keeps message queue before protected branches")
    func agentSheetOrderKeepsQueueAndProtectedBranchesAtBottom() {
        #expect(AgentSettingsSection.allCases == [
            .quickSession,
            .autonomy,
            .guardrails,
            .hooks,
            .messageQueue,
            .protectedBranches,
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
        #expect(SettingsDangerZoneAction.order.map(\.title) == [
            "Archive All Sessions",
            "Reset All Settings",
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
        #expect(SettingsDangerZoneAction.archiveAllSessions.isEnabled(
            hasSessions: false,
            serverSettingsReady: true,
            serverSettingsUnavailable: false,
            isInProgress: false
        ) == false)
        #expect(SettingsDangerZoneAction.resetAllSettings.isEnabled(
            hasSessions: false,
            serverSettingsReady: false,
            serverSettingsUnavailable: true,
            isInProgress: true
        ))
    }

    @Test("agent summary describes execution lifecycle")
    func agentSummaryDescribesExecutionLifecycle() {
        let unloaded = AgentSettingsSummary.Context(
            isLoaded: false,
            queueDrainMode: "sequential",
            enabledBuiltinHookCount: 0,
            totalBuiltinHookCount: 2,
            hooksErrorPolicy: "continue",
            protectedBranchCount: 0
        )
        #expect(AgentSettingsSummary.title(for: unloaded) == "Load agent settings")
        #expect(AgentSettingsSummary.description(for: unloaded) == "Loading agent execution and hook settings from the active server.")

        let loaded = AgentSettingsSummary.Context(
            isLoaded: true,
            queueDrainMode: "batched",
            enabledBuiltinHookCount: 2,
            totalBuiltinHookCount: 2,
            hooksErrorPolicy: "block",
            protectedBranchCount: 2
        )
        #expect(AgentSettingsSummary.title(for: loaded) == "Agent behavior")
        #expect(AgentSettingsSummary.description(for: loaded) == "Queued messages are batched into one prompt. 2 of 2 built-in hooks are enabled; hook failures block execution. 2 protected branches require push override.")
    }

    @Test("context summary describes compaction memory and rules")
    func contextSummaryDescribesCompactionMemoryAndRules() {
        let unloaded = ContextSettingsSummary.Context(
            isLoaded: false,
            triggerTokenThreshold: 0.70,
            preserveRecentCount: 5,
            autoRetainInterval: 10,
            retainModelDisplayName: "Sonnet",
            rulesDiscoverStandaloneFiles: true
        )
        #expect(ContextSettingsSummary.title(for: unloaded) == "Load context settings")
        #expect(ContextSettingsSummary.description(for: unloaded) == "Loading compaction, memory, and rule discovery settings from the active server.")

        let loaded = ContextSettingsSummary.Context(
            isLoaded: true,
            triggerTokenThreshold: 0.65,
            preserveRecentCount: 4,
            autoRetainInterval: 0,
            retainModelDisplayName: "Sonnet",
            rulesDiscoverStandaloneFiles: false
        )
        #expect(ContextSettingsSummary.title(for: loaded) == "Context management")
        #expect(ContextSettingsSummary.description(for: loaded) == "Compaction starts at 65% and keeps 4 recent turns. Memory auto-retain is off. Standalone rule discovery is off.")
    }
}
