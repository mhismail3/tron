import SwiftUI
import TronMobileCore

enum ChatTranscriptOrientation: Equatable, Sendable {
    case newestAtOrigin

    fileprivate var verticalScale: CGFloat { -1 }

    var newestEdge: Edge { layoutEdge(.bottom) }
    var oldestEdge: Edge { layoutEdge(.top) }

    var newestEndAnchor: UnitPoint { layoutAnchor(.bottom) }

    var oldestEndAnchor: UnitPoint { layoutAnchor(.top) }

    func paddingEdgeSet(_ transcriptEdge: Edge) -> Edge.Set {
        switch layoutEdge(transcriptEdge) {
        case .top: return .top
        case .bottom: return .bottom
        default: return .all
        }
    }

    func screenOffset(forLayoutRise rise: CGFloat) -> CGFloat { rise * verticalScale }

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

    func correctedOffsetY(
        currentModelOffsetY: CGFloat,
        visualOffset: CGFloat
    ) -> CGFloat {
        currentModelOffsetY - visualOffset
    }

    func scrollOffsetY(
        forModelOffsetY modelOffsetY: CGFloat,
        geometry: ChatTranscriptGeometry
    ) -> CGFloat {
        guard geometry.isValid else { return modelOffsetY }
        let pinnedModelOffsetY = geometry.offsetY + geometry.distanceFromBottom
        return (pinnedModelOffsetY - modelOffsetY)
    }

    func layoutClearance(for safeAreaInsets: EdgeInsets) -> EdgeInsets {
        return EdgeInsets(
            top: safeAreaInsets.bottom,
            leading: 0,
            bottom: safeAreaInsets.top,
            trailing: 0
        )
    }

    func voiceOverSortPriority(forSpinePosition spinePosition: Int) -> Double {
        Double(spinePosition)
    }

    func visualPosition(ofSpinePosition position: Int, count: Int) -> Int {
        count - 1 - position
    }

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

struct ChatTranscriptViewport<Content: View>: View {
    var sheetTop: CGFloat? = nil
    @ViewBuilder let content: (EdgeInsets) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSceneInsets: EdgeInsets?

    @ViewBuilder var body: some View {
        GeometryReader { insets in
            GeometryReader { viewport in
                content(covered(obstructions(live: insets.safeAreaInsets), viewport: viewport.frame(in: .global)))
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }
            .ignoresSafeArea(.all, edges: .vertical)
            .onChange(of: ActiveSceneInsets(active: scenePhase == .active, insets: insets.safeAreaInsets),
                      initial: true) { _, current in
                if current.active { activeSceneInsets = current.insets }
            }
        }
    }

    private func covered(_ insets: EdgeInsets, viewport: CGRect) -> EdgeInsets {
        guard let sheetTop else { return insets }
        var covered = insets
        covered.bottom = max(insets.bottom, viewport.maxY - sheetTop)
        return covered
    }

    private func obstructions(live: EdgeInsets) -> EdgeInsets {
        guard scenePhase != .active, let activeSceneInsets else { return live }
        return activeSceneInsets
    }
}

private struct ActiveSceneInsets: Equatable {
    let active: Bool
    let insets: EdgeInsets
}

struct ChatTranscriptClearance: View {
    let height: CGFloat

    var body: some View {
        Color.clear.frame(height: height)
            .accessibilityHidden(true)
    }
}

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

private struct ChatTranscriptVoiceOverOrderModifier: ViewModifier {
    let priority: Double

    func body(content: Content) -> some View {
        content.accessibilitySortPriority(priority)
    }
}

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

private struct ChatTranscriptOrientationModifier: ViewModifier {
    let orientation: ChatTranscriptOrientation

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: orientation.verticalScale)
    }
}

extension View {
    func chatTranscriptStatusBar(
        active: Bool,
        scrollToOldest: @escaping () -> Void
    ) -> some View {
        background {
            ChatTranscriptStatusBar(active: active, scrollToOldest: scrollToOldest)
                .frame(width: 0, height: 0)
        }
    }

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

    func chatTranscriptOrientation(_ orientation: ChatTranscriptOrientation) -> some View {
        modifier(ChatTranscriptOrientationModifier(orientation: orientation))
    }

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
