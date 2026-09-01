import Foundation
@preconcurrency import UIKit

/// The complete immutable projection needed by the UIKit composer. It contains
/// presentation facts only; draft and submission ownership remains with
/// ComposerDraftCoordinator/AppModel.
struct ChatUIKitComposerInput {
    let sessionID: String?
    let text: String
    let selection: NSRange
    let revision: Int
    let attachments: [PendingAttachment]
    let selectedResource: ComposerResourceEntry?
    let resourcePicker: ComposerResourcePickerSource?
    let resourceResults: [ComposerResourceEntry]
    let reduceMotion: Bool
    let keyboardVisible: Bool
    let showsCatchUp: Bool
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
    case send(behavior: String?)
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

@MainActor
final class ChatUIKitComposerController: UIViewController, UITextViewDelegate,
    UIContextMenuInteractionDelegate {
    typealias IntentHandler = @MainActor (ChatUIKitComposerIntent) -> Void

    private(set) var input: ChatUIKitComposerInput?
    private(set) var appliedRevision: Int?
    var onIntent: IntentHandler?

    private let rootStack = UIStackView()
    private let attachmentScroll = UIScrollView()
    private let attachmentStack = UIStackView()
    private let resourceScroll = UIScrollView()
    private let resourceStack = UIStackView()
    private let resourcePickerView = ChatUIKitResourcePickerView()
    private let bar = ChatUIKitComposerSurface()
    private let barStack = UIStackView()
    private let attachmentButton = UIButton(type: .system)
    private let editorContainer = UIView()
    private let editor = ChatUIKitComposerEditor()
    private let placeholder = UILabel()
    private let contextButton = ChatUIKitComposerContextButton()
    private let processButton = UIButton(type: .system)
    private let catchUpButton = UIButton(type: .system)
    private let trailingButton = UIButton(type: .system)
    private let trailingSpinner = UIActivityIndicatorView(style: .medium)
    private var editorHeight: NSLayoutConstraint?
    private var sendHandoffRevision: Int?
    private var sendHandoffAccepted = false
    private var sendHandoffTimeout: Task<Void, Never>?
    private var applyingAuthoritativeInput = false
    private var keyboardObservers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureStacks()
        configureEditor()
        configureButtons()
        configurePicker()
        installKeyboardObservers()
    }

    /// Installs a new authoritative projection. This is the only input path;
    /// local UI events are emitted as intents and are never merged into it.
    @discardableResult
    func apply(_ next: ChatUIKitComposerInput) -> Bool {
        if let appliedRevision, next.revision <= appliedRevision {
            return false
        }
        if let prior = input, prior.revision != next.revision {
            clearSendHandoff()
        }
        if sendHandoffRevision == next.revision,
           next.isSending || next.submissionPending {
            sendHandoffAccepted = true
            sendHandoffTimeout?.cancel()
            sendHandoffTimeout = nil
        }
        input = next
        applyingAuthoritativeInput = true
        configureEditorFromInput(next)
        switch next.focus {
        case .focused:
            if next.isEditable, !editor.isFirstResponder { editor.becomeFirstResponder() }
        case .resigned:
            if editor.isFirstResponder { editor.resignFirstResponder() }
        }
        applyingAuthoritativeInput = false
        configureAttachments(next)
        configureResource(next)
        configureButtonsFromInput(next)
        updateEditorHeight()
        updateAccessibilityOrder()
        appliedRevision = next.revision
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateEditorHeight()
    }

