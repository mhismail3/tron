import Observation
import SwiftUI
import UIKit

/// The assistant text part whose Markdown blocks may be quoted. Set by the
/// transcript row only; every other Markdown surface keeps SwiftUI text.
struct ChatAnnotationSource: Hashable {
    let itemID: String
    let partID: String

    func blockKey(_ block: String) -> String { "\(partID)/\(block)" }
}

extension EnvironmentValues {
    @Entry var chatAnnotationSource: ChatAnnotationSource? = nil
    @Entry var chatAnnotationPresenter: ChatAnnotationPresenter? = nil
}

/// A selection that is being annotated in the floating bubble.
struct ChatAnnotationRequest: Identifiable, Equatable {
    let id = UUID()
    let quote: String
    let anchor: ChatAnnotationAnchor
    /// The selection's bounds in window coordinates when Annotate was chosen.
    let selectionRect: CGRect
}

/// Chat-scoped presentation owner for annotating. Staged annotations stay in
/// `ComposerDraftCoordinator` (the draft authority); this object only binds
/// that authority to the mounted chat's scope and owns the open bubble.
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
        }
    }

    /// Ranges to highlight in one rendered block: staged annotations and the
    /// selection currently open in the bubble.
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

    // MARK: Revealing a staged annotation's source

    /// A scroll the transcript owes the open reveal.
    struct RevealScroll: Equatable {
        enum Target: Equatable {
            /// The source row is not mounted: bring it into the viewport first.
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

    /// The top of the band the source must lie in, as a fraction of the
    /// window height: below the navigation bar.
    static let revealBandTop: CGFloat = 0.14
    private static let maximumRevealScrolls = 3

    private(set) var revealScroll: RevealScroll?

    /// The last revealed source, for assistive technologies: the transcript
    /// row exposes it as an element over the range until the next reveal.
    struct RevealedSource: Equatable {
        let itemID: String
        let blockKey: String
        let quote: String
        /// The range's bounds in the source text view.
        let rect: CGRect
    }
    private(set) var revealed: RevealedSource?

    func revealed(itemID: String, blockKey: String) -> RevealedSource? {
        guard let revealed, revealed.itemID == itemID, revealed.blockKey == blockKey else { return nil }
        return revealed
    }
    /// The composer's top (with its staged chips) in window coordinates, the
    /// band's bottom; ChatView keeps it current.
    @ObservationIgnored var revealBottom: CGFloat?
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var reveal: Reveal?
    @ObservationIgnored private var sources: [SourceKey: WeakSource] = [:]

    private struct SourceKey: Hashable { let itemID: String; let blockKey: String }
    private struct WeakSource { weak var view: ChatSelectableTextView? }

    /// Scrolls the transcript to an annotation's selected range and flashes
    /// it. An annotation without an anchor, or whose source row is gone, does
    /// nothing.
    func reveal(_ annotation: ChatAnnotation) {
        guard let anchor = annotation.anchor else { return }
        revealed = nil
        reveal = Reveal(anchor: anchor, quote: annotation.quote)
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

    /// Measures the mounted source: flashes it when it is in the band (or no
    /// scroll can improve it), otherwise asks for the measured scroll. False
    /// when the source is not mounted.
    private func placeReveal() -> Bool {
        guard var reveal,
              let view = sources[SourceKey(itemID: reveal.anchor.itemID, blockKey: reveal.anchor.blockKey)]?.view,
              let window = view.window,
              NSMaxRange(reveal.anchor.range) <= view.attributedText.length else { return false }
        let rect = view.convert(view.bounds(of: reveal.anchor.range), to: window)
        let top = window.bounds.height * Self.revealBandTop
        let bottom = max(top + 1, (revealBottom ?? window.bounds.height * 0.5) - 12)
        if (rect.minY >= top && rect.maxY <= bottom) || reveal.scrolls >= Self.maximumRevealScrolls {
            view.flash(reveal.anchor.range, reduceMotion: reduceMotion)
            revealed = RevealedSource(
                itemID: reveal.anchor.itemID,
                blockKey: reveal.anchor.blockKey,
                quote: reveal.quote,
                rect: view.bounds(of: reveal.anchor.range)
            )
            endReveal()
            return true
        }
        reveal.scrolls += 1
        self.reveal = reveal
        // A source taller than the band starts at its top.
        let target = rect.height > bottom - top ? top : (top + bottom - rect.height) / 2
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
    /// The revealed source's accessibility element, over its range in this
    /// selectable text.
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
            }
        }
    }
}

