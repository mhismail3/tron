import SwiftUI
import TronMobileCore

/// The one owner of the transcript's vertical orientation (CT-23).
///
/// Today's transcript puts the newest row at the end of a `LazyVStack`, so the
/// pinned bottom it keeps depends on that stack's own content estimate. CT-23
/// flips the transcript's scroll view so the newest row is at the exact content
/// origin, which the lazy stack lays out exactly; history it has not loaded lies
/// beyond the viewport, where an estimate only sizes the scroll range.
///
/// Everything that has to agree about which end is newest lives here: the render
/// flip on the scroll view, the counter-flip each element applies, the order the
/// row spine presents, the layout edge, anchor and padding set a name maps to,
/// the sign a layout offset keeps, and the geometry the coordinator reads.
/// Callers keep naming the transcript's own ends — `.bottom` is the pinned end
/// that holds the newest row, `.top` the visual top where older history lives —
/// or ask the semantic questions below. None of them branches on the flip.
enum ChatTranscriptOrientation: Equatable, Sendable {
    /// The newest row sits at the content end, which is a lazy estimate.
    case newestAtEnd
    /// The newest row sits at the content origin, which is exact.
    case newestAtOrigin

    /// The development switch. Today's path is the default, and only a hosted
    /// build (including optimized DevicePerformance) can select the origin-anchored
    /// path: a whole hosted run selects it
    /// with `TRON_CHAT_TRANSCRIPT_ORIENTATION=origin`, so one suite runs both
    /// ways against the same committed reference.
    static let selected: ChatTranscriptOrientation = {
        #if HOSTED_TEST
        if ProcessInfo.processInfo.environment["TRON_CHAT_TRANSCRIPT_ORIENTATION"] == "origin" {
            return .newestAtOrigin
        }
        #endif
        return .newestAtEnd
    }()

    /// The vertical render scale the transcript applies. Every element of the
    /// transcript's content applies the same value as its outermost modifier:
    /// that counter-flip cancels the transcript's flip for the element's own
    /// content while leaving its position in the origin-anchored order, so
    /// row-local transforms (the entrance rise, streaming growth, the queued
    /// card's shrink) render exactly as they do today.
    fileprivate var verticalScale: CGFloat { self == .newestAtOrigin ? -1 : 1 }

    // MARK: Semantic questions the product asks

    /// Whether the transcript's content spine presents the newest row first.
    /// The origin-anchored transcript's first content element is the newest row
    /// and its last is the oldest loaded history.
    var presentsNewestRowFirst: Bool { self == .newestAtOrigin }

    /// Whether the newest row arrives with the content's first layout pass, with
    /// no lazy realization of its own. The origin-anchored transcript's first
    /// element is laid out before anything the reader can see, so nothing has to
    /// materialize it and no materialization lease exists to certify the
    /// entrance that owes a layout transaction.
    var mountsNewestRowWithContent: Bool { self == .newestAtOrigin }

    /// Whether the transcript suppresses the automatic scroll edge effect at its
    /// pinned end.
    ///
    /// iOS 26 derives that effect from the scroll view's own content origin: the
    /// origin-anchored transcript pins the newest row exactly at that origin, and
    /// UIKit then draws the whole soft effect over the whole viewport instead of a
    /// band, washing the transcript's text out (measured on the owned simulator's
    /// own screen, CT-23 stage 2: the parity region's frames differ by 0.105 with
    /// the effect and 0.018 with it suppressed, and the pinned newest row is
    /// inside the wash). Today's transcript pins at the far end of its content, so
    /// its own top edge effect is the normal band it has always been. The chat's
    /// top blur is drawn by the transcript itself and is the same on both paths.
    var suppressesPinnedEndScrollEdgeEffect: Bool { false }

    /// Whether the pinned newest end depends on the lazy stack's estimate.
    /// Materialization and repair mechanisms are retained only on this path
    /// until CT-19 removes them with their owning regressions.
    var pinsToEstimatedOrigin: Bool { self == .newestAtEnd }

    // MARK: The layout the transcript's own ends map to

