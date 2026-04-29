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
        #expect(ServerSettingsCategory.context.subtitle == "Compaction, memory retention, skills, and rules")
        #expect(ServerSettingsCategory.mcpServers.title == "MCP")
        #expect(MainSettingsListLayout.categorySpacing == 8)
        #expect(MainSettingsFooterLayout.horizontalPadding == 20)
        #expect(MainSettingsFooterLayout.textLeadingPadding == 8)
        #expect(MainSettingsFooterLayout.topPadding == 10)
        #expect(MainSettingsFooterLayout.bottomPadding == 10)
        #expect(MainSettingsFooterLayout.feedbackButtonCornerRadius == 13)
        #expect(MainSettingsFooterLayout.feedbackButtonGlassTintOpacity == 0.14)
        #expect(MainSettingsFooterLayout.feedbackButtonFallbackTintOpacity == 0.08)
        #expect(MainSettingsFooterLayout.feedbackButtonFallbackStrokeOpacity == 0.16)
        #expect(MainSettingsLocalCategoryStyle.accent == .tronEmerald)
        #expect(MainSettingsLocalCategoryStyle.appIcon == "paintbrush")
        #expect(!ServerSettingsCategory.serverBackedOrder.map(\.title).contains("Hooks"))
        #expect(!ServerSettingsCategory.serverBackedOrder.map(\.title).contains("Prompt Library"))
        #expect(!ServerSettingsCategory.serverBackedOrder.map(\.title).contains("Git Workflow"))
    }

    @Test("builtin hook catalog is shared by the agent sheet")
    func builtinHookCatalogIsSharedByAgentSheet() {
        #expect(BuiltinHookCatalog.all.map(\.id) == [
            "builtin:title-gen",
            "builtin:branch-name-gen",
            "builtin:suggest-prompts",
        ])
        #expect(BuiltinHookCatalog.all.map(\.label) == [
            "Generate Session Title",
            "Generate Branch Name",
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

    @Test("agent sheet keeps prompt library settings separated under one header")
    func agentSheetGroupsPromptLibrarySettingsUnderOneHeader() {
        #expect(AgentSettingsSection.promptLibrary.rawValue == "Prompt Library")
        #expect(PromptLibrarySetting.allCases.map(\.title) == [
            "Record prompt history",
            "Prune on record / startup",
            "Prompt retention",
        ])
        #expect(PromptLibrarySetting.recordHistory.description.contains("new prompts"))
        #expect(PromptLibrarySetting.autoPrune.description.contains("retention limits"))
        #expect(PromptLibrarySetting.retention.description.contains("unlimited"))
    }

    @Test("agent sheet keeps message queue after prompt library and protected branches last")
    func agentSheetOrderKeepsQueueAndProtectedBranchesAtBottom() {
        #expect(AgentSettingsSection.allCases == [
            .quickSession,
            .hooks,
            .promptLibrary,
            .messageQueue,
            .protectedBranches,
        ])
    }

    @Test("context sheet splits compaction into individual settings")
    func contextSheetSplitsCompactionIntoIndividualSettings() {
        #expect(ContextCompactionSetting.allCases.map(\.title) == [
            "Threshold",
            "Keep Recent Turns",
            "Active Skills",
            "Skill Index",
        ])
        #expect(ContextCompactionSetting.allCases.map(\.description).allSatisfy { !$0.isEmpty })
    }

    @Test("main settings danger zone puts clear prompt history first")
    func mainSettingsDangerZonePutsClearPromptHistoryFirst() {
        #expect(SettingsDangerZoneAction.order == [
            .clearPromptHistory,
            .archiveAllSessions,
            .resetAllSettings,
        ])
        #expect(SettingsDangerZoneAction.order.map(\.title) == [
            "Clear Prompt History",
            "Archive All Sessions",
            "Reset All Settings",
        ])
    }

    @Test("agent summary describes execution lifecycle and prompt library state")
    func agentSummaryDescribesExecutionLifecycleAndPromptLibraryState() {
        let unloaded = AgentSettingsSummary.Context(
            isLoaded: false,
            queueDrainMode: "sequential",
            enabledBuiltinHookCount: 0,
            totalBuiltinHookCount: 3,
            hooksErrorPolicy: "continue",
            promptHistoryEnabled: true,
            promptHistoryMaxEntries: 10_000,
            promptHistoryMaxAgeDays: 0,
            promptHistoryAutoPrune: true,
            protectedBranchCount: 0
        )
        #expect(AgentSettingsSummary.title(for: unloaded) == "Load agent settings")
        #expect(AgentSettingsSummary.description(for: unloaded) == "Loading agent execution, hook, and prompt-history settings from the active server.")

        let loaded = AgentSettingsSummary.Context(
            isLoaded: true,
            queueDrainMode: "batched",
            enabledBuiltinHookCount: 2,
            totalBuiltinHookCount: 3,
            hooksErrorPolicy: "block",
            promptHistoryEnabled: false,
            promptHistoryMaxEntries: 0,
            promptHistoryMaxAgeDays: 30,
            promptHistoryAutoPrune: false,
            protectedBranchCount: 2
        )
        #expect(AgentSettingsSummary.title(for: loaded) == "Agent behavior")
        #expect(AgentSettingsSummary.description(for: loaded) == "Queued messages are batched into one prompt. 2 of 3 built-in hooks are enabled; hook failures block execution. Prompt history is off. 2 protected branches require push override.")
    }

    @Test("context summary describes compaction memory skills and rules")
    func contextSummaryDescribesCompactionMemorySkillsAndRules() {
        let unloaded = ContextSettingsSummary.Context(
            isLoaded: false,
            triggerTokenThreshold: 0.70,
            preserveRecentCount: 5,
            skillsCompactionPolicy: "clearAll",
            skillsShowIndex: "always",
            autoRetainInterval: 10,
            retainModelDisplayName: "Sonnet",
            rulesDiscoverStandaloneFiles: true
        )
        #expect(ContextSettingsSummary.title(for: unloaded) == "Load context settings")
        #expect(ContextSettingsSummary.description(for: unloaded) == "Loading compaction, memory, skills, and rule discovery settings from the active server.")

        let loaded = ContextSettingsSummary.Context(
            isLoaded: true,
            triggerTokenThreshold: 0.65,
            preserveRecentCount: 4,
            skillsCompactionPolicy: "autoRestore",
            skillsShowIndex: "whenNoActiveSkills",
            autoRetainInterval: 0,
            retainModelDisplayName: "Sonnet",
            rulesDiscoverStandaloneFiles: false
        )
        #expect(ContextSettingsSummary.title(for: loaded) == "Context management")
        #expect(ContextSettingsSummary.description(for: loaded) == "Compaction starts at 65%, keeps 4 recent turns, and auto-restores active skills; the skill index appears when no skills are active. Memory auto-retain is off. Standalone rule discovery is off.")
    }
}
