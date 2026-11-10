import Observation
import SwiftUI
import UIKit

struct ChatAnnotationSource: Hashable {
    let itemID: String
    let partID: String

    func blockKey(_ block: String) -> String { "\(partID)/\(block)" }
}

extension EnvironmentValues {
    @Entry var chatAnnotationSource: ChatAnnotationSource? = nil
    @Entry var chatAnnotationPresenter: ChatAnnotationPresenter? = nil
}

struct ChatAnnotationRequest: Identifiable, Equatable {
    let id = UUID()
    let quote: String
    let anchor: ChatAnnotationAnchor
    let selectionRect: CGRect
}

@MainActor
@Observable
final class ChatAnnotationPresenter {
    private(set) var pending: ChatAnnotationRequest?
    private(set) var scope: ComposerDraftScope?
    @ObservationIgnored private weak var drafts: ComposerDraftCoordinator?

    func bind(drafts: ComposerDraftCoordinator, scope: ComposerDraftScope?) {
        self.drafts = drafts
        if self.scope != scope {
            self.scope = scope
            pending = nil
            endReveal()
            revealed = nil
            revealSheetTop = nil
        }
    }

    func highlights(itemID: String, blockKey: String) -> [NSRange] {
        var anchors: [ChatAnnotationAnchor] = []
        if let scope, let drafts {
            anchors = drafts.annotations(for: scope).compactMap(\.anchor)
        }
        if let pending { anchors.append(pending.anchor) }
        return anchors
            .filter { $0.itemID == itemID && $0.blockKey == blockKey }
            .map(\.range)
    }

    var admitsAnnotations: Bool { scope != nil && drafts != nil }

    func begin(_ request: ChatAnnotationRequest) {
        guard admitsAnnotations else { return }
        pending = request
    }

    func cancel() { pending = nil }

    struct RevealScroll: Equatable {
        enum Target: Equatable {
            case row(itemID: String)
            case visualOffset(CGFloat)
        }
        let id = UUID()
        let target: Target
    }

    private struct Reveal {
        let anchor: ChatAnnotationAnchor
        let quote: String
        var scrolls = 0
    }

    static let revealBandTop: CGFloat = 0.14
    private static let maximumRevealScrolls = 3
    static let maximumSettleFrames = 30

    private(set) var revealScroll: RevealScroll?

    struct RevealedSource: Equatable {
        let id = UUID()
        let itemID: String
        let blockKey: String
        let quote: String
        let rect: CGRect
    }
    private(set) var revealed: RevealedSource?

    #if HOSTED_TEST
    static var hostedReveals: (@MainActor (_ event: String, _ quote: String, _ windowFrame: CGRect?) -> Void)?
    #endif

    func revealed(itemID: String, blockKey: String) -> RevealedSource? {
        guard let revealed, revealed.itemID == itemID, revealed.blockKey == blockKey else { return nil }
        return revealed
    }
    @ObservationIgnored var revealBottom: CGFloat?
    @ObservationIgnored var sheetTop: CGFloat? {
        didSet { if revealSheetTop != nil { revealSheetTop = sheetTop } }
    }
    private(set) var revealSheetTop: CGFloat?
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var reveal: Reveal?
    @ObservationIgnored private var sources: [SourceKey: WeakSource] = [:]

    private struct SourceKey: Hashable { let itemID: String; let blockKey: String }
    private struct WeakSource { weak var view: ChatSelectableTextView? }

    func reveal(_ annotation: ChatAnnotation) {
        guard let anchor = annotation.anchor else { return }
        revealed = nil
        reveal = Reveal(anchor: anchor, quote: annotation.quote)
        if let sheetTop { revealSheetTop = sheetTop }
        if !placeReveal() { request(.row(itemID: anchor.itemID)) }
    }

    func revealScrollLanded() {
        guard reveal != nil else { return }
        if !placeReveal() { endReveal() }
    }

    func endReveal() {
        reveal = nil
        revealScroll = nil
    }

