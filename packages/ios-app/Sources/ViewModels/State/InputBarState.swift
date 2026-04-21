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

    // MARK: - Skills
    var selectedSkills: [Skill] = []

    // MARK: - Mention Popups
    var isMentionPopupVisible: Bool = false

    // MARK: - Recording
    var reasoningLevel: String = "medium"

    // MARK: - Clear All

    /// Reset all input state to initial values
    func clear() {
        text = ""
        selectedImages = []
        attachments = []
        // Note: skills are NOT cleared - they persist across messages
    }

    /// Clear everything including skills
    func clearAll() {
        text = ""
        selectedImages = []
        attachments = []
        selectedSkills = []
    }

    /// Remove attachments incompatible with the given capability.
    /// Returns count of removed attachments.
    @discardableResult
    func removeIncompatibleAttachments(for capability: AttachmentCapability) -> Int {
        let before = attachments.count
        attachments.removeAll { !$0.isCompatible(with: capability) }
        return before - attachments.count
    }

    // MARK: - Draft Persistence

    /// Lightweight fingerprint for draft-relevant state.
    /// Used by ChatView to trigger debounced draft saves via `.onChange`.
    var draftFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(attachments.map(\.id))
        hasher.combine(selectedSkills.map(\.name))
        return hasher.finalize()
    }

    /// Whether there is any draft content worth persisting.
    var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !selectedSkills.isEmpty
    }

    // MARK: - Computed Properties

    /// Whether there is any content to send
    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Whether there is text content (ignoring attachments).
    /// Used for queue-eligible sends during processing.
    var hasTextContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Why the send button is unavailable, if at all.
///
/// H9: every reason the input is disabled is enumerated here so the UI
/// can explain it in the disabled-button tooltip instead of leaving the
/// user guessing why tapping does nothing. `nil` from `InputBarConfig.sendBlockReason`
/// means there's no async blocker — the button may still be disabled
/// because the text field is empty, but *that* is user-controllable.
enum SendBlockReason: Equatable, Sendable {
    /// WebSocket isn't connected to the server.
    case disconnected
    /// Context compaction is in progress.
    case compacting
    /// Memory retention summarizer is running.
    case retaining
    /// This chat view is read-only (shared, workspace deleted, etc.).
    case readOnly

    /// User-facing explanation shown in the disabled-button tooltip.
    var description: String {
        switch self {
        case .disconnected: return "Reconnect to the server to send messages."
        case .compacting:   return "Waiting for context compaction to finish…"
        case .retaining:    return "Waiting for memory retention to finish…"
        case .readOnly:     return "This conversation is read-only."
        }
    }
}

/// Read-only configuration for the InputBar component
struct InputBarConfig {
    // MARK: - Processing State
    /// Agent lifecycle phase (idle / processing / postProcessing)
    let agentPhase: AgentPhase
    /// Compaction in progress (send blocked, spinning pill shown)
    let isCompacting: Bool
    /// Memory retention summarizer in progress (send blocked).
    let isRetaining: Bool
    /// WebSocket connection is live. False during reconnect attempts.
    let isConnected: Bool

    /// Whether the agent is currently processing (convenience).
    var isProcessing: Bool { agentPhase.isProcessing }
    /// Whether background hooks are running after completion (convenience).
    var isPostProcessing: Bool { agentPhase.isPostProcessing }
    let isRecording: Bool
    let isTranscribing: Bool

    /// Why the send button would be unavailable even with non-empty input.
    /// `nil` means no async blocker; input emptiness is the only remaining gate.
    ///
    /// Evaluation order matters: show the FIRST reason that applies, so
    /// the tooltip names the most specific cause. `readOnly` wins over
    /// everything else (the session fundamentally can't accept input);
    /// `disconnected` over async processing (reconnect would unblock it
    /// regardless of what the server is doing); compaction over retain
    /// (users see the compaction pill more prominently).
    var sendBlockReason: SendBlockReason? {
        if readOnly { return .readOnly }
        if !isConnected { return .disconnected }
        if isCompacting { return .compacting }
        if isRetaining { return .retaining }
        return nil
    }