    private func configureStacks() {
        rootStack.axis = .vertical
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])

        for scroll in [attachmentScroll, resourceScroll] {
            scroll.showsHorizontalScrollIndicator = false
            scroll.alwaysBounceVertical = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
        attachmentStack.axis = .horizontal
        attachmentStack.spacing = 8
        attachmentStack.alignment = .center
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.addSubview(attachmentStack)
        NSLayoutConstraint.activate([
            attachmentStack.leadingAnchor.constraint(equalTo: attachmentScroll.leadingAnchor),
            attachmentStack.trailingAnchor.constraint(equalTo: attachmentScroll.trailingAnchor),
            attachmentStack.topAnchor.constraint(equalTo: attachmentScroll.topAnchor, constant: 2),
            attachmentStack.bottomAnchor.constraint(equalTo: attachmentScroll.bottomAnchor, constant: -2),
            attachmentStack.heightAnchor.constraint(equalToConstant: 64)
        ])

        resourceStack.axis = .horizontal
        resourceStack.spacing = 8
        resourceStack.translatesAutoresizingMaskIntoConstraints = false
        resourceScroll.addSubview(resourceStack)
        NSLayoutConstraint.activate([
            resourceStack.leadingAnchor.constraint(equalTo: resourceScroll.leadingAnchor),
            resourceStack.trailingAnchor.constraint(equalTo: resourceScroll.trailingAnchor),
            resourceStack.topAnchor.constraint(equalTo: resourceScroll.topAnchor, constant: 2),
            resourceStack.bottomAnchor.constraint(equalTo: resourceScroll.bottomAnchor, constant: -2),
            resourceStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])

        bar.translatesAutoresizingMaskIntoConstraints = false
        barStack.axis = .horizontal
        barStack.alignment = .bottom
        barStack.spacing = 4
        barStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barStack)
        NSLayoutConstraint.activate([
            barStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            barStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
            barStack.topAnchor.constraint(equalTo: bar.topAnchor),
            barStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        rootStack.addArrangedSubview(attachmentScroll)
        rootStack.addArrangedSubview(resourceScroll)
        rootStack.addArrangedSubview(bar)
    }

    private func configureEditor() {
        editor.delegate = self
        editor.backgroundColor = .clear
        editor.textColor = ChatUIKitComposerColors.emerald
        editor.tintColor = ChatUIKitComposerColors.emerald
        editor.font = ChatUIKitComposerFonts.input
        editor.adjustsFontForContentSizeCategory = true
        editor.textContainerInset = .zero
        editor.textContainer.lineFragmentPadding = 0
        editor.isScrollEnabled = false
        editor.keyboardDismissMode = .interactive
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "Type here"
        placeholder.font = ChatUIKitComposerFonts.input
        placeholder.textColor = ChatUIKitComposerColors.emerald
        placeholder.alpha = 1
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(placeholder)
        editorContainer.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor, constant: 2),
            editor.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor, constant: -2),
            editor.topAnchor.constraint(equalTo: editorContainer.topAnchor, constant: 10),
            editor.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: -10),
            placeholder.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: editor.trailingAnchor),
            placeholder.centerYAnchor.constraint(equalTo: editor.centerYAnchor)
        ])
        editor.accessibilityLabel = "Message input"
        editor.accessibilityHint = "Enter a message to send to Tron"
        barStack.addArrangedSubview(processButton)
        barStack.addArrangedSubview(attachmentButton)
        barStack.addArrangedSubview(editorContainer)
        barStack.addArrangedSubview(contextButton)
        barStack.addArrangedSubview(trailingButton)
        barStack.addArrangedSubview(catchUpButton)
        for control in [processButton, attachmentButton, contextButton, trailingButton, catchUpButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: ComposerControlMetrics.hitTarget).isActive = true
            control.heightAnchor.constraint(equalToConstant: ComposerControlMetrics.hitTarget).isActive = true
        }
        editorHeight = editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        editorHeight?.isActive = true
        editorContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureButtons() {
        attachmentButton.setImage(UIImage(systemName: "plus"), for: .normal)
        attachmentButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(
                pointSize: ComposerControlMetrics.symbolSize,
                weight: .semibold
            ),
            forImageIn: .normal
        )
        attachmentButton.accessibilityLabel = "Add attachment"
        attachmentButton.showsMenuAsPrimaryAction = true

        contextButton.addTarget(self, action: #selector(contextPressed), for: .primaryActionTriggered)
        processButton.setImage(UIImage(systemName: "person.2"), for: .normal)
        processButton.accessibilityLabel = "Subagents"
        processButton.addTarget(self, action: #selector(processesPressed), for: .primaryActionTriggered)
        catchUpButton.setImage(UIImage(systemName: "arrow.down"), for: .normal)
        catchUpButton.accessibilityLabel = "Catch up"
        catchUpButton.accessibilityHint = "Returns to the latest response and follows new messages"
        catchUpButton.addTarget(self, action: #selector(catchUpPressed), for: .primaryActionTriggered)
        trailingButton.addTarget(self, action: #selector(trailingPressed), for: .primaryActionTriggered)
        trailingButton.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func configurePicker() {
        resourcePickerView.onSelect = { [weak self] entry in
            self?.onIntent?(.selectResource(entry))
        }
        resourcePickerView.onDetails = { [weak self] entry in
            self?.onIntent?(.showResourceDetails(entry))
        }
        resourcePickerView.onDismiss = { [weak self] in
            self?.onIntent?(.dismissResourcePicker)
        }
    }

    private func installKeyboardObservers() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.view.setNeedsLayout()
                    self.view.layoutIfNeeded()
                }
            })
        }
    }

    deinit {
        sendHandoffTimeout?.cancel()
    }

    /// The host must resolve the terminal admission explicitly. Rejected sends
    /// release the same revision for retry; accepted sends remain suppressed
    /// until a new authoritative revision arrives.
    func resolveSend(revision: Int, accepted: Bool) {
        guard sendHandoffRevision == revision else { return }
        if accepted {
            sendHandoffAccepted = true
            sendHandoffTimeout?.cancel()
            sendHandoffTimeout = nil
        } else {
            clearSendHandoff()
        }
    }

    private func clearSendHandoff() {
        sendHandoffRevision = nil
        sendHandoffAccepted = false
        sendHandoffTimeout?.cancel()
        sendHandoffTimeout = nil
    }

    private func configureEditorFromInput(_ next: ChatUIKitComposerInput) {
        editor.isEditable = next.isEditable
        editor.isSelectable = next.isEditable
        editor.keyboardAppearance = next.keyboardAppearance
        if editor.text != next.text {
            editor.text = next.text
        }
        let length = (next.text as NSString).length
        let location = min(max(next.selection.location, 0), length)
        let selectionLength = min(max(next.selection.length, 0), length - location)
        editor.selectedRange = NSRange(location: location, length: selectionLength)
        placeholder.isHidden = !next.text.isEmpty || editor.isFirstResponder
        placeholder.alpha = next.isTranscriptReady ? 1 : 0.38
    }

    private func configureAttachments(_ next: ChatUIKitComposerInput) {
        clearArrangedSubviews(attachmentStack)
        for attachment in next.attachments {
            let chip = ChatUIKitComposerAttachmentChip(attachment: attachment)
            chip.onPreview = { [weak self] in self?.onIntent?(.previewAttachment(id: attachment.id)) }
            chip.onRemove = { [weak self] in self?.onIntent?(.removeAttachment(id: attachment.id)) }
            attachmentStack.addArrangedSubview(chip)
        }
        let height = next.attachments.isEmpty ? 0 : 68
        attachmentScroll.constraints.first { $0.firstAttribute == .height }?.constant = CGFloat(height)
        attachmentScroll.isHidden = next.attachments.isEmpty
    }

    private func configureResource(_ next: ChatUIKitComposerInput) {
        clearArrangedSubviews(resourceStack)
        if let resource = next.selectedResource {
            let chip = ChatUIKitComposerResourceChip(resource: resource)
            chip.onDetails = { [weak self] in self?.onIntent?(.showResourceDetails(resource)) }
            chip.onRemove = { [weak self] in self?.onIntent?(.removeResource) }
            resourceStack.addArrangedSubview(chip)
        }
        resourceScroll.isHidden = next.selectedResource == nil
        resourceScroll.constraints.first { $0.firstAttribute == .height }?.constant = next.selectedResource == nil ? 0 : 40

        resourcePickerView.apply(
            kind: next.resourcePicker?.kind,
            query: next.resourcePicker?.query ?? "",
            entries: next.resourceResults,
            keyboardVisible: next.keyboardVisible,
            reduceMotion: next.reduceMotion
        )
        if next.resourcePicker == nil {
            if resourcePickerView.superview != nil { resourcePickerView.removeFromSuperview() }
        } else if resourcePickerView.superview == nil {
            rootStack.insertArrangedSubview(resourcePickerView, at: 2)
        }
    }

    private func configureButtonsFromInput(_ next: ChatUIKitComposerInput) {
        attachmentButton.isEnabled = next.attachmentActionsEnabled
        attachmentButton.tintColor = next.attachmentActionsEnabled
            ? ChatUIKitComposerColors.emerald : ChatUIKitComposerColors.muted
        attachmentButton.menu = makeAttachmentMenu(next)

        contextButton.apply(next.contextProgress, reduceMotion: next.reduceMotion)
        processButton.isHidden = !(next.hasSubagent && next.processOverview?.visibility != .hidden)
        processButton.tintColor = ChatUIKitComposerColors.emerald
        processButton.accessibilityValue = next.processOverview.map { overview in
            var values: [String] = []
            if overview.activeCount > 0 { values.append("\(overview.activeCount) active") }
            if overview.recentCount > 0 { values.append("\(overview.recentCount) recently finished") }
            if overview.problemCount > 0 { values.append("\(overview.problemCount) with problems") }
            return values.joined(separator: ", ")
        }
        catchUpButton.isHidden = !next.showsCatchUp
        catchUpButton.tintColor = ChatUIKitComposerColors.emerald
        trailingButton.isHidden = next.trailingMode == nil
        trailingButton.isEnabled = next.trailingMode == .stopAgent
            || !(next.isSending || next.submissionPending || next.hasActiveUploads || !next.isCommandReady)
        trailingButton.tintColor = next.trailingMode == .stopAgent
            ? ChatUIKitComposerColors.error : ChatUIKitComposerColors.emerald
        if next.trailingMode == .send, next.isSending {
            trailingButton.setImage(nil, for: .normal)
            trailingSpinner.color = ChatUIKitComposerColors.emerald
            trailingSpinner.startAnimating()
            if trailingSpinner.superview == nil {
                trailingButton.addSubview(trailingSpinner)
                trailingSpinner.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    trailingSpinner.centerXAnchor.constraint(equalTo: trailingButton.centerXAnchor),
                    trailingSpinner.centerYAnchor.constraint(equalTo: trailingButton.centerYAnchor)
                ])
            }
        } else {
            trailingSpinner.stopAnimating()
            trailingSpinner.removeFromSuperview()
            let imageName = next.trailingMode == .stopAgent ? "stop.fill" : "arrow.up.circle.fill"
            trailingButton.setImage(UIImage(systemName: imageName), for: .normal)
        }
        trailingButton.accessibilityLabel = next.trailingMode == .stopAgent
            ? "Stop Tron" : next.isSending ? "Sending message" : "Send message"
        trailingButton.accessibilityHint = next.isSending
            ? "Waiting for the message to be admitted."
            : next.trailingMode == .send && next.offersQueueChoices
                ? "Sends steering after the current turn. Touch and hold to choose follow-up delivery."
                : nil
        bar.tintColor = next.showsAmbientWorkingBlur
            ? ChatUIKitComposerColors.emerald.withAlphaComponent(0.32)
            : ChatUIKitComposerColors.emerald.withAlphaComponent(0.25)
    }

    private func makeAttachmentMenu(_ next: ChatUIKitComposerInput) -> UIMenu {
        var children = [
            destinationAction("Take Photo", image: "camera", destination: .camera),
            destinationAction("Select Photos", image: "photo.on.rectangle", destination: .photos),
            destinationAction("Attach Files", image: "folder", destination: .files)
        ]
        if next.resourcePickerAvailable {
            children.append(destinationAction("Add Skills", image: "sparkles", destination: .skills))
        }
        children.append(destinationAction("Add Commands", image: "command", destination: .commands))
        return UIMenu(children: children)
    }

    private func destinationAction(_ title: String, image: String, destination: ChatAttachmentDestination) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: image)) { [weak self] _ in
            self?.onIntent?(.selectAttachmentDestination(destination))
        }
    }

    private func updateEditorHeight() {
        guard editor.bounds.width > 0, let font = editor.font else { return }
        let fitting = editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height
        let panelPresented = input?.resourcePicker != nil
        let maximum = ChatUIKitComposerLayoutPolicy.editorHeight(
            fittingHeight: .greatestFiniteMagnitude,
            lineHeight: font.lineHeight,
            panelPresented: panelPresented,
            keyboardVisible: input?.keyboardVisible == true
        )
        editor.isScrollEnabled = fitting > maximum + 0.5
        editorHeight?.constant = ChatUIKitComposerLayoutPolicy.editorHeight(
            fittingHeight: fitting,
            lineHeight: font.lineHeight,
            panelPresented: panelPresented,
            keyboardVisible: input?.keyboardVisible == true
        )
    }

    private func updateAccessibilityOrder() {
        var elements: [Any] = []
        if !attachmentScroll.isHidden { elements.append(contentsOf: attachmentStack.arrangedSubviews) }
        if !resourceScroll.isHidden { elements.append(contentsOf: resourceStack.arrangedSubviews) }
        if resourcePickerView.superview != nil { elements.append(resourcePickerView) }
        if !attachmentButton.isHidden { elements.append(attachmentButton) }
        if !editor.isHidden { elements.append(editor) }
        if !contextButton.isHidden { elements.append(contextButton) }
        if !trailingButton.isHidden { elements.append(trailingButton) }
        view.accessibilityElements = elements
    }

    private func clearArrangedSubviews(_ stack: UIStackView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        placeholder.isHidden = true
        guard !applyingAuthoritativeInput else { return }
        onIntent?(.focusChanged(true))
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        guard !applyingAuthoritativeInput else { return }
        onIntent?(.focusChanged(false))
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty || textView.isFirstResponder
        onIntent?(.textChanged(text: textView.text, selection: textView.selectedRange))
        updateEditorHeight()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.isFirstResponder else { return }
        onIntent?(.textChanged(text: textView.text, selection: textView.selectedRange))
    }

    @objc private func contextPressed() { onIntent?(.showContext) }
    @objc private func processesPressed() { onIntent?(.showProcesses) }
    @objc private func catchUpPressed() { onIntent?(.catchUp) }

    @objc private func trailingPressed() {
        guard let mode = input?.trailingMode else { return }
        switch mode {
        case .stopAgent:
            onIntent?(.abort)
        case .send:
            emitSend(behavior: nil)
        }
    }

    private func emitSend(behavior: String?) {
        guard let next = input else { return }
        let text = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next.trailingMode == .send,
              (!text.isEmpty || !next.attachments.isEmpty),
              !next.isSending, !next.submissionPending, !next.hasActiveUploads,
              next.isCommandReady,
              !(sendHandoffRevision == next.revision && sendHandoffAccepted) else { return }
        // A pending handoff suppresses duplicate native actions until the host
        // reports acceptance/rejection or the bounded terminal deadline opens
        // a retry. It is deliberately not keyed only to revision forever.
        guard sendHandoffRevision == nil else { return }
        sendHandoffRevision = next.revision
        sendHandoffAccepted = false
        sendHandoffTimeout?.cancel()
        sendHandoffTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2_000))
            guard let self, self.sendHandoffRevision == next.revision,
                  !self.sendHandoffAccepted else { return }
            self.clearSendHandoff()
        }
        onIntent?(.send(behavior: behavior))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let next = input, next.trailingMode == .send,
              next.offersQueueChoices,
              !next.isSending else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Steer after current turn", image: UIImage(systemName: "arrow.turn.up.right")) { [weak self] _ in self?.emitSend(behavior: "steer") },
                UIAction(title: "Follow up after current work", image: UIImage(systemName: "text.line.last.and.arrowtriangle.forward")) { [weak self] _ in self?.emitSend(behavior: "followUp") }
            ])
        }
    }
}