    func register(_ view: ChatSelectableTextView, itemID: String, blockKey: String) {
        sources[SourceKey(itemID: itemID, blockKey: blockKey)] = WeakSource(view: view)
    }

    func unregister(_ view: ChatSelectableTextView) {
        sources = sources.filter { $0.value.view != nil && $0.value.view !== view }
    }

    var revealSourceFrame: CGRect? {
        guard let reveal,
              let view = sources[SourceKey(itemID: reveal.anchor.itemID, blockKey: reveal.anchor.blockKey)]?.view,
              let window = view.window,
              NSMaxRange(reveal.anchor.range) <= view.attributedText.length else { return nil }
        return view.convert(view.bounds(of: reveal.anchor.range), to: window)
    }

    private func placeReveal() -> Bool {
        guard var reveal,
              let view = sources[SourceKey(itemID: reveal.anchor.itemID, blockKey: reveal.anchor.blockKey)]?.view,
              let window = view.window,
              NSMaxRange(reveal.anchor.range) <= view.attributedText.length else { return false }
        let rect = view.convert(view.bounds(of: reveal.anchor.range), to: window)
        let top = window.bounds.height * Self.revealBandTop
        let obstruction = min(revealBottom ?? window.bounds.height * 0.5, sheetTop ?? .infinity)
        let bottom = max(top + 1, obstruction - 12)
        let tall = rect.height > bottom - top
        let placed = tall ? abs(rect.minY - top) <= 1 : rect.minY >= top && rect.maxY <= bottom
        if placed || reveal.scrolls >= Self.maximumRevealScrolls {
            let source = RevealedSource(
                itemID: reveal.anchor.itemID,
                blockKey: reveal.anchor.blockKey,
                quote: reveal.quote,
                rect: view.bounds(of: reveal.anchor.range)
            )
            revealed = source
            #if HOSTED_TEST
            Self.hostedReveals?("shown", source.quote, rect)
            #endif
            view.flash(reveal.anchor.range, reduceMotion: reduceMotion) { [weak self] in
                guard let self, self.revealed?.id == source.id else { return }
                self.revealed = nil
                #if HOSTED_TEST
                Self.hostedReveals?("cleared", source.quote, nil)
                #endif
            }
            endReveal()
            return true
        }
        reveal.scrolls += 1
        self.reveal = reveal
        let target = tall ? top : (top + bottom - rect.height) / 2
        request(.visualOffset(rect.minY - target))
        return true
    }

    private func request(_ target: RevealScroll.Target) {
        revealScroll = RevealScroll(target: target)
    }

    func save(comment: String) {
        guard let pending, let scope, let drafts else { return }
        drafts.addAnnotation(
            ChatAnnotation(
                quote: pending.quote,
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                anchor: pending.anchor
            ),
            for: scope
        )
        self.pending = nil
    }
}

extension View {
    func chatRevealedSource(_ presenter: ChatAnnotationPresenter, itemID: String, blockKey: String) -> some View {
        overlay(alignment: .topLeading) {
            if let revealed = presenter.revealed(itemID: itemID, blockKey: blockKey) {
                Color.clear
                    .frame(width: revealed.rect.width, height: revealed.rect.height)
                    .offset(x: revealed.rect.minX, y: revealed.rect.minY)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(revealed.quote)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("chat.annotation.revealed-source")
                    #if HOSTED_TEST
                    .onAppear { ChatAnnotationPresenter.hostedReveals?("exposed", revealed.quote, nil) }
                    #endif
            }
        }
    }
}

struct ChatSelectableTextStyle: Hashable {
    var size: CGFloat = 14
    var weight: TronFontLoader.Weight = .regular
    var color: Color = .tronTextPrimary
}

struct ChatSelectableInlineText: UIViewRepresentable {
    let inline: MarkdownPresentation.Inline
    let style: ChatSelectableTextStyle
    var messageBlocks: [MarkdownPresentation.Block]? = nil
    var highlights: [NSRange] = []
    var detectsLinks = false
    var revealSource: (presenter: ChatAnnotationPresenter, itemID: String, blockKey: String)? = nil
    let onAnnotate: ((String, NSRange, CGRect) -> Void)?