    // MARK: - Status Display
    let tokenUsage: TokenUsage?
    let contextPercentage: Int
    let contextWindow: Int
    let lastTurnInputTokens: Int

    // MARK: - Model / Attachments
    let currentModelInfo: ModelInfo?

    // MARK: - Skills
    let skillStore: SkillStore?

    // MARK: - History
    let inputHistory: InputHistoryStore?

    // MARK: - Misc
    let animationCoordinator: AnimationCoordinator?
    let readOnly: Bool

    // MARK: - Attachment Limits
    /// Provider-specific image processing limits derived from current model.
    var providerImageLimits: ProviderImageLimits {
        currentModelInfo?.providerImageLimits ?? .default
    }
    /// Attachment capability derived from current model.
    var attachmentCapability: AttachmentCapability {
        AttachmentCapability.from(model: currentModelInfo)
    }

    // MARK: - Drag Hint
    /// Show the chevron-up drag hint above the input row (hold gesture active).
    let showDragHint: Bool

    // MARK: - Message Queue (Server-Driven)
    /// Pending queued messages from the server. Drives the pill chips UI.
    let queuedMessages: [PendingQueueItem]

    init(
        agentPhase: AgentPhase = .idle,
        isCompacting: Bool = false,
        isRetaining: Bool = false,
        isConnected: Bool = true,
        isRecording: Bool = false,
        isTranscribing: Bool = false,
        tokenUsage: TokenUsage? = nil,
        contextPercentage: Int = 0,
        contextWindow: Int = 0,
        lastTurnInputTokens: Int = 0,
        currentModelInfo: ModelInfo? = nil,
        skillStore: SkillStore? = nil,
        inputHistory: InputHistoryStore? = nil,
        animationCoordinator: AnimationCoordinator? = nil,
        readOnly: Bool = false,
        showDragHint: Bool = false,
        queuedMessages: [PendingQueueItem] = []
    ) {
        self.agentPhase = agentPhase
        self.isCompacting = isCompacting
        self.isRetaining = isRetaining
        self.isConnected = isConnected
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing
        self.tokenUsage = tokenUsage
        self.contextPercentage = contextPercentage
        self.contextWindow = contextWindow
        self.lastTurnInputTokens = lastTurnInputTokens
        self.currentModelInfo = currentModelInfo
        self.skillStore = skillStore
        self.inputHistory = inputHistory
        self.animationCoordinator = animationCoordinator
        self.readOnly = readOnly
        self.showDragHint = showDragHint
        self.queuedMessages = queuedMessages
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

    // MARK: - Context
    let onContextTap: (() -> Void)?

    // MARK: - Skills
    let onSkillSelect: ((Skill) -> Void)?
    let onSkillRemove: ((Skill) -> Void)?
    let onSkillDetailTap: ((Skill) -> Void)?

    // MARK: - Message Queue (Server-Driven)
    let onQueueRemove: ((String) -> Void)?

    init(
        onSend: @escaping () -> Void = {},
        onAbort: @escaping () -> Void = {},
        onMicTap: @escaping () -> Void = {},
        onAddAttachment: @escaping (Attachment) -> Void = { _ in },
        onRemoveAttachment: @escaping (Attachment) -> Void = { _ in },
        onHistoryNavigate: ((String) -> Void)? = nil,
        onContextTap: (() -> Void)? = nil,
        onSkillSelect: ((Skill) -> Void)? = nil,
        onSkillRemove: ((Skill) -> Void)? = nil,
        onSkillDetailTap: ((Skill) -> Void)? = nil,
        onQueueRemove: ((String) -> Void)? = nil
    ) {
        self.onSend = onSend
        self.onAbort = onAbort
        self.onMicTap = onMicTap
        self.onAddAttachment = onAddAttachment
        self.onRemoveAttachment = onRemoveAttachment
        self.onHistoryNavigate = onHistoryNavigate
        self.onContextTap = onContextTap
        self.onSkillSelect = onSkillSelect
        self.onSkillRemove = onSkillRemove
        self.onSkillDetailTap = onSkillDetailTap
        self.onQueueRemove = onQueueRemove
    }
}
