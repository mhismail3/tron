import Foundation
@preconcurrency import UIKit

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
    private let trailingSpinner = ChatUIKitPulseLoadingView(accent: ChatUIKitTheme.emerald)
    private var editorHeight: NSLayoutConstraint?
    private var sendHandoffRevision: Int?
    private var sendHandoffIdentity: ChatUIKitComposerSendIdentity?
    private var sendHandoffAccepted = false
    private var applyingAuthoritativeInput = false
    nonisolated(unsafe) private var keyboardObservers: [NSObjectProtocol] = []
    private var attachmentChips: [String: ChatUIKitComposerAttachmentChip] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureStacks()
        configureEditor()
        configureButtons()
        configurePicker()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installKeyboardObservers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeKeyboardObservers()
    }

    /// Installs a new authoritative projection. This is the only input path;
    /// local UI events are emitted as intents and are never merged into it.
    @discardableResult
    func apply(_ next: ChatUIKitComposerInput) -> Bool {
        // Equal revisions may carry authoritative admission, rejection, or
        // focus transitions. Only an older revision is stale.
        if let appliedRevision, next.revision < appliedRevision {
            return false
        }
        if let prior = input, prior.revision != next.revision {
            clearSendHandoff()
        }
        // Revision is a UI refresh token, not an admission identity. A
        // same-revision replacement must not inherit the prior send outcome.
        if sendHandoffRevision == next.revision,
           next.sendIdentity != sendHandoffIdentity {
            clearSendHandoff()
        }
        if sendHandoffRevision == next.revision,
           next.sendIdentity == sendHandoffIdentity,
           (next.isSending || next.submissionPending) {
            sendHandoffAccepted = true
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        editor.font = ChatUIKitComposerFonts.input
        placeholder.font = ChatUIKitComposerFonts.input
        view.backgroundColor = .clear
        configureEditorFromInput(input ?? ChatUIKitComposerInput())
        if let input { configureButtonsFromInput(input) }
        updateEditorHeight()
        updateAccessibilityOrder()
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
        editor.textColor = ChatUIKitTheme.emerald
        editor.tintColor = ChatUIKitTheme.emerald
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
        placeholder.textColor = ChatUIKitTheme.emerald
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
        guard keyboardObservers.isEmpty, viewIfLoaded?.window != nil else { return }
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.viewIfLoaded?.window != nil else { return }
                    self.view.setNeedsLayout()
                    self.view.layoutIfNeeded()
                }
            })
        }
    }

    private func removeKeyboardObservers() {
        let center = NotificationCenter.default
        keyboardObservers.forEach { center.removeObserver($0) }
        keyboardObservers.removeAll()
    }

    deinit {
        // Lifecycle methods own suspension; deinit is only final cleanup.
        let center = NotificationCenter.default
        keyboardObservers.forEach { center.removeObserver($0) }
    }

    /// The host must resolve the terminal admission explicitly. Rejected sends
    /// release the exact identity for retry; accepted sends remain suppressed
    /// until a new authoritative identity arrives. There is no wildcard
    /// revision-only resolution.
    func resolveSend(revision: Int, identity: ChatUIKitComposerSendIdentity, accepted: Bool) {
        guard sendHandoffRevision == revision,
              identity == sendHandoffIdentity else { return }
        if accepted {
            sendHandoffAccepted = true
        } else {
            clearSendHandoff()
        }
    }

    private func clearSendHandoff() {
        sendHandoffRevision = nil
        sendHandoffIdentity = nil
        sendHandoffAccepted = false
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
        let retained = Dictionary(uniqueKeysWithValues: next.attachments.map { attachment in
            (attachment.id, attachmentChips[attachment.id] ?? ChatUIKitComposerAttachmentChip(attachment: attachment))
        })
        attachmentChips.keys.filter { retained[$0] == nil }.forEach { attachmentChips[$0]?.removeFromSuperview() }
        attachmentChips = retained
        clearArrangedSubviews(attachmentStack)
        for attachment in next.attachments {
            guard let chip = attachmentChips[attachment.id] else { continue }
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
                trailingSpinner.accentColor = ChatUIKitTheme.emerald
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
        guard let next = input, let identity = next.sendIdentity else { return }
        let text = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next.trailingMode == .send,
              (!text.isEmpty || !next.attachments.isEmpty),
              !next.isSending, !next.submissionPending, !next.hasActiveUploads,
              next.isCommandReady,
              !(sendHandoffRevision == next.revision && sendHandoffAccepted) else { return }
        // A pending handoff suppresses duplicate native actions until the host
        // reports the terminal acceptance or rejection for this admission.
        guard sendHandoffRevision == nil else { return }
        // No speculative timeout: an ambiguous transport result must not
        // reopen an accepted command and emit it a second time.
        sendHandoffRevision = next.revision
        sendHandoffIdentity = identity
        sendHandoffAccepted = false
        onIntent?(.send(behavior: behavior, identity: identity))
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