    init(
        inline: MarkdownPresentation.Inline,
        style: ChatSelectableTextStyle,
        highlights: [NSRange] = [],
        detectsLinks: Bool = false,
        revealSource: (presenter: ChatAnnotationPresenter, itemID: String, blockKey: String)? = nil,
        onAnnotate: ((String, NSRange, CGRect) -> Void)?
    ) {
        self.inline = inline
        self.style = style
        self.highlights = highlights
        self.detectsLinks = detectsLinks
        self.revealSource = revealSource
        self.onAnnotate = onAnnotate
    }

    init(
        messageBlocks: [MarkdownPresentation.Block],
        style: ChatSelectableTextStyle,
        highlights: [NSRange],
        revealSource: (presenter: ChatAnnotationPresenter, itemID: String, blockKey: String)?,
        onAnnotate: ((String, NSRange, CGRect) -> Void)?
    ) {
        self.revealSource = revealSource
        self.inline = MarkdownPresentation.Inline(source: Self.plainText(messageBlocks), attributedString: nil)
        self.style = style
        self.messageBlocks = messageBlocks
        self.highlights = highlights
        self.onAnnotate = onAnnotate
    }

    private static func plainText(_ blocks: [MarkdownPresentation.Block]) -> String {
        blocks.map { block in
            switch block.kind {
            case .paragraph(let value), .heading(_, let value): value.source
            case .list(let items): items.map { "\($0.marker) \($0.inline.source)" }.joined(separator: "\n")
            default: ""
            }
        }.joined(separator: "\n")
    }

    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme
    @State private var fontSettings = FontSettings.shared

    static let accessibilityIdentifier = "chat.assistant.selectable-text"

    struct RenderKey: Equatable {
        let inline: MarkdownPresentation.Inline
        let style: ChatSelectableTextStyle
        let messageBlocks: [MarkdownPresentation.Block]?
        let highlights: [NSRange]
        let detectsLinks: Bool
        let sizeCategory: ContentSizeCategory
        let colorScheme: ColorScheme
        let fontRevision: String
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var key: RenderKey?
        var onAnnotate: ((String, NSRange, CGRect) -> Void)?
        weak var presenter: ChatAnnotationPresenter?

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let textView = textView as? ChatSelectableTextView,
                  let annotate = annotateAction(textView, range: range) else { return nil }
            return UIMenu(children: [annotate] + suggestedActions)
        }

