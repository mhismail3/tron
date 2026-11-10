import OSLog
import SwiftUI
import UIKit

private struct ChatOwnsStatusBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatOwnsStatusBar: Bool {
        get { self[ChatOwnsStatusBarKey.self] }
        set { self[ChatOwnsStatusBarKey.self] = newValue }
    }
}

struct ChatChipStrip<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        let frameAlignment: Alignment = alignment == .trailing ? .trailing : .leading
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .chatSecondaryScrollContent()
        }
        .scrollClipDisabled()
        .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

extension View {
    func chatSecondaryScrollContent() -> some View {
        modifier(ChatSecondaryScrollModifier())
    }
}

private struct ChatSecondaryScrollModifier: ViewModifier {
    @Environment(\.chatOwnsStatusBar) private var chatOwnsStatusBar
    func body(content: Content) -> some View {
        content.background {
            if chatOwnsStatusBar { ChatSecondaryScrollProbe().frame(width: 0, height: 0) }
        }
    }
}

private struct ChatSecondaryScrollProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.reconcile() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        private weak var owner: UIScrollView?
        private var previous = true
        private var reported = false
        override func didMoveToWindow() { super.didMoveToWindow(); reconcile() }
        override func layoutSubviews() { super.layoutSubviews(); reconcile() }
        func reconcile() {
            guard window != nil else { restore(); return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else {
                restore()
                if !reported {
                    reported = true
                    Logger(subsystem: "com.tron.mobile", category: "ChatTranscriptOrientation")
                        .error("Secondary scroll status-bar exclusion unavailable: no enclosing scroll view")
                }
                return
            }
            guard owner !== scroll else { return }
            restore()
            owner = scroll
            previous = scroll.scrollsToTop
            scroll.scrollsToTop = false
        }
        func restore() {
            if let owner, !owner.scrollsToTop { owner.scrollsToTop = previous }
            owner = nil
        }
    }
}
