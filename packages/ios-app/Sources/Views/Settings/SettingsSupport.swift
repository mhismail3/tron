import Foundation
import CoreGraphics
import SwiftUI

// ARCHITECTURE: Shared settings copy and sheet-launch contracts live here so
// page views stay focused on layout and state binding.

enum SettingsLabels {
    static let providers = "Providers"
    static let connectToNewServer = "Connect to a new server"
    static let connectedServerUnavailableDescription = ConnectionStatusCopy.connectedServerUnavailableDescription
    static let loadingServerSettingsDescription = "Loading server settings from the active server."
    static let transcriptionSidecar = "Transcription Sidecar"
    static let updates = "Updates"
}

enum ServerSettingsCategory: CaseIterable, Hashable, Sendable {
    case server
    case providers
    case agent
    case context
    case mcpServers

    static let serverBackedOrder: [Self] = [
        .server,
        .providers,
        .agent,
        .context,
        .mcpServers,
    ]

    var icon: String {
        switch self {
        case .server:
            return "network"
        case .providers:
            return "circle.hexagongrid"
        case .agent:
            return "wand.and.stars"
        case .context:
            return "gauge.with.dots.needle.67percent"
        case .mcpServers:
            return "server.rack"
        }
    }

    var title: String {
        switch self {
        case .server:
            return "Servers"
        case .providers:
            return SettingsLabels.providers
        case .agent:
            return "Agent"
        case .context:
            return "Context"
        case .mcpServers:
            return "MCP"
        }
    }

    var subtitle: String {
        switch self {
        case .server:
            return "Paired servers, transcription, and updates"
        case .providers:
            return "Login with OAuth and configure API keys"
        case .agent:
            return "Hooks, prompts, queueing, and branch safety"
        case .context:
            return "Compaction, memory retention, skills, and rules"
        case .mcpServers:
            return "Configure external tool servers"
        }
    }
}

enum MainSettingsLocalCategoryStyle {
    static let accent: Color = .tronEmerald
    static let appIcon = "paintbrush"
}

enum MainSettingsListLayout {
    static let categorySpacing: CGFloat = 8
    static let unavailableActionLeadingPadding: CGFloat = 28
}

enum MainSettingsFooterLayout {
    static let horizontalPadding: CGFloat = 20
    static let textLeadingPadding: CGFloat = 8
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 10
    static let feedbackButtonCornerRadius: CGFloat = 13
    static let feedbackButtonGlassTintOpacity = 0.14
}

struct BuiltinHookInfo: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let description: String
    let event: String
}

enum BuiltinHookCatalog {
    static let all: [BuiltinHookInfo] = [
        BuiltinHookInfo(
            id: "builtin:title-gen",
            label: "Generate Session Title",
            description: "Auto-generates a short title when a session starts",
            event: "session-start"
        ),
        BuiltinHookInfo(
            id: "builtin:branch-name-gen",
            label: "Generate Branch Name",
            description: "Renames worktree branches to memorable 3-word names",
            event: "worktree-acquired"
        ),
        BuiltinHookInfo(
            id: "builtin:suggest-prompts",
            label: "Suggest Follow-up Prompts",
            description: "Suggests short follow-up prompts when the agent finishes",
            event: "stop"
        ),
    ]
}

enum AgentSettingsSection: String, CaseIterable, Sendable {
    case quickSession = "Quick Session"
    case hooks = "Hooks"
    case promptLibrary = "Prompt Library"
    case messageQueue = "Message Queue"
    case protectedBranches = "Protected Branches"
}

enum AgentHookSetting: CaseIterable, Hashable, Sendable {
    case llmModel
    case errorPolicy
    case builtInHooks
    case userHooks

    var title: String {
        switch self {
        case .builtInHooks:
            return "Built-in lifecycle hooks"
        case .llmModel:
            return "LLM Hook Model"
        case .errorPolicy:
            return "Hook error policy"
        case .userHooks:
            return "User hook directory"
        }
    }

    var description: String {
        switch self {
        case .builtInHooks:
            return "Enable platform hooks that create session titles, branch names, and follow-up suggestions as the agent runs."
        case .llmModel:
            return "Model used for built-in and .prompt hooks. Defaults to Haiku for speed."
        case .errorPolicy:
            return "Continue lets the agent proceed when a hook fails. Block stops execution with a safety reason."
        case .userHooks:
            return "Place .prompt or script files (.sh, .js, .ts) with YAML frontmatter. Hooks are discovered fresh each session."
        }
    }
}