    /// The scroll view's layout edge that holds the newest row.
    var newestEdge: Edge { layoutEdge(.bottom) }

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
    /// transcript, increasing downward, exactly as today's transcript reports
    /// its own frames.
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
    func transcriptFrame(_ frame: CGRect, containerHeight: CGFloat) -> CGRect {
        guard self == .newestAtOrigin, containerHeight > 0 else { return frame }
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
    /// Today's model offset is the scroll view's own content offset, so it moves
    /// with the content and is clamped at the content's top. The origin-anchored
    /// transcript's model offset is the reflection of that offset, so it moves
    /// against the content, and its legal ends are the native scroll view's own
    /// — which clamps an out-of-range target itself.
    func correctedOffsetY(
        currentModelOffsetY: CGFloat,
        visualOffset: CGFloat
    ) -> CGFloat {
        switch self {
        case .newestAtEnd:
            return max(0, currentModelOffsetY + visualOffset)
        case .newestAtOrigin:
            return currentModelOffsetY - visualOffset
        }
    }

    /// The scroll view's own `scrollTo(y:)` offset for a point in the model the
    /// coordinator reasons in.
    ///
    /// Today's transcript reports the scroll view's offset as its model offset.
    /// The origin-anchored transcript reports the reflection of it, so a command
    /// computed in the model — the staged catch-up's point, a correction's
    /// target — has to be reflected back before it reaches the scroll view, or
    /// it becomes a jump of the same size in the opposite direction: thousands
    /// of points into the oldest loaded history instead of a point near the
    /// newest row.
    ///
    /// The model's own `distanceFromBottom` is the reverse of its offset, so the
    /// two share one anchor — the model offset at the pinned end — and a target's
    /// distance from that end is what a native offset is built from. The
    /// composer/keyboard inset is the model's bottom inset and sits at the
    /// scroll view's own origin on this path, so that distance is measured from
    /// `-bottomInset`.
    func scrollOffsetY(
        forModelOffsetY modelOffsetY: CGFloat,
        geometry: ChatTranscriptGeometry
    ) -> CGFloat {
        guard self == .newestAtOrigin, geometry.isValid else { return modelOffsetY }
        let pinnedModelOffsetY = geometry.offsetY + geometry.distanceFromBottom
        return (pinnedModelOffsetY - modelOffsetY) - geometry.bottomInset
    }

    /// Insets read by the unflipped transcript container are re-applied as
    /// margins only on the origin-anchored path. The flipped scroll view ignores
    /// these safe areas, so UIKit never receives a changing overlay inset.
    func scrollMargins(for safeAreaInsets: EdgeInsets) -> EdgeInsets {
        guard self == .newestAtOrigin else { return .init() }
        return EdgeInsets(
            top: safeAreaInsets.bottom,
            leading: 0,
            bottom: safeAreaInsets.top,
            trailing: 0
        )
    }

    /// The accessibility sort priority for the element at `spinePosition` of the
    /// transcript's content spine, which makes VoiceOver read the transcript in
    /// the order the reader sees it.
    ///
    /// VoiceOver reads a container's elements in the accessibility tree's own
    /// order, and that order follows the view order. Today's spine presents the
    /// oldest row first, which is also its visual order, so its elements need no
    /// priority at all (every element keeps the default `0`, and today's path is
    /// untouched). The origin-anchored spine presents the newest row first, so
    /// its view order is the reverse of its visual order: VoiceOver would read
    /// the transcript bottom-up and scroll it backwards. A sort priority is
    /// relative within the element's own accessibility container and sorts
    /// highest-first, so the spine's own position is the value that puts the
    /// oldest element first and the newest last.
    func voiceOverSortPriority(forSpinePosition spinePosition: Int) -> Double {
        guard presentsNewestRowFirst else { return 0 }
        return Double(spinePosition)
    }

    /// The transcript position a spine index reports: a row's position counted
    /// from the transcript's visual top, which is the position every diagnostic
    /// that names a row's place in the transcript reports. Today's spine presents
    /// the oldest row first, so its own index is that position; the
    /// origin-anchored spine presents the newest row first, so its positions are
    /// reversed.
    func visualPosition(ofSpinePosition position: Int, count: Int) -> Int {
        guard self == .newestAtOrigin else { return position }
        return count - 1 - position
    }

    /// The geometry the coordinator reads. Every field is derived from this one
    /// ScrollGeometry sample, so container size and applied insets are coherent
    /// even when successive callbacks in one frame differ. Both orientations report one model:
    /// `distanceFromBottom` is the distance from the newest row. The flipped
    /// scroll view's content origin is its visual bottom, so the visible rect is
    /// mirrored and the composer/keyboard inset, which the flip moves to the
    /// layout top, becomes the model's bottom inset.
    ///
    /// Container size and insets in this adapter come from the same native
    /// `ScrollGeometry` value: its `contentInsets` are the margins actually
    /// applied by the scroll view, not the safe-area values that sourced them.
    ///
    /// `visibleTopY` and `visibleBottomY` are the exact native rect: at the
    /// pinned origin the visible top is the inset above the content start, which
    /// is why the distance is exact rather than estimate-derived.
    func coordinatorGeometry(_ geometry: ScrollGeometry) -> ChatTranscriptGeometry {
        let contentHeight = geometry.contentSize.height
        guard self == .newestAtOrigin else {
            return ChatTranscriptGeometry(
                offsetY: geometry.contentOffset.y,
                contentHeight: contentHeight,
                containerHeight: geometry.containerSize.height,
                bottomInset: geometry.contentInsets.bottom,
                visibleTopY: geometry.visibleRect.minY,
                visibleBottomY: geometry.visibleRect.maxY
            )
        }
        let visibleTop = geometry.visibleRect.minY
        let visibleBottom = geometry.visibleRect.maxY
        return ChatTranscriptGeometry(
            offsetY: contentHeight - visibleBottom,
            contentHeight: contentHeight,
            containerHeight: geometry.containerSize.height,
            bottomInset: geometry.contentInsets.top,
            visibleTopY: contentHeight - visibleBottom,
            visibleBottomY: contentHeight - visibleTop
        )
    }

    private func layoutEdge(_ transcriptEdge: Edge) -> Edge {
        guard self == .newestAtOrigin else { return transcriptEdge }
        switch transcriptEdge {
        case .top: return .bottom
        case .bottom: return .top
        default: return transcriptEdge
        }
    }

    private func layoutAnchor(_ transcriptAnchor: UnitPoint) -> UnitPoint {
        guard self == .newestAtOrigin else { return transcriptAnchor }
        switch transcriptAnchor {
        case .top: return .bottom
        case .bottom: return .top
        default: return transcriptAnchor
        }
    }
}

/// The CT-23 accessibility order applies in both orientations. Today's owner
/// returns priority zero, preserving the default ordering, while the
/// origin-anchored owner supplies the reversed spine's visual order.
private struct ChatTranscriptVoiceOverOrderModifier: ViewModifier {
    let priority: Double