        func annotateAction(_ textView: ChatSelectableTextView, range: NSRange) -> UIAction? {
            let source = textView.attributedText.string as NSString
            guard onAnnotate != nil, range.length > 0, NSMaxRange(range) <= source.length else { return nil }
            let trimmed = ChatSelectableTextLayout.trimmedRange(range, in: source)
            guard trimmed.length > 0 else { return nil }
            let quote = source.substring(with: trimmed)
            return UIAction(
                title: "Annotate",
                image: UIImage(systemName: "text.quote")
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                let windowRect = textView.convert(textView.bounds(of: trimmed), to: nil)
                textView.endChatSelection()
                self.onAnnotate?(quote, trimmed, windowRect)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ChatSelectableTextView {
        let view: ChatSelectableTextView = messageBlocks == nil
            ? ChatSelectableTextView(frame: .zero, textContainer: nil)
            : ChatSelectableMessageTextView(frame: .zero, textContainer: nil)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.foregroundColor: UIColor(Color.tronPrimary)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = Self.accessibilityIdentifier
        view.delegate = context.coordinator
        view.annotateAction = { [weak coordinator = context.coordinator, weak view] range in
            guard let coordinator, let view else { return nil }
            return coordinator.annotateAction(view, range: range)
        }
        return view
    }

    func updateUIView(_ view: ChatSelectableTextView, context: Context) {
        configure(view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: ChatSelectableTextView, coordinator: Coordinator) {
        coordinator.presenter?.unregister(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatSelectableTextView, context: Context) -> CGSize? {
        configure(uiView, coordinator: context.coordinator)
        let width = proposal.width ?? 10_000
        guard width > 0, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? ceil(size.width), height: ceil(size.height))
    }

    private func configure(_ view: ChatSelectableTextView, coordinator: Coordinator) {
        coordinator.onAnnotate = onAnnotate
        if let revealSource {
            coordinator.presenter = revealSource.presenter
            revealSource.presenter.register(view, itemID: revealSource.itemID, blockKey: revealSource.blockKey)
        }
        let family = fontSettings.selectedFamily
        let key = RenderKey(
            inline: inline,
            style: style,
            messageBlocks: messageBlocks,
            highlights: highlights,
            detectsLinks: detectsLinks,
            sizeCategory: sizeCategory,
            colorScheme: colorScheme,
            fontRevision: "\(family.rawValue):\(fontSettings.axisValue(for: family, axis: .weight)):\(fontSettings.axisValue(for: family, axis: .casual)):\(fontSettings.selectedMonoFamily.rawValue)"
        )
        guard coordinator.key != key else { return }
        coordinator.key = key
        view.endKeyboardSelection()
        view.clearRevealedSource()
        view.dataDetectorTypes = detectsLinks ? [.link] : []
        let traits = UITraitCollection(traitsFrom: [
            view.traitCollection,
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(sizeCategory)),
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light),
        ])
        view.attributedText = messageBlocks.map {
            ChatSelectableTextLayout.attributedText(
                $0,
                style: style,
                highlights: highlights,
                traits: traits
            )
        } ?? ChatSelectableTextLayout.attributedText(
            inline,
            style: style,
            highlights: highlights,
            traits: traits
        )
        if let messageBlocks, let messageView = view as? ChatSelectableMessageTextView {
            messageView.installAccessibilitySegments(ChatSelectableTextLayout.accessibilitySegments(messageBlocks))
        } else {
            view.accessibilityLabel = inline.accessibilitySource
            view.accessibilityElements = nil
        }
    }
}

@MainActor
class ChatSelectableTextView: UITextView {
    var annotateAction: ((NSRange) -> UIAction?)?

    private static weak var activeKeyboardSelection: ChatSelectableTextView?

