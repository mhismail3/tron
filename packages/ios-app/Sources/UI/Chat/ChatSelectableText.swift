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

/// Typography for one selectable block; mirrors the SwiftUI text it replaces.
struct ChatSelectableTextStyle: Hashable {
    var size: CGFloat = 14
    var weight: TronFontLoader.Weight = .regular
    var color: Color = .assistantMessageText
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
    var highlights: [NSRange] = []
    var detectsLinks = false
    let onAnnotate: ((String, NSRange, CGRect) -> Void)?

    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.colorScheme) private var colorScheme
    @State private var fontSettings = FontSettings.shared

    static let accessibilityIdentifier = "chat.assistant.selectable-text"

    /// Every input that changes rendered text. Selection survives any update
    /// that leaves it equal.
    struct RenderKey: Equatable {
        let inline: MarkdownPresentation.Inline
        let style: ChatSelectableTextStyle
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

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0, onAnnotate != nil else { return nil }
            let annotate = UIAction(
                title: "Annotate",
                image: UIImage(systemName: "text.quote")
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.annotate(textView, range: range)
            }
            return UIMenu(children: [annotate] + suggestedActions)
        }

        private func annotate(_ textView: UITextView, range: NSRange) {
            let source = textView.attributedText.string as NSString
            guard NSMaxRange(range) <= source.length else { return }
            let trimmed = ChatSelectableTextLayout.trimmedRange(range, in: source)
            guard trimmed.length > 0 else { return }
            var rect = CGRect.null
            if let start = textView.position(from: textView.beginningOfDocument, offset: trimmed.location),
               let end = textView.position(from: start, offset: trimmed.length),
               let textRange = textView.textRange(from: start, to: end) {
                for selection in textView.selectionRects(for: textRange) where !selection.rect.isEmpty {
                    rect = rect.union(selection.rect)
                }
            }
            if rect.isNull { rect = textView.bounds }
            let windowRect = textView.convert(rect, to: nil)
            textView.selectedRange = NSRange(location: 0, length: 0)
            textView.resignFirstResponder()
            onAnnotate?(source.substring(with: trimmed), trimmed, windowRect)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.foregroundColor: UIColor(Color.tronEmerald)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = Self.accessibilityIdentifier
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        configure(view, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        configure(uiView, coordinator: context.coordinator)
        let width = proposal.width ?? 10_000
        guard width > 0, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? ceil(size.width), height: ceil(size.height))
    }

    private func configure(_ view: UITextView, coordinator: Coordinator) {
        coordinator.onAnnotate = onAnnotate
        let family = fontSettings.selectedFamily
        let key = RenderKey(
            inline: inline,
            style: style,
            highlights: highlights,
            detectsLinks: detectsLinks,
            sizeCategory: sizeCategory,
            colorScheme: colorScheme,
            fontRevision: "\(family.rawValue):\(fontSettings.axisValue(for: family, axis: .weight)):\(fontSettings.axisValue(for: family, axis: .casual)):\(fontSettings.selectedMonoFamily.rawValue)"
        )
        guard coordinator.key != key else { return }
        coordinator.key = key
        view.dataDetectorTypes = detectsLinks ? [.link] : []
        let traits = UITraitCollection(traitsFrom: [
            view.traitCollection,
            UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(sizeCategory)),
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light),
        ])
        view.attributedText = ChatSelectableTextLayout.attributedText(
            inline,
            style: style,
            highlights: highlights,
            traits: traits
        )
        view.accessibilityLabel = inline.accessibilitySource
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
