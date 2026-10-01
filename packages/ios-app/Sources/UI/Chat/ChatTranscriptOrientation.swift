import SwiftUI
import TronMobileCore

/// The transcript's origin-anchored layout: newest row at the exact content origin.
///
/// Everything that has to agree about which end is newest lives here: the render
/// flip on the scroll view, the counter-flip each element applies, the order the
/// row spine presents, the layout edge, anchor and padding set a name maps to,
/// the sign a layout offset keeps, and the geometry the coordinator reads.
/// Callers keep naming the transcript's own ends — `.bottom` is the pinned end
/// that holds the newest row, `.top` the visual top where older history lives —
/// or ask the semantic questions below. None of them branches on the flip.
enum ChatTranscriptOrientation: Equatable, Sendable {
    case newestAtOrigin

    /// The vertical render scale the transcript applies. Every element of the
    /// transcript's content applies the same value as its outermost modifier:
    /// that counter-flip cancels the transcript's flip for the element's own
    /// content while leaving its position in the origin-anchored order, so
    /// row-local transforms (the entrance rise, streaming growth, the queued
    /// card's shrink) render exactly as they do today.
    fileprivate var verticalScale: CGFloat { -1 }

    // MARK: The layout the transcript's own ends map to

    /// The scroll view's layout edge that holds the newest row.
    var newestEdge: Edge { layoutEdge(.bottom) }
    var oldestEdge: Edge { layoutEdge(.top) }

    /// The anchor that puts a target's newest side at the transcript's pinned
    /// bottom: the `initialOffset`, `alignment` and pinned `sizeChanges` roles,
    /// a scroll to the newest row or the marker at its end.
    var newestEndAnchor: UnitPoint { layoutAnchor(.bottom) }

    /// The anchor that puts a target's oldest side at the transcript's visual
    /// top, which unnamed content size changes fall back to.
    var oldestEndAnchor: UnitPoint { layoutAnchor(.top) }

    /// The `padding` set for the transcript edge the caller names.
    func paddingEdgeSet(_ transcriptEdge: Edge) -> Edge.Set {
        switch layoutEdge(transcriptEdge) {
        case .top: return .top
        case .bottom: return .bottom
        default: return .all
        }
    }

    /// A vertical layout offset that must read as the same movement on screen.
    /// The flip is a render transform, so a layout offset inside the flipped
    /// transcript renders inverted: the opening lift has to negate its own sign
    /// to stay a rise rather than a fall.
    func screenOffset(forLayoutRise rise: CGFloat) -> CGFloat { rise * verticalScale }