    private lazy var delegateProxy = KeyboardSelectionDelegate(owner: self)
    private lazy var selectionDisplay = UITextSelectionDisplayInteraction(textInput: self, delegate: delegateProxy)
    private lazy var editMenu = UIEditMenuInteraction(delegate: delegateProxy)
    private lazy var selectionPress = UILongPressGestureRecognizer(target: self, action: #selector(selectWithPress(_:)))
    private lazy var handleDrag = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
    private lazy var clearingTap = UITapGestureRecognizer(target: self, action: #selector(clearWithTap))
    private var loupe: UITextLoupeSession?
    private var pressAnchor: NSRange?
    private var fixedHandleOffset: Int?
    private var isAdjustingSelection = false
    private var selectionGeneration = 0

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addInteraction(selectionDisplay)
        addInteraction(editMenu)
        for recognizer in [selectionPress, handleDrag, clearingTap] as [UIGestureRecognizer] {
            recognizer.delegate = delegateProxy
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool {
        !ChatTextInputFocus.keyboardIsOwned(byAnotherThan: self) && super.canBecomeFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        endKeyboardSelection()
        return true
    }

    private var hasKeyboardSelection: Bool { Self.activeKeyboardSelection === self }

    func endChatSelection() {
        endKeyboardSelection()
        if isFirstResponder {
            selectedRange = NSRange(location: 0, length: 0)
            resignFirstResponder()
        }
    }

    func endKeyboardSelection() {
        guard hasKeyboardSelection else { return }
        Self.activeKeyboardSelection = nil
        pressAnchor = nil
        fixedHandleOffset = nil
        loupe?.invalidate()
        loupe = nil
        selectedRange = NSRange(location: 0, length: 0)
        selectionDisplay.isActivated = false
        editMenu.dismissMenu()
    }

    private var flashView: UIView?

    func clearRevealedSource() {
        flashView?.removeFromSuperview()
        flashView = nil
    }

    func flash(_ range: NSRange, reduceMotion: Bool, faded: @escaping () -> Void) {
        clearRevealedSource()
        var rects: [CGRect] = []
        if let start = position(from: beginningOfDocument, offset: range.location),
           let end = position(from: start, offset: range.length),
           let textRange = textRange(from: start, to: end) {
            rects = selectionRects(for: textRange).map(\.rect).filter { !$0.isEmpty }
        }
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { faded(); return }
        let container = UIView(frame: union)
        container.isUserInteractionEnabled = false
        let tint = UIColor(Color.tronAmber).resolvedColor(with: traitCollection).withAlphaComponent(0.5)
        for rect in rects {
            let piece = UIView(frame: rect.offsetBy(dx: -union.minX, dy: -union.minY).insetBy(dx: -2, dy: -1))
            piece.backgroundColor = tint
            piece.layer.cornerRadius = 4
            piece.layer.cornerCurve = .continuous
            container.addSubview(piece)
        }
        addSubview(container)
        flashView = container
        let finish = { [weak self, weak container] (_: Bool) in
            faded()
            guard let self, let container, self.flashView === container else { return }
            container.removeFromSuperview()
            self.flashView = nil
        }
        if reduceMotion {
            UIView.animate(withDuration: 0.6, delay: 0.5, options: [.curveEaseOut, .allowUserInteraction],
                           animations: { container.alpha = 0 }, completion: finish)
        } else {
            container.alpha = 0
            container.transform = CGAffineTransform(scaleX: 1.04, y: 1.12)
            UIView.animateKeyframes(withDuration: 1.05, delay: 0, options: [.allowUserInteraction, .calculationModeCubic], animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                    container.alpha = 1
                    container.transform = .identity
                }
                UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) { container.alpha = 0 }
            }, completion: finish)
        }
    }

    fileprivate func keyboardSelectionShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === selectionPress {
            return ChatTextInputFocus.keyboardIsOwned(byAnotherThan: self)
        }
        if recognizer === handleDrag {
            let pressing = [.began, .changed].contains(selectionPress.state)
            return !pressing && hasKeyboardSelection && handleEnd(near: recognizer.location(in: self)) != nil
        }
        return hasKeyboardSelection
    }

    fileprivate func keyboardSelection(_ recognizer: UIGestureRecognizer,
                                       recognizesSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer === selectionPress && other.view === self
    }

    fileprivate func keyboardSelection(_ recognizer: UIGestureRecognizer,
                                       makesWait other: UIGestureRecognizer) -> Bool {
        recognizer === handleDrag && other.view is UIScrollView && other.view !== self
    }