/// Typography for one selectable block; mirrors the SwiftUI text it replaces.
struct ChatSelectableTextStyle: Hashable {
    var size: CGFloat = 14
    var weight: TronFontLoader.Weight = .regular
    var color: Color = .tronTextPrimary
}

/// A completed assistant Markdown block rendered by a non-editable UITextView,
/// which gives native range selection with drag handles (SwiftUI `Text` on
/// iOS 26 only selects whole views). Links keep UIKit's default open action.
/// The edit menu adds Annotate ahead of the system actions when the surface
/// admits annotation; otherwise it keeps only the system actions (Copy).
/// `detectsLinks` turns bare URLs into links for surfaces whose authored text
/// is not Markdown-linked (Ask Question); the transcript keeps them literal.
struct ChatSelectableInlineText: UIViewRepresentable {
    let inline: MarkdownPresentation.Inline
    let style: ChatSelectableTextStyle
    var messageBlocks: [MarkdownPresentation.Block]? = nil
    var highlights: [NSRange] = []
    var detectsLinks = false
    /// The presenter and block this text quotes from, so a staged
    /// annotation's quote can find and flash its source.
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
        // The message run renders `messageBlocks`; its plain text needs no Markdown parse.
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

    /// Every input that changes rendered text. Selection survives any update
    /// that leaves it equal.
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

        /// Annotate for `range`. The quote and its range are fixed when the
        /// menu is built, so a later re-render or layout shift cannot change
        /// what is quoted.
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
        // The subclasses use their designated initializer, which runs their
        // stored property initializers; `init(usingTextLayoutManager:)` does
        // not on iOS 27. A nil container selects TextKit 2.
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

/// Selectable chat text. UIKit's own range selection makes this view first
/// responder, which takes the keyboard from the focused composer; the
/// transcript then re-lays out under the finger and the drag extends onto
/// other text. So while another text input owns the keyboard this view
/// refuses first responder and selects with UIKit's public selection pieces
/// instead: the same word-granular long-press drag, handles, loupe and menu,
/// leaving the keyboard and the transcript where they are.
@MainActor
class ChatSelectableTextView: UITextView {
    /// Annotate for a selected range; nil when the surface does not annotate.
    var annotateAction: ((NSRange) -> UIAction?)?

    /// The one keyboard-up selection on screen.
    private static weak var activeKeyboardSelection: ChatSelectableTextView?