enum UserHookDirectoryDisplay {
    static let path = "~/.tron/hooks/"
    static let emptyState = "No user added hooks found"
}

enum PromptLibrarySetting: CaseIterable, Hashable, Sendable {
    case recordHistory
    case autoPrune
    case retention

    var title: String {
        switch self {
        case .recordHistory:
            return "Record prompt history"
        case .autoPrune:
            return "Prune on record / startup"
        case .retention:
            return "Prompt retention"
        }
    }

    var description: String {
        switch self {
        case .recordHistory:
            return "When recording is off, new prompts are not saved to the server prompt history."
        case .autoPrune:
            return "When enabled, the server removes prompt-history entries that exceed retention limits after recording a prompt and during startup."
        case .retention:
            return "0 means unlimited. Retention rules only apply when auto-prune is enabled."
        }
    }
}

enum ContextCompactionSetting: CaseIterable, Hashable, Sendable {
    case threshold
    case recentTurns
    case activeSkills
    case skillIndex

    var title: String {
        switch self {
        case .threshold:
            return "Threshold"
        case .recentTurns:
            return "Keep Recent Turns"
        case .activeSkills:
            return "Active Skills"
        case .skillIndex:
            return "Skill Index"
        }
    }

    var description: String {
        switch self {
        case .threshold:
            return "Compaction starts when context usage reaches this percentage of the model window."
        case .recentTurns:
            return "Most recent turns to keep verbatim when older context is compacted."
        case .activeSkills:
            return "Controls whether active skills are cleared, restored, or require confirmation after compaction."
        case .skillIndex:
            return "Controls when the lightweight skill index is included in the system prompt."
        }
    }
}

enum SettingsDangerZoneAction: CaseIterable, Hashable, Sendable {
    case clearPromptHistory
    case archiveAllSessions
    case resetAllSettings

    static let order: [Self] = [
        .clearPromptHistory,
        .archiveAllSessions,
        .resetAllSettings,
    ]

    var title: String {
        switch self {
        case .clearPromptHistory:
            return "Clear Prompt History"
        case .archiveAllSessions:
            return "Archive All Sessions"
        case .resetAllSettings:
            return "Reset All Settings"
        }
    }

    var icon: String {
        switch self {
        case .clearPromptHistory:
            return "clock.badge.xmark"
        case .archiveAllSessions:
            return "archivebox"
        case .resetAllSettings:
            return "arrow.trianglehead.counterclockwise"
        }
    }
}

enum AgentSettingsSummary {
    struct Context: Equatable, Sendable {
        let isLoaded: Bool
        let queueDrainMode: String
        let enabledBuiltinHookCount: Int
        let totalBuiltinHookCount: Int
        let hooksErrorPolicy: String
        let promptHistoryEnabled: Bool
        let promptHistoryMaxEntries: Int
        let promptHistoryMaxAgeDays: Int
        let promptHistoryAutoPrune: Bool
        let protectedBranchCount: Int
    }

    static func title(for context: Context) -> String {
        guard context.isLoaded else {
            return "Load agent settings"
        }

        return "Agent behavior"
    }

    static func description(for context: Context) -> String {
        guard context.isLoaded else {
            return "Loading agent execution, hook, and prompt-history settings from the active server."
        }

        let queue = queueDescription(context.queueDrainMode)
        let hooks = hooksDescription(
            enabled: context.enabledBuiltinHookCount,
            total: context.totalBuiltinHookCount,
            errorPolicy: context.hooksErrorPolicy
        )
        let prompt = promptHistoryDescription(
            enabled: context.promptHistoryEnabled,
            maxEntries: context.promptHistoryMaxEntries,
            maxAgeDays: context.promptHistoryMaxAgeDays,
            autoPrune: context.promptHistoryAutoPrune
        )
        let protectedBranches = protectedBranchesDescription(context.protectedBranchCount)
        return "\(queue) \(hooks). \(prompt) \(protectedBranches)"
    }

