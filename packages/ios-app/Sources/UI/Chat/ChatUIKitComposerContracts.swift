import Foundation
@preconcurrency import UIKit

/// The complete immutable projection needed by the UIKit composer. It contains
/// presentation facts only; draft and submission ownership remains with
/// ComposerDraftCoordinator/AppModel.
struct ChatUIKitComposerSendIdentity: Equatable, Sendable {
    let sessionID: String
    let submissionID: String

    init?(sessionID: String?, submissionID: String?) {
        guard let sessionID, !sessionID.isEmpty,
              let submissionID, !submissionID.isEmpty else { return nil }
        self.sessionID = sessionID
        self.submissionID = submissionID
    }
}

struct ChatUIKitComposerInput: Equatable {
    let sessionID: String?
    let text: String
    let selection: NSRange
    let revision: Int
    /// Existing ComposerDraftCoordinator admission identity. It is only used
    /// to correlate same-revision authoritative terminal state; it is not a
    /// second receipt store.
    let submissionID: String?
    var sendIdentity: ChatUIKitComposerSendIdentity? {
        ChatUIKitComposerSendIdentity(sessionID: sessionID, submissionID: submissionID)
    }
    let attachments: [PendingAttachment]
    let selectedResource: ComposerResourceEntry?
    let resourcePicker: ComposerResourcePickerSource?
    let resourceResults: [ComposerResourceEntry]
    let reduceMotion: Bool
    let keyboardVisible: Bool
    private(set) var showsCatchUp: Bool
    let showsAmbientWorkingBlur: Bool
    let processOverview: SessionProcessOverview?
    let hasSubagent: Bool
    let contextProgress: SessionContextProgressPresentation
    let trailingMode: ComposerTrailingMode?
    let offersQueueChoices: Bool
    let isSending: Bool
    let submissionPending: Bool
    let hasActiveUploads: Bool
    let isTranscriptReady: Bool
    let isCommandReady: Bool
    let attachmentMenuState: ChatAttachmentMenuState
    let attachmentActionsEnabled: Bool
    let resourcePickerAvailable: Bool
    let isEditable: Bool
    let keyboardAppearance: UIKeyboardAppearance
    let focus: ChatUIKitComposerFocus

    init(
        sessionID: String? = nil,
        text: String = "",
        selection: NSRange = NSRange(location: 0, length: 0),
        revision: Int = 0,
        submissionID: String? = nil,
        attachments: [PendingAttachment] = [],
        selectedResource: ComposerResourceEntry? = nil,
        resourcePicker: ComposerResourcePickerSource? = nil,
        resourceResults: [ComposerResourceEntry] = [],
        reduceMotion: Bool = false,
        keyboardVisible: Bool = false,
        showsCatchUp: Bool = false,
        showsAmbientWorkingBlur: Bool = false,
        processOverview: SessionProcessOverview? = nil,
        hasSubagent: Bool = false,
        contextProgress: SessionContextProgressPresentation = .init(
            contextPercentage: 0,
            modelName: nil,
            isCompacting: false,
            isEnabled: false
        ),
        trailingMode: ComposerTrailingMode? = nil,
        offersQueueChoices: Bool = false,
        isSending: Bool = false,
        submissionPending: Bool = false,
        hasActiveUploads: Bool = false,
        isTranscriptReady: Bool = false,
        isCommandReady: Bool = false,
        attachmentMenuState: ChatAttachmentMenuState = .init(
            sessionID: "",
            phase: nil,
            isTranscriptReady: false,
            isSending: false
        ),
        attachmentActionsEnabled: Bool = false,
        resourcePickerAvailable: Bool = false,
        isEditable: Bool = true,
        keyboardAppearance: UIKeyboardAppearance = .default,
        focus: ChatUIKitComposerFocus = .resigned
    ) {
        self.sessionID = sessionID
        self.text = text
        self.selection = selection
        self.revision = revision
        self.submissionID = submissionID
        self.attachments = attachments
        self.selectedResource = selectedResource
        self.resourcePicker = resourcePicker
        self.resourceResults = resourceResults
        self.reduceMotion = reduceMotion
        self.keyboardVisible = keyboardVisible
        self.showsCatchUp = showsCatchUp
        self.showsAmbientWorkingBlur = showsAmbientWorkingBlur
        self.processOverview = processOverview
        self.hasSubagent = hasSubagent
        self.contextProgress = contextProgress
        self.trailingMode = trailingMode
        self.offersQueueChoices = offersQueueChoices
        self.isSending = isSending
        self.submissionPending = submissionPending
        self.hasActiveUploads = hasActiveUploads
        self.isTranscriptReady = isTranscriptReady
        self.isCommandReady = isCommandReady
        self.attachmentMenuState = attachmentMenuState
        self.attachmentActionsEnabled = attachmentActionsEnabled
        self.resourcePickerAvailable = resourcePickerAvailable
        self.isEditable = isEditable
        self.keyboardAppearance = keyboardAppearance
        self.focus = focus
    }

    func replacingShowsCatchUp(_ visible: Bool) -> Self {
        var copy = self
        copy.showsCatchUp = visible
        return copy
    }
}

enum ChatUIKitComposerFocus: Equatable, Sendable {
    case focused
    case resigned
}

/// Semantic composer output. A host translates these intents to the existing
/// draft, presentation, and viewport authorities; the composer never mutates
/// transcript state or writes a collection-view offset.
enum ChatUIKitComposerIntent: Equatable {
    case textChanged(text: String, selection: NSRange)
    case focusChanged(Bool)
    case send(behavior: String?, identity: ChatUIKitComposerSendIdentity)
    case abort
    case selectAttachmentDestination(ChatAttachmentDestination)
    case previewAttachment(id: String)
    case removeAttachment(id: String)
    case selectResource(ComposerResourceEntry)
    case showResourceDetails(ComposerResourceEntry)
    case removeResource
    case dismissResourcePicker
    case showContext
    case showProcesses
    case catchUp
}

/// Shared native layout facts keep the editor cap deterministic for both the
/// controller and contract tests. TextKit remains the owner of actual glyph
/// measurement and caret scrolling.
enum ChatUIKitComposerLayoutPolicy {
    static let minimumEditorHeight: CGFloat = 20
    static let regularEditorLines = 8

    static func editorLines(panelPresented: Bool, keyboardVisible: Bool) -> Int {
        ComposerResourcePanelPolicy.editorLines(
            panelPresented: panelPresented,
            keyboardVisible: keyboardVisible
        )
    }

    static func editorHeight(
        fittingHeight: CGFloat,
        lineHeight: CGFloat,
        panelPresented: Bool,
        keyboardVisible: Bool
    ) -> CGFloat {
        guard fittingHeight.isFinite, lineHeight.isFinite, lineHeight > 0 else {
            return minimumEditorHeight
        }
        let lines = panelPresented
            ? editorLines(panelPresented: true, keyboardVisible: keyboardVisible)
            : regularEditorLines
        let maximum = ceil(lineHeight * CGFloat(max(lines, 1)))
        return min(max(fittingHeight, ceil(lineHeight)), maximum)
    }
}