    /// The transcript-relative viewport frame for the `ScrollView` frame a row
    /// or the tail marker reports: `0` at the visual top of the visible
    /// transcript, increasing downward.
    ///
    /// The origin-anchored transcript renders its content mirrored, so its
    /// reported frames measure *upward* from the visual bottom: the pinned
    /// newest row reports a frame at `0` while it is drawn at the bottom of the
    /// viewport. Every consumer reads one space — the reader's anchor row, the
    /// tail marker's placement against the viewport, an entrance's visibility
    /// test, a correction's signed residual — so the reflection belongs here,
    /// when the coordinator reads stored raw frames, and nowhere else.
    /// `containerHeight` is the model's own visible height; before the first
    /// geometry sample there is no space to reflect into and the frame is
    /// returned unchanged.
    func transcriptFrame(_ frame: CGRect, geometry: ChatTranscriptGeometry) -> CGRect {
        let containerHeight = geometry.containerHeight + geometry.bottomInset
        guard containerHeight > 0 else { return frame }
        return CGRect(
            x: frame.minX,
            y: containerHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// The model offset that puts an anchor back where the layout moved it.
    /// `visualOffset` is the anchor's own movement down the visible transcript
    /// since the reader's position was captured.
    ///
    /// The model offset reflects the scroll view's native offset, so it moves
    /// against the content; its legal ends are the native scroll view's own,
    /// which clamps an out-of-range target.
    func correctedOffsetY(
        currentModelOffsetY: CGFloat,
        visualOffset: CGFloat
    ) -> CGFloat {
        currentModelOffsetY - visualOffset
    }

    /// The native `scrollTo(y:)` offset for a point in the coordinator's model.
    /// Its coordinate is reflected, so a catch-up or correction target must be
    /// reflected back before it reaches the scroll view or it jumps into old history.
    ///
    /// The model's own `distanceFromBottom` is the reverse of its offset, so the
    /// two share one anchor — the model offset at the pinned end — and a target's
    /// distance from that end is what a native offset is built from. The
    /// obstruction is content layout on this path, so that distance is measured
    /// from the exact native content origin, not an adjusted inset.
    func scrollOffsetY(
        forModelOffsetY modelOffsetY: CGFloat,
        geometry: ChatTranscriptGeometry
    ) -> CGFloat {
        guard geometry.isValid else { return modelOffsetY }
        let pinnedModelOffsetY = geometry.offsetY + geometry.distanceFromBottom
        return (pinnedModelOffsetY - modelOffsetY)
    }

    /// Safe-area obstructions read before the flip, mapped to layout ends. The
    /// two content clearances are lazy-layout items; only scroll indicators use
    /// margins. No component supplies a second height or curve.
    func layoutClearance(for safeAreaInsets: EdgeInsets) -> EdgeInsets {
        return EdgeInsets(
            top: safeAreaInsets.bottom,
            leading: 0,
            bottom: safeAreaInsets.top,
            trailing: 0
        )
    }

    /// The origin spine presents the newest row first, the reverse of VoiceOver's
    /// desired oldest-to-newest reading order. Sort priority is relative within
    /// the accessibility container and sorts highest-first, so the spine's own
    /// position puts the oldest element first and the newest last.
    func voiceOverSortPriority(forSpinePosition spinePosition: Int) -> Double {
        Double(spinePosition)
    }

    /// The visual position of a row in the origin-anchored spine, counted from
    /// the oldest end at the visual top.
    func visualPosition(ofSpinePosition position: Int, count: Int) -> Int {
        count - 1 - position
    }

    /// Native geometry plus the declared newest-edge spacer. The native sample
    /// remains authoritative until UIKit changes it; the declared input can
    /// change without altering the lazy stack's current content-size estimate.
    /// ChatTranscriptViewportGeometry republishes when either input changes.
    ///
    /// The spacer is layout, not scroll-content inset. Remove it from the model's
    /// content and usable viewport heights, report it as bottom obstruction, and
    /// reflect the native visible rect. On this path, `distanceFromBottom` then
    /// cancels the reflected content height and is exactly `visibleRect.minY`:
    /// distance from the native content origin, independent of the lazy estimate.
    func coordinatorGeometry(_ geometry: ScrollGeometry, obstruction: CGFloat = 0) -> ChatTranscriptGeometry {
        let contentHeight = geometry.contentSize.height
        let visibleTop = geometry.visibleRect.minY
        let visibleBottom = geometry.visibleRect.maxY
        return ChatTranscriptGeometry(
            offsetY: contentHeight - visibleBottom,
            contentHeight: contentHeight - obstruction,
            containerHeight: geometry.containerSize.height - obstruction,
            bottomInset: obstruction,
            visibleTopY: contentHeight - visibleBottom,
            visibleBottomY: contentHeight - visibleTop
        )
    }

    private func layoutEdge(_ transcriptEdge: Edge) -> Edge {
        switch transcriptEdge {
        case .top: return .bottom
        case .bottom: return .top
        default: return transcriptEdge
        }
    }

    private func layoutAnchor(_ transcriptAnchor: UnitPoint) -> UnitPoint {
        switch transcriptAnchor {
        case .top: return .bottom
        case .bottom: return .top
        default: return transcriptAnchor
        }
    }
}

/// A zero-copy spine over the same canonical items, carrying stable item IDs and
/// their layout positions for the owner's accessibility ordering.
struct ChatTranscriptOrderedElements<Base: RandomAccessCollection>: RandomAccessCollection
where Base.Element: Identifiable {
    struct Element: Identifiable {
        let item: Base.Element
        let spinePosition: Int
        var id: Base.Element.ID { item.id }
    }
    let base: Base
    let orientation: ChatTranscriptOrientation
    var startIndex: Int { 0 }
    var endIndex: Int { base.count }
    subscript(position: Int) -> Element {
        let source = orientation.visualPosition(ofSpinePosition: position, count: base.count)
        return Element(item: base[base.index(base.startIndex, offsetBy: source)], spinePosition: position)
    }
}

extension ChatTranscriptOrientation {
    func ordered<Base: RandomAccessCollection>(_ items: Base) -> ChatTranscriptOrderedElements<Base>
    where Base.Element: Identifiable {
        ChatTranscriptOrderedElements(base: items, orientation: self)
    }
}

/// Read obstructions in the unflipped space, but propose the entire viewport to
/// the transformed scroll view. Merely ignoring safe areas on the flip can still
/// shrink its native clip when keyboard + accessories cross the viewport center.
struct ChatTranscriptViewport<Content: View>: View {
    @ViewBuilder let content: (EdgeInsets) -> Content

    @ViewBuilder var body: some View {
        GeometryReader { insets in
            GeometryReader { viewport in
                content(insets.safeAreaInsets)
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .ignoresSafeArea(.all, edges: .vertical)
        }
    }
}

/// Clearance belongs INSIDE the lazy stack: newest first, oldest last. Native
/// underflow alignment then includes both obstructions in the content extent.
/// An outer newest spacer moves a detached reader; a margin runs ahead of closing
/// animation, and oldest margins can place short content behind navigation.
struct ChatTranscriptClearance: View {
    let height: CGFloat

    var body: some View {
        Color.clear.frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Applied native geometry and declared layout clearance have one owner. SwiftUI
/// may keep its lazy estimate unchanged when the spacer changes, so either input
/// republishes the model. These fields are deliberately not observable: geometry
/// publication must not schedule another view/layout pass.
@MainActor
final class ChatTranscriptViewportGeometry {
    private var native: ScrollGeometry?
    private var obstruction: CGFloat = 0
    private var published: ChatTranscriptGeometry = .zero

    func update(
        native: ScrollGeometry? = nil,
        obstruction: CGFloat,
        orientation: ChatTranscriptOrientation
    ) -> (previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry)? {
        if let native { self.native = native }
        self.obstruction = obstruction
        guard let applied = self.native else { return nil }
        let previous = published
        let current = orientation.coordinatorGeometry(applied, obstruction: self.obstruction)
        published = current
        return (previous, current)
    }
}

/// The origin-anchored spine supplies the accessibility order matching the
/// reader's oldest-to-newest visual order.
private struct ChatTranscriptVoiceOverOrderModifier: ViewModifier {
    let priority: Double

    func body(content: Content) -> some View {
        content.accessibilitySortPriority(priority)
    }
}

/// Viewport render transform and indicator margins. Both clearances belong
/// inside the lazy content (see ChatTranscriptClearance), so their animation
/// uses the same renderer/transaction as the obstructing component.
private struct ChatTranscriptViewportModifier: ViewModifier {
    let orientation: ChatTranscriptOrientation
    let safeAreaInsets: EdgeInsets

    @ViewBuilder
    func body(content: Content) -> some View {
        let margins = orientation.layoutClearance(for: safeAreaInsets)
        content
            .ignoresSafeArea(.container, edges: .vertical)
            .ignoresSafeArea(.keyboard, edges: .vertical)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .contentMargins(.top, margins.top, for: .scrollIndicators)
            .contentMargins(.bottom, margins.bottom, for: .scrollIndicators)
            .chatTranscriptOrientation(orientation)
            .ignoresSafeArea(.all, edges: .vertical)
    }
}

/// Applies the transcript flip outside row-local content. Each row applies the
/// same transform as its outermost modifier to keep its own rendering upright.
private struct ChatTranscriptOrientationModifier: ViewModifier {
    let orientation: ChatTranscriptOrientation

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: orientation.verticalScale)
    }
}

extension View {
    /// The reflected viewport needs a separate system-tap recipient. Mount inside
    /// its content for exact ancestry.
    func chatTranscriptStatusBar(
        active: Bool,
        scrollToOldest: @escaping () -> Void
    ) -> some View {
        background {
            ChatTranscriptStatusBar(active: active, scrollToOldest: scrollToOldest)
                .frame(width: 0, height: 0)
        }
    }

    /// Native anchoring and edge effects are shared by main and child transcripts.
    /// `underflowAt` lets a short read-only child sheet remain top-aligned.
    func chatTranscriptScrollBehavior(
        _ orientation: ChatTranscriptOrientation,
        sizeChangesPinned: Bool,
        position: Binding<ScrollPosition>,
        underflowAt edge: Edge = .bottom
    ) -> some View {
        defaultScrollAnchor(orientation.newestEndAnchor, for: .initialOffset)
            .defaultScrollAnchor(edge == .bottom ? orientation.newestEndAnchor : orientation.oldestEndAnchor, for: .alignment)
            .defaultScrollAnchor(sizeChangesPinned ? orientation.newestEndAnchor : orientation.oldestEndAnchor, for: .sizeChanges)
            .scrollPosition(position)
            .scrollEdgeEffectHidden(true, for: Edge.Set(orientation.newestEdge))
    }

    /// Renders this view in the transcript's orientation. The transcript applies
    /// it to its scroll view and each row applies it to its own element.
    func chatTranscriptOrientation(_ orientation: ChatTranscriptOrientation) -> some View {
        modifier(ChatTranscriptOrientationModifier(orientation: orientation))
    }

    /// Applies the scroll viewport's margins, flip and safe-area exclusion
    /// together. Row counter-flips do not inherit viewport layout modifiers.
    func chatTranscriptViewport(
        _ orientation: ChatTranscriptOrientation,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        modifier(
            ChatTranscriptViewportModifier(
                orientation: orientation,
                safeAreaInsets: safeAreaInsets
            )
        )
    }

    /// Gives this transcript element the accessibility order the reader sees:
    /// the priority the orientation owner computes for the element's own
    /// position in the content spine.
    func chatTranscriptVoiceOverOrder(
        _ orientation: ChatTranscriptOrientation,
        spinePosition: Int
    ) -> some View {
        modifier(
            ChatTranscriptVoiceOverOrderModifier(
                priority: orientation.voiceOverSortPriority(forSpinePosition: spinePosition)
            )
        )
    }
}