    private static func queueDescription(_ mode: String) -> String {
        switch mode {
        case "batched":
            return "Queued messages are batched into one prompt."
        default:
            return "Queued messages are delivered one turn at a time."
        }
    }

    private static func hooksDescription(
        enabled: Int,
        total: Int,
        errorPolicy: String
    ) -> String {
        let safeEnabled = max(0, enabled)
        let safeTotal = max(safeEnabled, total)
        let failureBehavior = errorPolicy == "block" ? "block execution" : "let execution continue"
        return "\(safeEnabled) of \(safeTotal) built-in hooks are enabled; hook failures \(failureBehavior)"
    }

    private static func promptHistoryDescription(
        enabled: Bool,
        maxEntries: Int,
        maxAgeDays: Int,
        autoPrune: Bool
    ) -> String {
        guard enabled else {
            return "Prompt history is off."
        }

        var limits: [String] = []
        if maxEntries > 0 {
            limits.append("\(maxEntries) entries")
        }
        if maxAgeDays > 0 {
            limits.append("\(maxAgeDays) days")
        }
        let retention = limits.isEmpty ? "unlimited retention" : limits.joined(separator: " and ")
        let pruning = autoPrune ? "auto-prune is on" : "auto-prune is off"
        return "Prompt history is on with \(retention); \(pruning)."
    }

    private static func protectedBranchesDescription(_ count: Int) -> String {
        guard count > 0 else {
            return "No protected branches are configured."
        }
        return "\(count) protected \(count == 1 ? "branch requires" : "branches require") push override."
    }
}

enum ContextSettingsSummary {
    struct Context: Equatable, Sendable {
        let isLoaded: Bool
        let triggerTokenThreshold: Double
        let preserveRecentCount: Int
        let skillsCompactionPolicy: String
        let skillsShowIndex: String
        let autoRetainInterval: Int
        let retainModelDisplayName: String
        let rulesDiscoverStandaloneFiles: Bool
    }

    static func title(for context: Context) -> String {
        guard context.isLoaded else {
            return "Load context settings"
        }
        return "Context management"
    }

    static func description(for context: Context) -> String {
        guard context.isLoaded else {
            return "Loading compaction, memory, skills, and rule discovery settings from the active server."
        }

        let threshold = Int((context.triggerTokenThreshold * 100).rounded())
        let compaction = "Compaction starts at \(threshold)%, keeps \(context.preserveRecentCount) recent \(context.preserveRecentCount == 1 ? "turn" : "turns"), and \(skillsPolicyDescription(context.skillsCompactionPolicy)); the skill index \(skillIndexDescription(context.skillsShowIndex))."
        let memory = memoryDescription(
            interval: context.autoRetainInterval,
            retainModelDisplayName: context.retainModelDisplayName
        )
        let rules = "Standalone rule discovery is \(context.rulesDiscoverStandaloneFiles ? "on" : "off")."
        return "\(compaction) \(memory) \(rules)"
    }

    private static func skillsPolicyDescription(_ value: String) -> String {
        switch value {
        case "autoRestore":
            return "auto-restores active skills"
        case "askUser":
            return "asks before restoring active skills"
        default:
            return "clears active skills"
        }
    }

    private static func skillIndexDescription(_ value: String) -> String {
        switch value {
        case "never":
            return "is hidden"
        case "whenNoActiveSkills":
            return "appears when no skills are active"
        default:
            return "is always visible"
        }
    }

    private static func memoryDescription(interval: Int, retainModelDisplayName: String) -> String {
        guard interval > 0 else {
            return "Memory auto-retain is off."
        }
        return "Memory auto-retain runs every \(interval) \(interval == 1 ? "turn" : "turns") using \(retainModelDisplayName)."
    }
}

enum ProvidersSettingsSummary {
    struct Context: Equatable, Sendable {
        let isLoaded: Bool
        let configuredModelProviderCount: Int
        let totalModelProviderCount: Int
        let configuredServiceCount: Int
        let totalServiceCount: Int
    }

    static func title(for context: Context) -> String {
        guard context.isLoaded else {
            return "Load credential status"
        }

        return "Provider connections"
    }