@MainActor
private final class ChatUIKitComposerEditor: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard isScrollEnabled, let range = selectedTextRange else { return }
        scrollRangeToVisible(NSRange(location: offset(from: beginningOfDocument, to: range.end), length: 0))
    }
}

@MainActor
private final class ChatUIKitComposerSurface: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let tint = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = ChatUIKitComposerColors.border.cgColor
        clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur); addSubview(tint)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor), blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor), tint.trailingAnchor.constraint(equalTo: trailingAnchor), tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var tintColor: UIColor! { didSet { tint.backgroundColor = tintColor } }
}

@MainActor
private final class ChatUIKitComposerAttachmentChip: UIView {
    var onPreview: (() -> Void)?
    var onRemove: (() -> Void)?
    private let preview = UIButton(type: .system)
    init(attachment: PendingAttachment) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
        preview.frame = bounds
        preview.translatesAutoresizingMaskIntoConstraints = false
        let image = attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) }
        preview.setImage(image ?? UIImage(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text"), for: .normal)
        preview.tintColor = ChatUIKitComposerColors.blue
        preview.backgroundColor = ChatUIKitComposerColors.blue.withAlphaComponent(0.10)
        preview.imageView?.contentMode = .scaleAspectFill
        preview.layer.cornerRadius = 14; preview.layer.cornerCurve = .continuous; preview.clipsToBounds = true
        preview.accessibilityLabel = "Preview \(attachment.name)"
        preview.accessibilityHint = attachment.mimeType.hasPrefix("image/") ? "Opens a photo preview" : "Opens the file preview"
        preview.addTarget(self, action: #selector(previewPressed), for: .primaryActionTriggered)
        addSubview(preview)
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark"), for: .normal)
        remove.tintColor = ChatUIKitComposerColors.primary
        remove.backgroundColor = ChatUIKitComposerColors.background.withAlphaComponent(0.92)
        remove.layer.cornerRadius = 11
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.accessibilityLabel = "Remove \(attachment.name)"
        remove.addTarget(self, action: #selector(removePressed), for: .primaryActionTriggered)
        addSubview(remove)
        NSLayoutConstraint.activate([remove.widthAnchor.constraint(equalToConstant: 22), remove.heightAnchor.constraint(equalToConstant: 22), remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 7), remove.topAnchor.constraint(equalTo: topAnchor, constant: -7)])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func previewPressed() { onPreview?() }
    @objc private func removePressed() { onRemove?() }
}

@MainActor
private final class ChatUIKitComposerResourceChip: UIView {
    var onDetails: (() -> Void)?
    var onRemove: (() -> Void)?
    init(resource: ComposerResourceEntry) {
        super.init(frame: .zero)
        let accent = resource.kind == .skill ? ChatUIKitComposerColors.cyan : ChatUIKitComposerColors.purple
        let details = UIButton(type: .system)
        details.setTitle("  \(resource.friendlyName)  ", for: .normal)
        details.setImage(UIImage(systemName: resource.kind == .skill ? "sparkles" : "command"), for: .normal)
        details.tintColor = accent; details.setTitleColor(accent, for: .normal)
        details.titleLabel?.font = ChatUIKitComposerFonts.chip
        details.accessibilityLabel = "\(resource.kind == .skill ? "Skill" : "Command"), \(resource.friendlyName)"
        details.accessibilityHint = "Opens details"
        details.addTarget(self, action: #selector(detailsPressed), for: .primaryActionTriggered)
        details.translatesAutoresizingMaskIntoConstraints = false
        addSubview(details)
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        remove.tintColor = ChatUIKitComposerColors.muted
        remove.accessibilityLabel = "Remove \(resource.friendlyName)"
        remove.addTarget(self, action: #selector(removePressed), for: .primaryActionTriggered)
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([details.leadingAnchor.constraint(equalTo: leadingAnchor), details.topAnchor.constraint(equalTo: topAnchor), details.bottomAnchor.constraint(equalTo: bottomAnchor), remove.leadingAnchor.constraint(equalTo: details.trailingAnchor, constant: 2), remove.trailingAnchor.constraint(equalTo: trailingAnchor), remove.centerYAnchor.constraint(equalTo: details.centerYAnchor), remove.widthAnchor.constraint(equalToConstant: 30), remove.heightAnchor.constraint(equalToConstant: 30), heightAnchor.constraint(equalToConstant: 34)])
        backgroundColor = accent.withAlphaComponent(0.15); layer.cornerRadius = 16; layer.cornerCurve = .continuous
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func detailsPressed() { onDetails?() }
    @objc private func removePressed() { onRemove?() }
}

@MainActor
private final class ChatUIKitComposerContextButton: UIButton {
    private var presentation = SessionContextProgressPresentation(contextPercentage: 0, modelName: nil, isCompacting: false, isEnabled: false)
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(track)
        layer.addSublayer(progress)
        track.fillColor = UIColor.clear.cgColor
        progress.fillColor = UIColor.clear.cgColor
        track.lineWidth = 2
        progress.lineWidth = 2.5
        track.lineCap = .round
        progress.lineCap = .round
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(1, min(bounds.width, bounds.height) * 0.20)
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true).cgPath
        track.path = path; progress.path = path
        track.frame = bounds; progress.frame = bounds
    }

    func apply(_ value: SessionContextProgressPresentation, reduceMotion: Bool) {
        presentation = value
        let bounded = min(max(value.contextPercentage, 0), 100)
        let accent = value.isEnabled
            ? (bounded >= 95 ? ChatUIKitComposerColors.error : bounded >= 80 ? ChatUIKitComposerColors.amber : ChatUIKitComposerColors.emerald)
            : ChatUIKitComposerColors.muted
        track.strokeColor = ChatUIKitComposerColors.muted.withAlphaComponent(0.34).cgColor
        progress.strokeColor = accent.cgColor
        progress.strokeEnd = CGFloat(bounded) / 100
        isEnabled = value.isEnabled; alpha = value.isEnabled ? 1 : 0.56
        accessibilityLabel = "Manage Session"
        var parts = value.modelName.map { [$0] } ?? []
        parts.append(value.isEnabled ? "\(bounded)% context used" : "Session context loading")
        if value.isCompacting { parts.append("compacting") }
        accessibilityValue = parts.joined(separator: ", ")
        accessibilityHint = "Shows context usage, model selection, and session actions"
        if !reduceMotion {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
            progress.strokeEnd = CGFloat(bounded) / 100
            CATransaction.commit()
        }
    }
}

@MainActor
private final class ChatUIKitResourcePickerView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onSelect: ((ComposerResourceEntry) -> Void)?
    var onDetails: ((ComposerResourceEntry) -> Void)?
    var onDismiss: (() -> Void)?
    private let titleLabel = UILabel()
    private let queryLabel = UILabel()
    private let dismissButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .plain)
    private var entries: [ComposerResourceEntry] = []
    private var kind: ComposerResourceEntry.Kind = .command
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16; layer.cornerCurve = .continuous; clipsToBounds = true
        backgroundColor = ChatUIKitComposerColors.background.withAlphaComponent(0.94)
        titleLabel.font = ChatUIKitComposerFonts.title; queryLabel.font = ChatUIKitComposerFonts.caption; queryLabel.textColor = ChatUIKitComposerColors.secondary
        dismissButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal); dismissButton.tintColor = ChatUIKitComposerColors.muted; dismissButton.accessibilityLabel = "Dismiss resource picker"; dismissButton.addTarget(self, action: #selector(dismissPressed), for: .primaryActionTriggered)
        let header = UIStackView(arrangedSubviews: [titleLabel, queryLabel, UIView(), dismissButton]); header.axis = .horizontal; header.alignment = .center; header.spacing = 6; header.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self; table.delegate = self; table.rowHeight = 48; table.separatorStyle = .none; table.backgroundColor = .clear; table.register(UITableViewCell.self, forCellReuseIdentifier: "resource")
        table.translatesAutoresizingMaskIntoConstraints = false; addSubview(header); addSubview(table)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), header.topAnchor.constraint(equalTo: topAnchor, constant: 6), dismissButton.widthAnchor.constraint(equalToConstant: 36), dismissButton.heightAnchor.constraint(equalToConstant: 36), table.leadingAnchor.constraint(equalTo: leadingAnchor), table.trailingAnchor.constraint(equalTo: trailingAnchor), table.topAnchor.constraint(equalTo: header.bottomAnchor), table.bottomAnchor.constraint(equalTo: bottomAnchor), heightAnchor.constraint(greaterThanOrEqualToConstant: 54)])
        heightConstraint = heightAnchor.constraint(equalToConstant: 54); heightConstraint?.isActive = true
        accessibilityLabel = "Resource picker"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(kind: ComposerResourceEntry.Kind?, query: String, entries: [ComposerResourceEntry], keyboardVisible: Bool, reduceMotion: Bool) {
        guard let kind else { return }
        self.kind = kind; self.entries = entries
        titleLabel.text = kind == .skill ? "Skills" : "Commands"; queryLabel.text = query.isEmpty ? nil : "· \"\(query)\""; queryLabel.isHidden = query.isEmpty
        table.reloadData()
        let rows = ComposerResourcePanelPolicy.visibleRows(entryCount: entries.count, keyboardVisible: keyboardVisible)
        heightConstraint?.constant = CGFloat(54 + max(rows, entries.isEmpty ? 0 : 1) * 48)
        if !reduceMotion { alpha = 0; UIView.animate(withDuration: 0.18) { self.alpha = 1 } }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "resource", for: indexPath)
        let entry = entries[indexPath.row]; cell.backgroundColor = .clear; cell.textLabel?.text = entry.friendlyName; cell.textLabel?.font = ChatUIKitComposerFonts.body; cell.textLabel?.textColor = ChatUIKitComposerColors.primary; cell.imageView?.image = UIImage(systemName: kind == .skill ? "sparkles" : "command"); cell.imageView?.tintColor = kind == .skill ? ChatUIKitComposerColors.cyan : ChatUIKitComposerColors.purple; cell.accessibilityLabel = "\(kind == .skill ? "Skill" : "Command"), \(entry.displayName)"; cell.accessibilityHint = "Selects resource"; return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); onSelect?(entries[indexPath.row]) }
    @objc private func dismissPressed() { onDismiss?() }
}