    /// UIScrollView is its own gesture delegate; these recognizers and the
    /// interactions use a separate one.
    private lazy var delegateProxy = KeyboardSelectionDelegate(owner: self)
    private lazy var selectionDisplay = UITextSelectionDisplayInteraction(textInput: self, delegate: delegateProxy)
    private lazy var editMenu = UIEditMenuInteraction(delegate: delegateProxy)
    private lazy var selectionPress = UILongPressGestureRecognizer(target: self, action: #selector(selectWithPress(_:)))
    private lazy var handleDrag = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
    private lazy var clearingTap = UITapGestureRecognizer(target: self, action: #selector(clearWithTap))
    private var loupe: UITextLoupeSession?
    /// The long press's first word; the selection always contains it.
    private var pressAnchor: NSRange?
    /// The selection end a handle drag keeps fixed.
    private var fixedHandleOffset: Int?
    /// Set while the menu is replaced, so its dismissal keeps the selection.
    private var isAdjustingSelection = false
    /// Advances with each new or adjusted selection; a dismissed menu ends
    /// only the selection it was shown for.
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
        // UIKit's own selection press still asks while it is refused.
        guard super.becomeFirstResponder() else { return false }
        endKeyboardSelection()
        return true
    }

    private var hasKeyboardSelection: Bool { Self.activeKeyboardSelection === self }

    /// Ends this view's selection in either mode.
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

    // MARK: Reveal flash

    private var flashView: UIView?

    func clearRevealedSource() {
        flashView?.removeFromSuperview()
        flashView = nil
    }

    /// A brief amber pulse over `range` that fades; with Reduce Motion only
    /// the fade.
    func flash(_ range: NSRange, reduceMotion: Bool) {
        clearRevealedSource()
        var rects: [CGRect] = []
        if let start = position(from: beginningOfDocument, offset: range.location),
           let end = position(from: start, offset: range.length),
           let textRange = textRange(from: start, to: end) {
            rects = selectionRects(for: textRange).map(\.rect).filter { !$0.isEmpty }
        }
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return }
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

    // MARK: Gestures

    fileprivate func keyboardSelectionShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === selectionPress {
            return ChatTextInputFocus.keyboardIsOwned(byAnotherThan: self)
        }
        if recognizer === handleDrag {
            // The long press's own drag extends by words; a handle only moves after it.
            let pressing = [.began, .changed].contains(selectionPress.state)
            return !pressing && hasKeyboardSelection && handleEnd(near: recognizer.location(in: self)) != nil
        }
        return hasKeyboardSelection
    }

    fileprivate func keyboardSelection(_ recognizer: UIGestureRecognizer,
                                       recognizesSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // UIKit's own selection press fails quietly without first responder.
        recognizer === selectionPress && other.view === self
    }

    fileprivate func keyboardSelection(_ recognizer: UIGestureRecognizer,
                                       makesWait other: UIGestureRecognizer) -> Bool {
        // A handle drag wins over the transcript's scroll: the scroll waits for it.
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

    // MARK: Geometry

    private func offset(at point: CGPoint) -> Int {
        guard let position = closestPosition(to: point) else { return 0 }
        return offset(from: beginningOfDocument, to: position)
    }

    private func caretRect(atOffset offset: Int) -> CGRect {
        guard let position = position(from: beginningOfDocument, offset: offset) else { return .null }
        return caretRect(for: position)
    }

    /// The word at `point`, or the character there when it is not in a word.
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

    /// The selection end whose handle is under `point`.
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

    /// The union of the selection rects for `range`, in this view.
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

    // MARK: Menu

    /// Annotate ahead of the system actions, as the keyboard-down menu.
    fileprivate func keyboardSelectionMenu(suggestedActions: [UIMenuElement]) -> UIMenu? {
        let range = selectedRange
        guard hasKeyboardSelection, range.length > 0, NSMaxRange(range) <= attributedText.length else { return nil }
        return UIMenu(children: [annotateAction?(range)].compactMap { $0 } + suggestedActions)
    }

    fileprivate var keyboardSelectionMenuTarget: CGRect {
        hasKeyboardSelection ? bounds(of: selectedRange) : .null
    }

    fileprivate func keyboardSelectionMenuWillDismiss(_ animator: any UIEditMenuInteractionAnimating) {
        // A tap or scroll elsewhere dismisses the menu and ends the selection,
        // as it would resign UIKit's own.
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
        // Layout/highlight updates must not replace the VoiceOver element that
        // owns focus. Only a different semantic source rebuilds these elements.
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
    /// Subtle highlighter for annotated ranges; amber is the annotation accent.
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

    /// First-line baseline for aligning a SwiftUI list marker with the block.
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
        // One separator between blocks, as `accessibilitySegments` counts them.
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
                    // Wrapped lines align with the item's text, after its marker.
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

    /// Selections commonly include the trailing space or newline of a word;
    /// the quote and its highlight are the visible words only.
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