    static func description(for context: Context) -> String {
        guard context.isLoaded else {
            return "Loading provider and service credential status from the active server."
        }

        let totalConfigured = context.configuredModelProviderCount + context.configuredServiceCount
        guard totalConfigured > 0 else {
            return "No model providers or services are configured. Add OAuth accounts or API keys; secrets stay on the Mac server."
        }

        let modelSummary = countSummary(
            configured: context.configuredModelProviderCount,
            total: context.totalModelProviderCount,
            singular: "model provider",
            plural: "model providers"
        )
        let serviceSummary = countSummary(
            configured: context.configuredServiceCount,
            total: context.totalServiceCount,
            singular: "service",
            plural: "services"
        )
        return sentenceCase("\(modelSummary) and \(serviceSummary) are configured. Secrets stay on the Mac server.")
    }

    private static func countSummary(configured: Int, total: Int, singular: String, plural: String) -> String {
        let noun = configured == 1 ? singular : plural
        if configured == 0 {
            return "0 \(plural)"
        }
        if configured == total {
            return "all \(total) \(plural)"
        }
        return "\(configured) \(noun)"
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}

enum ServerOnboardingLauncher {
    static let serverIdUserInfoKey = "serverId"

    static func userInfo(serverId: String?) -> [String: String] {
        var userInfo: [String: String] = [:]
        if let serverId {
            userInfo[serverIdUserInfoKey] = serverId
        }
        return userInfo
    }

    static func userInfo(prefill server: PairedServer?) -> [String: String] {
        userInfo(serverId: server?.id)
    }

    static func post(prefill server: PairedServer?, notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(
            name: .startServerOnboarding,
            object: nil,
            userInfo: userInfo(prefill: server)
        )
    }
}

enum ConnectionSettingsServerBackedSection: CaseIterable, Hashable, Sendable {
    case transcriptionSidecar
    case updates

    static let loadedOrder: [Self] = [
        .transcriptionSidecar,
        .updates,
    ]

    var title: String {
        switch self {
        case .transcriptionSidecar:
            return SettingsLabels.transcriptionSidecar
        case .updates:
            return SettingsLabels.updates
        }
    }
}

enum ServerUpdateSettingsItem: CaseIterable, Hashable, Sendable {
    case automaticChecks
    case releaseChannel
    case checkFrequency
    case manualCheck

    static let sectionTitle = SettingsLabels.updates

    var title: String {
        switch self {
        case .automaticChecks:
            return "Automatically check for updates"
        case .releaseChannel:
            return "Release channel"
        case .checkFrequency:
            return "Check for updates"
        case .manualCheck:
            return "Check now"
        }
    }

    var icon: String {
        switch self {
        case .automaticChecks:
            return "arrow.down.app"
        case .releaseChannel:
            return "shippingbox"
        case .checkFrequency:
            return "clock.arrow.2.circlepath"
        case .manualCheck:
            return "arrow.clockwise"
        }
    }

    var description: String {
        switch self {
        case .automaticChecks:
            return "When off, the server never contacts GitHub Releases. Opt in to be notified of new versions."
        case .releaseChannel:
            return "Stable tracks only `latest` GitHub releases. Beta also includes pre-release tags, such as `server-v0.1.0-beta.1`."
        case .checkFrequency:
            return "Manual means only the button below and the Mac menu bar fire checks. Startup checks once per server launch."
        case .manualCheck:
            return "Contacts GitHub Releases now regardless of the schedule. Cached 60 seconds server-side to avoid API rate-limit thrash."
        }
    }
}

enum ServerSettingsSummary {
    struct Context: Equatable, Sendable {
        let activeServerLabel: String?
        let pairedServerCount: Int
        let activeServerUnavailable: Bool
        let isLoaded: Bool
        let loadError: String?
        let transcriptionEnabled: Bool
        let updateEnabled: Bool
        let updateChannel: String
        let updateFrequency: String
    }

    static func title(for context: Context) -> String {
        if let label = cleaned(context.activeServerLabel), !label.isEmpty {
            if context.activeServerUnavailable {
                return "\(label) not available"
            }
            return "Manage \(label)"
        }
        return context.pairedServerCount == 0 ? "Connect a Mac" : "Choose a server"
    }

