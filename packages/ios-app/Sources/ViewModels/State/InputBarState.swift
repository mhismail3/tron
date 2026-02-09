import Foundation
import PhotosUI
import SwiftUI

/// Mutable state for the InputBar component
/// Consolidates all @Binding properties into a single observable object
@Observable
final class InputBarState {
    // MARK: - Text Input
    var text: String = ""

    // MARK: - Media Selection
    var selectedImages: [PhotosPickerItem] = []
    var attachments: [Attachment] = []

    // MARK: - Skills and Spells
    var selectedSkills: [Skill] = []
    var selectedSpells: [Skill] = []

    // MARK: - Recording
    var reasoningLevel: String = "medium"

    // MARK: - Clear All

    /// Reset all input state to initial values
    func clear() {
        text = ""
        selectedImages = []
        attachments = []
        // Note: skills and spells are NOT cleared - they persist across messages
    }

    /// Clear everything including skills and spells
    func clearAll() {
        text = ""
        selectedImages = []
        attachments = []
        selectedSkills = []
        selectedSpells = []
    }

    // MARK: - Computed Properties

    /// Whether there is any content to send
    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}

/// Read-only configuration for the InputBar component
struct InputBarConfig {
    // MARK: - Processing State
    /// Agent lifecycle phase (idle / processing / postProcessing)
    let agentPhase: AgentPhase
    /// Compaction in progress (send blocked, spinning pill shown)
    let isCompacting: Bool

    /// Whether the agent is currently processing (convenience).
    var isProcessing: Bool { agentPhase.isProcessing }
    /// Whether background hooks are running after completion (convenience).
    var isPostProcessing: Bool { agentPhase.isPostProcessing }
    let isRecording: Bool
    let isTranscribing: Bool

    // MARK: - Status Display
    let modelName: String
    let tokenUsage: TokenUsage?
    let contextPercentage: Int
    let contextWindow: Int
    let lastTurnInputTokens: Int

    // MARK: - Model Picker
    let cachedModels: [ModelInfo]
    let isLoadingModels: Bool
    let currentModelInfo: ModelInfo?

    // MARK: - Skills
    let skillStore: SkillStore?

    // MARK: - History
    let inputHistory: InputHistoryStore?

    // MARK: - Misc
    let animationCoordinator: AnimationCoordinator?
    let readOnly: Bool

    init(
        agentPhase: AgentPhase = .idle,
        isCompacting: Bool = false,
        isRecording: Bool = false,
        isTranscribing: Bool = false,
        modelName: String = "",
        tokenUsage: TokenUsage? = nil,
        contextPercentage: Int = 0,
        contextWindow: Int = 0,
        lastTurnInputTokens: Int = 0,
        cachedModels: [ModelInfo] = [],
        isLoadingModels: Bool = false,
        currentModelInfo: ModelInfo? = nil,
        skillStore: SkillStore? = nil,
        inputHistory: InputHistoryStore? = nil,
        animationCoordinator: AnimationCoordinator? = nil,
        readOnly: Bool = false
    ) {
        self.agentPhase = agentPhase
        self.isCompacting = isCompacting
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing
        self.modelName = modelName
        self.tokenUsage = tokenUsage
        self.contextPercentage = contextPercentage
        self.contextWindow = contextWindow
        self.lastTurnInputTokens = lastTurnInputTokens
        self.cachedModels = cachedModels
        self.isLoadingModels = isLoadingModels
        self.currentModelInfo = currentModelInfo
        self.skillStore = skillStore
        self.inputHistory = inputHistory
        self.animationCoordinator = animationCoordinator
        self.readOnly = readOnly
    }
}

/// Action callbacks for the InputBar component
struct InputBarActions {
    // MARK: - Core Actions
    let onSend: () -> Void
    let onAbort: () -> Void
    let onMicTap: () -> Void

    // MARK: - Attachments
    let onAddAttachment: (Attachment) -> Void
    let onRemoveAttachment: (Attachment) -> Void

    // MARK: - History
    let onHistoryNavigate: ((String) -> Void)?

    // MARK: - Model/Reasoning
    let onModelSelect: ((ModelInfo) -> Void)?
    let onReasoningLevelChange: ((String) -> Void)?

    // MARK: - Context
    let onContextTap: (() -> Void)?

    // MARK: - Model Picker Sheet
    let onModelPickerTap: (() -> Void)?

    // MARK: - Skills
    let onSkillSelect: ((Skill) -> Void)?
    let onSkillRemove: ((Skill) -> Void)?
    let onSkillDetailTap: ((Skill) -> Void)?

    // MARK: - Spells
    let onSpellRemove: ((Skill) -> Void)?
    let onSpellDetailTap: ((Skill) -> Void)?

    init(
        onSend: @escaping () -> Void = {},
        onAbort: @escaping () -> Void = {},
        onMicTap: @escaping () -> Void = {},
        onAddAttachment: @escaping (Attachment) -> Void = { _ in },
        onRemoveAttachment: @escaping (Attachment) -> Void = { _ in },
        onHistoryNavigate: ((String) -> Void)? = nil,
        onModelSelect: ((ModelInfo) -> Void)? = nil,
        onReasoningLevelChange: ((String) -> Void)? = nil,
        onContextTap: (() -> Void)? = nil,
        onModelPickerTap: (() -> Void)? = nil,
        onSkillSelect: ((Skill) -> Void)? = nil,
        onSkillRemove: ((Skill) -> Void)? = nil,
        onSkillDetailTap: ((Skill) -> Void)? = nil,
        onSpellRemove: ((Skill) -> Void)? = nil,
        onSpellDetailTap: ((Skill) -> Void)? = nil
    ) {
        self.onSend = onSend
        self.onAbort = onAbort
        self.onMicTap = onMicTap
        self.onAddAttachment = onAddAttachment
        self.onRemoveAttachment = onRemoveAttachment
        self.onHistoryNavigate = onHistoryNavigate
        self.onModelSelect = onModelSelect
        self.onReasoningLevelChange = onReasoningLevelChange
        self.onContextTap = onContextTap
        self.onModelPickerTap = onModelPickerTap
        self.onSkillSelect = onSkillSelect
        self.onSkillRemove = onSkillRemove
        self.onSkillDetailTap = onSkillDetailTap
        self.onSpellRemove = onSpellRemove
        self.onSpellDetailTap = onSpellDetailTap
    }
}
