import Foundation
import PhotosUI
import SwiftUI

/// Mutable state for the InputBar component
/// Consolidates all @Binding properties into a single observable object
@Observable
final class InputBarState {
    // MARK: - Text Input
    var text: String = ""
    /// One-shot presentation intent for externally prepared drafts. This is
    /// not draft content and therefore never participates in persistence or
    /// send admission.
    var textEndRevealRevision: UInt64 = 0

    func requestTextEndReveal() {
        textEndRevealRevision &+= 1
    }

    // MARK: - Media Selection
    var selectedImages: [PhotosPickerItem] = []
    var attachments: [Attachment] = []

    var reasoningLevel: String = "medium"

    /// Remove attachments incompatible with the given tool.
    /// Returns count of removed attachments.
    @discardableResult
    func removeIncompatibleAttachments(for tool: AttachmentSupport) -> Int {
        let before = attachments.count
        attachments.removeAll { !$0.isCompatible(with: tool) }
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

    // MARK: - Computed Properties

    /// Whether there is any content to send or persist as a draft.
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
    /// This presentation does not permit session mutation.
    case readOnly
    /// Cached content is visible, but the authoritative session cut is not ready.
    case historySynchronizing
    /// No usable authoritative or cached conversation could be loaded yet.
    case historyUnavailable

    /// User-facing explanation shown in the disabled-button tooltip.
    var description: String {
        switch self {
        case .disconnected: return "Reconnect to the server to send messages."
        case .compacting:   return "Waiting for context compaction to finish…"
        case .readOnly:     return "This conversation is read-only."
        case .historySynchronizing: return "Waiting for conversation sync."
        case .historyUnavailable: return "Conversation history is unavailable."
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
    /// Native composer capture is active.
    let isRecording: Bool
    /// Smoothed normalized microphone energy (0...1).
    let recordingAudioLevel: Double
    /// Captured audio is being processed by the speech worker.
    let isTranscribing: Bool
    /// A healthy enabled worker owns the validated speech client action.
    let speechTranscriptionAvailable: Bool

    var showsContextBriefingControl: Bool {
        !isRecording && !isTranscribing
    }

    func canSend(hasContent: Bool) -> Bool {
        guard allowsSubmission, agentPhase.isIdle, showsContextBriefingControl else { return false }
        return hasContent && sendBlockReason == nil
    }

    /// Why the send button would be unavailable even with non-empty input.
    /// `nil` means no async blocker; input emptiness is the only remaining gate.
    ///
    /// Evaluation order matters: presentation and history authority win over
    /// transport state because reconnecting alone cannot make either writable.
    var sendBlockReason: SendBlockReason? {
        if readOnly { return .readOnly }
        if !allowsSubmission {
            return availabilityBlockReason ?? .historyUnavailable
        }
        if let availabilityBlockReason { return availabilityBlockReason }
        if !isConnected { return .disconnected }
        if isCompacting { return .compacting }
        return nil
    }

    /// Attachment selection edits only the local draft. It remains available
    /// while the transport reconnects or cached history is being verified.
    var attachmentSelectionDisabled: Bool {
        readOnly || agentPhase.isActive || !allowsAttachments
    }

    var attachmentBlockReason: SendBlockReason? {
        guard attachmentSelectionDisabled else { return nil }
        if readOnly { return .readOnly }
        if !allowsAttachments {
            return availabilityBlockReason ?? .historyUnavailable
        }
        return nil
    }

    /// Recording is a local draft actuator, but transcription requires the
    /// live worker transport. An active recording must always remain stoppable.
    var speechCaptureDisabled: Bool {
        if isRecording { return false }
        return readOnly
            || !allowsSpeechCapture
            || agentPhase.isActive
            || isTranscribing
            || !isConnected
    }

    var speechCaptureBlockReason: SendBlockReason? {
        guard speechCaptureDisabled else { return nil }
        if readOnly { return .readOnly }
        if !allowsSpeechCapture {
            return availabilityBlockReason ?? .historyUnavailable
        }
        if !isConnected { return .disconnected }
        return nil
    }

    // MARK: - Status Display
    /// Placeholder shown when the prompt field is empty and unfocused.
    let placeholderText: String
    /// Whether the placeholder represents a shell-owned loading state.
    let placeholderShowsProgress: Bool
    /// Server-derived percentage of the selected model's context window in use.
    let contextPercentage: Int

    // MARK: - Model / Attachments
    let currentModelInfo: ModelInfo?

    // MARK: - History
    let inputHistory: InputHistoryStore?

    // MARK: - Misc
    let readOnly: Bool
    /// Draft text can remain editable even while server-mutating actions wait.
    let allowsTextEntry: Bool
    /// Attachment selection is visible in interactive chats but independently gated.
    let allowsAttachments: Bool
    /// Speech capture is draft-local and does not require an authoritative history cut.
    let allowsSpeechCapture: Bool
    /// Only server submission requires an authoritative history cut.
    let allowsSubmission: Bool
    /// History-specific explanation for an unavailable interactive action.
    let availabilityBlockReason: SendBlockReason?

    // MARK: - Attachment Limits
    /// Provider-specific image processing limits derived from current model.
    var providerImageLimits: ProviderImageLimits {
        currentModelInfo?.providerImageLimits ?? .default
    }
    /// Attachment tool derived from current model.
    var attachmentSupport: AttachmentSupport {
        AttachmentSupport.from(model: currentModelInfo)
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
        speechTranscriptionAvailable: Bool = false,
        placeholderText: String = "Type here",
        placeholderShowsProgress: Bool = false,
        contextPercentage: Int = 0,
        currentModelInfo: ModelInfo? = nil,
        inputHistory: InputHistoryStore? = nil,
        readOnly: Bool = false,
        allowsTextEntry: Bool = true,
        allowsAttachments: Bool = true,
        allowsSpeechCapture: Bool = true,
        allowsSubmission: Bool = true,
        availabilityBlockReason: SendBlockReason? = nil,
        showDragHint: Bool = false
    ) {
        self.agentPhase = agentPhase
        self.isCompacting = isCompacting
        self.isConnected = isConnected
        self.isRecording = isRecording
        self.recordingAudioLevel = min(max(recordingAudioLevel, 0), 1)
        self.isTranscribing = isTranscribing
        self.speechTranscriptionAvailable = speechTranscriptionAvailable
        self.placeholderText = placeholderText
        self.placeholderShowsProgress = placeholderShowsProgress
        self.contextPercentage = contextPercentage
        self.currentModelInfo = currentModelInfo
        self.inputHistory = inputHistory
        self.readOnly = readOnly
        self.allowsTextEntry = allowsTextEntry
        self.allowsAttachments = allowsAttachments
        self.allowsSpeechCapture = allowsSpeechCapture
        self.allowsSubmission = allowsSubmission
        self.availabilityBlockReason = availabilityBlockReason
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
    /// Starts or stops the native capture actuator. The captured audio is
    /// routed through the current speech worker by the chat view model.
    let onMicTap: () -> Void
    // MARK: - History
    let onHistoryNavigate: ((String) -> Void)?

    // MARK: - Session Context
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