    @objc private func selectWithPress(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: self)
        switch press.state {
        case .began:
            guard let word = wordRange(at: point) else { return }
            Self.activeKeyboardSelection?.endKeyboardSelection()
            Self.activeKeyboardSelection = self
            selectionGeneration += 1
            pressAnchor = word
            selectionDisplay.isActivated = true
            setKeyboardSelection(word)
            loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: self)
        case .changed:
            guard let anchor = pressAnchor, let word = wordRange(at: point) else { return }
            setKeyboardSelection(NSUnionRange(anchor, word))
            loupe?.move(to: point, withCaretRect: caretRect(atOffset: offset(at: point)), trackingCaret: false)
        case .ended:
            finishAdjusting()
        default:
            endKeyboardSelection()
        }
    }

    @objc private func dragHandle(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        switch pan.state {
        case .began:
            guard let moving = handleEnd(near: point) else { return }
            let range = selectedRange
            fixedHandleOffset = moving == range.location ? NSMaxRange(range) : range.location
            selectionGeneration += 1
            isAdjustingSelection = true
            editMenu.dismissMenu()
            loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: self)
        case .changed:
            guard let fixed = fixedHandleOffset else { return }
            let moving = offset(at: point)
            let lower = min(fixed, moving), upper = max(fixed, moving)
            guard upper > lower else { return }
            setKeyboardSelection(NSRange(location: lower, length: upper - lower))
            loupe?.move(to: point, withCaretRect: caretRect(atOffset: moving), trackingCaret: true)
        default:
            fixedHandleOffset = nil
            finishAdjusting()
        }
    }

    @objc private func clearWithTap() { endKeyboardSelection() }

    private func setKeyboardSelection(_ range: NSRange) {
        selectedRange = range
        selectionDisplay.setNeedsSelectionUpdate()
    }

    private func finishAdjusting() {
        loupe?.invalidate()
        loupe = nil
        guard hasKeyboardSelection, selectedRange.length > 0 else {
            endKeyboardSelection()
            return
        }
        isAdjustingSelection = true
        let bounds = bounds(of: selectedRange)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: CGPoint(x: bounds.midX, y: bounds.minY)
        ))
        isAdjustingSelection = false
    }

    private func offset(at point: CGPoint) -> Int {
        guard let position = closestPosition(to: point) else { return 0 }
        return offset(from: beginningOfDocument, to: position)
    }

    private func caretRect(atOffset offset: Int) -> CGRect {
        guard let position = position(from: beginningOfDocument, offset: offset) else { return .null }
        return caretRect(for: position)
    }

    private func wordRange(at point: CGPoint) -> NSRange? {
        guard let position = closestPosition(to: point) else { return nil }
        let word = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward))
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.backward))
        if let word {
            let location = offset(from: beginningOfDocument, to: word.start)
            return NSRange(location: location, length: offset(from: word.start, to: word.end))
        }
        let length = attributedText.length
        guard length > 0 else { return nil }
        return NSRange(location: min(offset(from: beginningOfDocument, to: position), length - 1), length: 1)
    }

    private func handleEnd(near point: CGPoint) -> Int? {
        let range = selectedRange
        guard range.length > 0 else { return nil }
        let slop: CGFloat = 22
        for end in [range.location, NSMaxRange(range)] {
            let caret = caretRect(atOffset: end)
            if !caret.isNull, caret.insetBy(dx: -slop, dy: -slop).contains(point) { return end }
        }
        return nil
    }

    func bounds(of range: NSRange) -> CGRect {
        var rect = CGRect.null
        if let start = position(from: beginningOfDocument, offset: range.location),
           let end = position(from: start, offset: range.length),
           let textRange = textRange(from: start, to: end) {
            for selection in selectionRects(for: textRange) where !selection.rect.isEmpty {
                rect = rect.union(selection.rect)
            }
        }
        return rect.isNull ? bounds : rect
    }

    fileprivate func keyboardSelectionMenu(suggestedActions: [UIMenuElement]) -> UIMenu? {
        let range = selectedRange
        guard hasKeyboardSelection, range.length > 0, NSMaxRange(range) <= attributedText.length else { return nil }
        return UIMenu(children: [annotateAction?(range)].compactMap { $0 } + suggestedActions)
    }

    fileprivate var keyboardSelectionMenuTarget: CGRect {
        hasKeyboardSelection ? bounds(of: selectedRange) : .null
    }

    fileprivate func keyboardSelectionMenuWillDismiss(_ animator: any UIEditMenuInteractionAnimating) {
        guard !isAdjustingSelection else { return }
        let generation = selectionGeneration
        animator.addCompletion { [weak self] in
            guard let self, self.selectionGeneration == generation, !self.isAdjustingSelection,
                  self.fixedHandleOffset == nil else { return }
            self.endKeyboardSelection()
        }
    }
}