private enum ChatUIKitComposerColors {
    private static func dynamic(light: String, dark: String) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }

    static let background = dynamic(light: "#F7F8FA", dark: "#090A0C")
    static let primary = dynamic(light: "#111827", dark: "#F8FAFC")
    static let secondary = dynamic(light: "#4B5563", dark: "#AAB2BF")
    static let muted = dynamic(light: "#6B7280", dark: "#8B949E")
    static let emerald = dynamic(light: "#059669", dark: "#10B981")
    static let cyan = dynamic(light: "#0891B2", dark: "#06B6D4")
    static let purple = dynamic(light: "#7C3AED", dark: "#8B5CF6")
    static let amber = dynamic(light: "#D97706", dark: "#F59E0B")
    static let error = dynamic(light: "#DC2626", dark: "#EF4444")
    static let blue = dynamic(light: "#2563EB", dark: "#3B82F6")
    static let border = dynamic(light: "#D8DEE6", dark: "#3B424D")
}

@MainActor
private enum ChatUIKitComposerFonts {
    static let input = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeBodyLG, weight: .regular))
    static let body = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeBody, weight: .regular))
    static let title = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeTitle, weight: .semibold))
    static let caption = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: TronFontLoader.createUIFont(size: TronTypography.sizeCaption, weight: .regular))
    static let chip = UIFontMetrics(forTextStyle: .body).scaledFont(for: TronFontLoader.createUIFont(size: 12, weight: .bold))
}
