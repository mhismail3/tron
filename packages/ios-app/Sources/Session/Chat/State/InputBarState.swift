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

    var reasoningLevel: String = "medium"

    // MARK: - Clear All

    /// Reset all input state to initial values
    func clear() {
        text = ""
        selectedImages = []
        attachments = []
    }

    /// Clear all pending composer state.
    func clearAll() {
        text = ""
        selectedImages = []
        attachments = []
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
        return hasher.finalize()
    }

    /// Whether there is any draft content worth persisting.
    var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    // MARK: - Computed Properties

    /// Whether there is any content to send
    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

}

/// Why the send button is unavailable, if at all.
///
/// Every reason the input is disabled is enumerated here so the UI
/// can explain it in the disabled-button tooltip instead of leaving the
/// user guessing why tapping does nothing. `nil` from `InputBarConfig.sendBlockReason`
/// means there's no async blocker — the button may still be disabled
/// because the text field is empty, but *that* is user-controllable.
enum SendBlockReason: Equatable, Sendable {
    /// WebSocket isn't connected to the server.
    case disconnected
    /// Context compaction is in progress.
    case compacting
    /// The shared interaction policy currently treats this chat view as read-only.
    case readOnly

    /// User-facing explanation shown in the disabled-button tooltip.
    var description: String {
        switch self {
        case .disconnected: return "Reconnect to the server to send messages."
        case .compacting:   return "Waiting for context compaction to finish…"
        case .readOnly:     return "This conversation is read-only."
        }
    }
}

/// Read-only configuration for the InputBar component
struct InputBarConfig {
    // MARK: - Processing State
    /// Agent lifecycle phase (idle / processing)
    let agentPhase: AgentPhase
    /// Compaction in progress (send blocked, spinning pill shown)
    let isCompacting: Bool
    /// WebSocket connection is live. False during reconnect attempts.
    let isConnected: Bool

    /// Whether the agent is currently processing (convenience).
    var isProcessing: Bool { agentPhase.isProcessing }
    /// Whether composer audio is currently recording.
    let isRecording: Bool
    /// Normalized microphone energy owned by the recorder (0...1).
    let recordingAudioLevel: Double
    /// Whether a captured recording is being transcribed.
    let isTranscribing: Bool

    /// Session Briefing yields its composer slot throughout the authoritative
    /// voice lifecycle so capture/transcription status stays adjacent to the
    /// trailing action.
    var showsContextBriefingControl: Bool {
        !isRecording && !isTranscribing
    }

    /// Voice capture owns the trailing composer action until recording and
    /// transcription have both finished, even when a draft already has text
    /// or attachments.
    func canSend(hasContent: Bool) -> Bool {
        guard agentPhase.isIdle, showsContextBriefingControl else { return false }
        return hasContent && sendBlockReason == nil
    }

    /// Why the send button would be unavailable even with non-empty input.
    /// `nil` means no async blocker; input emptiness is the only remaining gate.
    ///
    /// Evaluation order matters: show the FIRST reason that applies, so
    /// the tooltip names the most specific cause. `readOnly` wins over
    /// everything else (the session fundamentally can't accept input);
    /// `disconnected` over async processing (reconnect would unblock it
    /// regardless of what the server is doing).
    var sendBlockReason: SendBlockReason? {
        if readOnly { return .readOnly }
        if !isConnected { return .disconnected }
        if isCompacting { return .compacting }
        return nil
    }

    // MARK: - Status Display
    /// Placeholder shown when the prompt field is empty and unfocused.
    let placeholderText: String
    /// Whether the placeholder represents a shell-owned loading state.
    let placeholderShowsProgress: Bool
    let contextPercentage: Int

    // MARK: - Model / Attachments
    let currentModelInfo: ModelInfo?

    // MARK: - History
    let inputHistory: InputHistoryStore?

    // MARK: - Misc
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

    init(
        agentPhase: AgentPhase = .idle,
        isCompacting: Bool = false,
        isConnected: Bool = true,
        isRecording: Bool = false,
        recordingAudioLevel: Double = 0,
        isTranscribing: Bool = false,
        placeholderText: String = "Type here",
        placeholderShowsProgress: Bool = false,
        contextPercentage: Int = 0,
        currentModelInfo: ModelInfo? = nil,
        inputHistory: InputHistoryStore? = nil,
        readOnly: Bool = false,
        showDragHint: Bool = false
    ) {
        self.agentPhase = agentPhase
        self.isCompacting = isCompacting
        self.isConnected = isConnected
        self.isRecording = isRecording
        self.recordingAudioLevel = min(max(recordingAudioLevel, 0), 1)
        self.isTranscribing = isTranscribing
        self.placeholderText = placeholderText
        self.placeholderShowsProgress = placeholderShowsProgress
        self.contextPercentage = contextPercentage
        self.currentModelInfo = currentModelInfo
        self.inputHistory = inputHistory
        self.readOnly = readOnly
        self.showDragHint = showDragHint
    }
}

/// Action callbacks for the InputBar component
struct InputBarActions {
    // MARK: - Core Actions
    let onSend: () -> Void
    let onAbort: () -> Void

    // MARK: - Attachments
    let onAddAttachment: (Attachment) -> Void
    let onRemoveAttachment: (Attachment) -> Void
    let onAttachmentError: (String, String) -> Void
    let onMicTap: () -> Void

    // MARK: - History
    let onHistoryNavigate: ((String) -> Void)?

    // MARK: - Context
    let onContextTap: (() -> Void)?

    init(
        onSend: @escaping () -> Void = {},
        onAbort: @escaping () -> Void = {},
        onAddAttachment: @escaping (Attachment) -> Void = { _ in },
        onRemoveAttachment: @escaping (Attachment) -> Void = { _ in },
        onAttachmentError: @escaping (String, String) -> Void = { _, _ in },
        onMicTap: @escaping () -> Void = {},
        onHistoryNavigate: ((String) -> Void)? = nil,
        onContextTap: (() -> Void)? = nil
    ) {
        self.onSend = onSend
        self.onAbort = onAbort
        self.onAddAttachment = onAddAttachment
        self.onRemoveAttachment = onRemoveAttachment
        self.onAttachmentError = onAttachmentError
        self.onMicTap = onMicTap
        self.onHistoryNavigate = onHistoryNavigate
        self.onContextTap = onContextTap
    }
}