    static func description(for context: Context) -> String {
        guard context.pairedServerCount > 0 else {
            return "Pair a Mac to manage server-backed transcription and update settings from this iPhone."
        }

        guard let label = cleaned(context.activeServerLabel), !label.isEmpty else {
            let count = context.pairedServerCount
            let mac = count == 1 ? "Mac" : "Macs"
            return "Choose one of your \(count) paired \(mac) to load its server-backed settings."
        }

        if context.activeServerUnavailable {
            return SettingsLabels.connectedServerUnavailableDescription
        }

        guard context.isLoaded else {
            if let error = cleaned(context.loadError), !error.isEmpty {
                return "\(label) is paired, but settings are unavailable: \(error)"
            }
            return "\(label) is connected. Loading transcription and update settings."
        }

        let transcription = "Local transcription is \(context.transcriptionEnabled ? "on" : "off")"
        let updates = updateDescription(
            enabled: context.updateEnabled,
            channel: context.updateChannel,
            frequency: context.updateFrequency
        )
        return "\(label) is connected. \(transcription). \(updates)."
    }

    private static func updateDescription(enabled: Bool, channel: String, frequency: String) -> String {
        guard enabled else {
            return "Automatic update checks are off"
        }

        return "Update checks run \(displayFrequency(frequency)) on the \(displayChannel(channel)) channel"
    }

    private static func displayChannel(_ rawValue: String) -> String {
        if let channel = UpdateChannel.from(rawValue) {
            return channel.displayName.lowercased()
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "selected" : trimmed
    }

    private static func displayFrequency(_ rawValue: String) -> String {
        if let frequency = UpdateFrequency.from(rawValue) {
            return frequency.displayName.lowercased()
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "on the selected schedule" : trimmed
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PairedServerRowStatusTone: Equatable, Sendable {
    case success
    case warning
    case muted
}

struct PairedServerMenuEntry: Equatable, Identifiable, Sendable {
    let action: PairedServerMenuAction
    let title: String

    var id: PairedServerMenuAction { action }
    var systemImage: String { action.systemImage }
}

struct PairedServerRowPresentation: Equatable, Sendable {
    let status: String?
    let statusTone: PairedServerRowStatusTone
    let menuEntries: [PairedServerMenuEntry]

    static func resolve(
        isSelected: Bool,
        activeServerUnavailable: Bool,
        lastKnownStatus: String?
    ) -> Self {
        let menuEntries = resolvedMenuEntries(
            isSelected: isSelected,
            activeServerUnavailable: activeServerUnavailable
        )

        if isSelected {
            if activeServerUnavailable {
                return Self(status: "Unavailable", statusTone: .warning, menuEntries: menuEntries)
            }
            return Self(status: "Connected", statusTone: .success, menuEntries: menuEntries)
        }

        if let status = cleaned(lastKnownStatus), !status.isEmpty {
            return Self(
                status: status,
                statusTone: status == "Connected" ? .success : .muted,
                menuEntries: menuEntries
            )
        }

        return Self(status: nil, statusTone: .muted, menuEntries: menuEntries)
    }

    private static func resolvedMenuEntries(
        isSelected: Bool,
        activeServerUnavailable: Bool
    ) -> [PairedServerMenuEntry] {
        if isSelected && activeServerUnavailable {
            return [
                PairedServerMenuEntry(action: .reconnect, title: "Retry"),
                PairedServerMenuEntry(action: .forget, title: PairedServerMenuAction.forget.title),
            ]
        }

        return PairedServerMenuAction.allCases.map {
            PairedServerMenuEntry(action: $0, title: $0.title)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PairedServerMenuAction: CaseIterable, Hashable, Sendable {
    case reconnect
    case setUp
    case forget

    var title: String {
        switch self {
        case .reconnect:
            return "Reconnect"
        case .setUp:
            return "Set Up"
        case .forget:
            return "Forget"
        }
    }

    var systemImage: String {
        switch self {
        case .reconnect:
            return "arrow.clockwise"
        case .setUp:
            return "gearshape.2"
        case .forget:
            return "trash"
        }
    }

    var isDestructive: Bool {
        self == .forget
    }
}

enum PairedServerMenuLayout {
    static let hitTargetSize: CGFloat = 36
}

extension Notification.Name {
    /// Posted by settings and connection repair affordances to open pairing.
    static let startServerOnboarding = Notification.Name("tron.startServerOnboarding")
}