@MainActor
private final class KeyboardSelectionDelegate: NSObject, @preconcurrency UIGestureRecognizerDelegate,
    @preconcurrency UIEditMenuInteractionDelegate, @preconcurrency UITextSelectionDisplayInteractionDelegate {
    weak var owner: ChatSelectableTextView?

    init(owner: ChatSelectableTextView) { self.owner = owner }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        owner?.keyboardSelectionShouldBegin(recognizer) ?? false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        owner?.keyboardSelection(recognizer, recognizesSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        owner?.keyboardSelection(recognizer, makesWait: other) ?? false
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        owner?.keyboardSelectionMenu(suggestedActions: suggestedActions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        owner?.keyboardSelectionMenuTarget ?? .null
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        owner?.keyboardSelectionMenuWillDismiss(animator)
    }
}

@MainActor
private struct ChatSelectableAccessibilitySegment: Equatable {
    let label: String
    let range: NSRange
}

@MainActor
private final class ChatSelectableMessageTextView: ChatSelectableTextView {
    private var segments: [ChatSelectableAccessibilitySegment] = []
    private var segmentElements: [UIAccessibilityElement] = []

    func installAccessibilitySegments(_ segments: [ChatSelectableAccessibilitySegment]) {
        if self.segments != segments {
            self.segments = segments
            segmentElements = segments.map { segment in
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = segment.label
                element.accessibilityTraits = .staticText
                return element
            }
            accessibilityElements = segmentElements
        }
        isAccessibilityElement = false
        accessibilityLabel = nil
        refreshAccessibilityFrames()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshAccessibilityFrames()
    }

    private func refreshAccessibilityFrames() {
        for (segment, element) in zip(segments, segmentElements) {
            if let start = position(from: beginningOfDocument, offset: segment.range.location),
               let end = position(from: start, offset: segment.range.length),
               let textRange = textRange(from: start, to: end) {
                let rect = selectionRects(for: textRange).reduce(CGRect.null) { partial, value in
                    value.rect.isEmpty ? partial : partial.union(value.rect)
                }
                element.accessibilityFrameInContainerSpace = rect.isNull ? .zero : rect
            } else {
                element.accessibilityFrameInContainerSpace = .zero
            }
        }
    }
}

@MainActor
enum ChatSelectableTextLayout {
    static let highlightOpacity = 0.24

    static func scaledFont(
        size: CGFloat,
        weight: TronFontLoader.Weight,
        mono: Bool = false,
        traits: UITraitCollection
    ) -> UIFont {
        let base = TronFontLoader.createUIFont(size: size, weight: weight, mono: mono)
        return UIFontMetrics(forTextStyle: TronFontLoader.uiTextStyle(for: size))
            .scaledFont(for: base, compatibleWith: traits)
    }

    static func firstBaseline(style: ChatSelectableTextStyle, sizeCategory: ContentSizeCategory) -> CGFloat {
        scaledFont(
            size: style.size,
            weight: style.weight,
            traits: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(sizeCategory))
        ).ascender
    }

    fileprivate static func accessibilitySegments(_ blocks: [MarkdownPresentation.Block]) -> [ChatSelectableAccessibilitySegment] {
        var offset = 0
        var segments: [ChatSelectableAccessibilitySegment] = []
        for (index, block) in blocks.enumerated() {
            if index > 0 { offset += 1 }
            switch block.kind {
            case .paragraph(let inline):
                let length = renderedString(inline).utf16.count
                segments.append(.init(label: inline.accessibilitySource, range: NSRange(location: offset, length: length)))
                offset += length
            case .heading(_, let inline):
                let length = renderedString(inline).utf16.count
                segments.append(.init(label: inline.accessibilitySource, range: NSRange(location: offset, length: length)))
                offset += length
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    if itemIndex > 0 { offset += 1 }
                    let length = (item.marker + " " + renderedString(item.inline)).utf16.count
                    segments.append(.init(label: "\(item.marker) \(item.inline.accessibilitySource)", range: NSRange(location: offset, length: length)))
                    offset += length
                }
            default:
                break
            }
        }
        return segments
    }

    private static func renderedString(_ inline: MarkdownPresentation.Inline) -> String {
        String((inline.attributedString ?? AttributedString(inline.source)).characters)
    }

    static func attributedText(
        _ blocks: [MarkdownPresentation.Block],
        style: ChatSelectableTextStyle,
        highlights: [NSRange],
        traits: UITraitCollection
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let start = result.length
            switch block.kind {
            case .paragraph(let inline):
                result.append(attributedText(inline, style: style, highlights: [], traits: traits))
                setParagraphSpacing(result, range: NSRange(location: start, length: result.length - start), after: 9)
            case .heading(let level, let inline):
                let size = max(14, 22 - CGFloat(level * 2))
                let weight: TronFontLoader.Weight = level <= 2 ? .bold : .semibold
                let headingStyle = ChatSelectableTextStyle(size: size, weight: weight, color: style.color)
                result.append(attributedText(inline, style: headingStyle, highlights: [], traits: traits))
                setParagraphSpacing(result, range: NSRange(location: start, length: result.length - start), before: level <= 2 ? 6 : 2, after: 9)
            case .list(let items):
                for item in items {
                    if result.length > start { result.append(NSAttributedString(string: "\n")) }
                    let itemStart = result.length
                    let marker = NSAttributedString(string: "\(item.marker) ", attributes: [
                        .font: scaledFont(size: style.size, weight: style.weight, traits: traits),
                        .foregroundColor: UIColor(style.color).resolvedColor(with: traits),
                    ])
                    result.append(marker)
                    result.append(attributedText(item.inline, style: style, highlights: [], traits: traits))
                    let range = NSRange(location: itemStart, length: result.length - itemStart)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byWordWrapping
                    paragraph.firstLineHeadIndent = CGFloat(item.depth) * 14
                    paragraph.headIndent = CGFloat(item.depth) * 14 + ceil(marker.size().width)
                    paragraph.paragraphSpacing = 5
                    result.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
            default:
                break
            }
        }
        let highlight = UIColor(Color.tronAmber).resolvedColor(with: traits).withAlphaComponent(highlightOpacity)
        for range in highlights where range.location != NSNotFound && NSMaxRange(range) <= result.length {
            result.addAttribute(.backgroundColor, value: highlight, range: range)
        }
        return result
    }

    private static func setParagraphSpacing(
        _ text: NSMutableAttributedString,
        range: NSRange,
        before: CGFloat = 0,
        after: CGFloat
    ) {
        guard range.length > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }

    static func attributedText(
        _ inline: MarkdownPresentation.Inline,
        style: ChatSelectableTextStyle,
        highlights: [NSRange],
        traits: UITraitCollection
    ) -> NSAttributedString {
        let value = inline.attributedString ?? AttributedString(inline.source)
        let base = scaledFont(size: style.size, weight: style.weight, traits: traits)
        let strong = scaledFont(size: style.size, weight: max(style.weight, .bold), traits: traits)
        let code = scaledFont(size: style.size, weight: style.weight, mono: true, traits: traits)
        let color = UIColor(style.color).resolvedColor(with: traits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        let result = NSMutableAttributedString(
            string: String(value.characters),
            attributes: [.font: base, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        for run in value.runs {
            let range = NSRange(run.range, in: value)
            guard range.location != NSNotFound, NSMaxRange(range) <= result.length else { continue }
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? code : intent.contains(.stronglyEmphasized) ? strong : base
            if intent.contains(.emphasized),
               let italic = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: italic, size: font.pointSize)
            }
            result.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let link = run.link {
                result.addAttribute(.link, value: link, range: range)
            }
        }
        let highlight = UIColor(Color.tronAmber).resolvedColor(with: traits).withAlphaComponent(highlightOpacity)
        for range in highlights where range.location != NSNotFound && NSMaxRange(range) <= result.length {
            result.addAttribute(.backgroundColor, value: highlight, range: range)
        }
        return result
    }

    static func trimmedRange(_ range: NSRange, in source: NSString) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        while lower < upper,
              let scalar = UnicodeScalar(source.character(at: lower)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { lower += 1 }
        while upper > lower,
              let scalar = UnicodeScalar(source.character(at: upper - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }
}

extension TronFontLoader.Weight: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
