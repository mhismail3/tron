import CoreGraphics
import Foundation
import Testing
@testable import TronMobile

@Suite("ScrollViewportAnchor Tests")
struct ScrollViewportAnchorTests {
    @Test("captures first visible message identity")
    func capturesFirstVisibleMessageIdentity() {
        let first = UUID()
        let second = UUID()

        let anchor = ScrollViewportAnchorResolver.capture(
            frames: [
                first: CGRect(x: 0, y: -24, width: 300, height: 120),
                second: CGRect(x: 0, y: 108, width: 300, height: 80)
            ],
            viewportHeight: 700,
            orderedMessageIds: [first, second]
        )

        #expect(anchor?.messageId == first)
    }

    @Test("ignores offscreen messages")
    func ignoresOffscreenMessages() {
        let above = UUID()
        let visible = UUID()
        let below = UUID()

        let anchor = ScrollViewportAnchorResolver.capture(
            frames: [
                above: CGRect(x: 0, y: -180, width: 300, height: 100),
                visible: CGRect(x: 0, y: 12, width: 300, height: 90),
                below: CGRect(x: 0, y: 900, width: 300, height: 90)
            ],
            viewportHeight: 700,
            orderedMessageIds: [above, visible, below]
        )

        #expect(anchor?.messageId == visible)
    }

    @Test("is nil without measured viewport")
    func nilWithoutMeasuredViewport() {
        let id = UUID()

        let anchor = ScrollViewportAnchorResolver.capture(
            frames: [id: CGRect(x: 0, y: 0, width: 300, height: 100)],
            viewportHeight: 0,
            orderedMessageIds: [id]
        )

        #expect(anchor == nil)
    }
}
