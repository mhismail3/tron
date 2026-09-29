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
    /// build can select the origin-anchored path: a whole hosted run selects it
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
    var suppressesPinnedEndScrollEdgeEffect: Bool { self == .newestAtOrigin }

    /// Whether the pinned end the transcript keeps is the lazy stack's own
    /// estimate. Every mechanism that materializes, repairs or proves that end
    /// exists for this case and is gated off while the anchor is the exact
    /// origin (not deleted: CT-19 removes them).
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

    /// The geometry the coordinator reads. Both orientations report one model:
    /// `distanceFromBottom` is the distance from the newest row. The flipped
    /// scroll view's content origin is its visual bottom, so the visible rect is
    /// mirrored and the composer/keyboard inset, which the flip moves to the
    /// layout top, becomes the model's bottom inset.
    ///
    /// The origin inset is the scroll view's own resolved content inset
    /// (`contentInsets.top`), the same value the scroll view applies: the flipped
    /// view's safe-area insets are already mirrored by the render transform (see
    /// `ChatTranscriptOrientationModifier`), so there is one inset source rather
    /// than a read plus a re-application.
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

/// The CT-23 render transform. A no-op on today's path, so both orientations run
/// the same view tree, and it is the one modifier both the transcript and each
/// of its rows apply: the transcript's flip puts the newest row at the exact
/// origin, and the row's own application of the same value cancels it for the
/// row's content while leaving the row's position in the origin-anchored order.
///
/// The flip is the whole inset mechanism: no margin is added and no safe area is
/// ignored, because the scroll view's own vertical safe-area insets arrive
/// already mirrored by the render transform. Measured on the origin-anchored path
/// through the keyboard's own inset (the CT-25 stage B1 driver, one driven
/// display boundary per curve step, hosted lane ct23): the scroll view's
/// `safeAreaInsets.top` is the composer/keyboard inset and its
/// `safeAreaInsets.bottom` is the navigation inset at every boundary — 53/116 at
/// rest, 389/116 with the keyboard up, 450.3/116 with a four-line draft — so the
/// composer inset lands at the content origin (the pinned newest row) and the
/// navigation inset at the far end, both as native content insets that ride the
/// keyboard's transaction.
///
/// Reading the insets in an unflipped `GeometryReader` and re-applying them
/// swapped is what the blueprint proposed, and it is wrong on this OS: the read
/// is doubled by the mirroring the scroll view already applies. With
/// `contentMargins(..., for: .scrollContent)` and `.ignoresSafeArea(.vertical)`
/// the scroll view's own safe area measured 166 pt at keyboard-up and 277.7 pt
/// with the four-line draft, added to the margin, so the newest row settled
/// 166-290 pt above the composer instead of at it.
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
}