    func body(content: Content) -> some View {
        content.accessibilitySortPriority(priority)
    }
}

/// The origin-anchored inset adapter reads safe areas before the render flip,
/// ignores the scroll view's vertical container and keyboard safe areas, and
/// applies swapped values as scroll-content and indicator margins. Exclusion
/// inside the flip prevents UIKit overlay-inset adjustment; exclusion outside
/// keeps the transformed viewport from shrinking and clipping a detached row
/// when the keyboard crosses its center. Today's path bypasses both.
private struct ChatTranscriptViewportModifier: ViewModifier {
    let orientation: ChatTranscriptOrientation
    let safeAreaInsets: EdgeInsets

    @ViewBuilder
    func body(content: Content) -> some View {
        if orientation.presentsNewestRowFirst {
            let margins = orientation.scrollMargins(for: safeAreaInsets)
            content
                .ignoresSafeArea(.container, edges: .vertical)
                .ignoresSafeArea(.keyboard, edges: .vertical)
                .contentMargins(.top, margins.top, for: .scrollContent)
                .contentMargins(.bottom, margins.bottom, for: .scrollContent)
                .contentMargins(.top, margins.top, for: .scrollIndicators)
                .contentMargins(.bottom, margins.bottom, for: .scrollIndicators)
                .chatTranscriptOrientation(orientation)
                .ignoresSafeArea(.all, edges: .vertical)
        } else {
            content
        }
    }
}

/// Applies the transcript flip outside row-local content. Each row applies the
/// same transform as its outermost modifier to keep its own rendering upright.
private struct ChatTranscriptOrientationModifier: ViewModifier {
    let orientation: ChatTranscriptOrientation

    func body(content: Content) -> some View {
        if orientation.presentsNewestRowFirst {
            content.scaleEffect(x: 1, y: orientation.verticalScale)
        } else {
            content
        }
    }
}

extension View {
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
