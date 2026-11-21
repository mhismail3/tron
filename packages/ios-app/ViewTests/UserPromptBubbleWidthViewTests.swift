import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class UserPromptBubbleWidthViewTests: ShuffledTestCase {
    func testWrappedPromptBubbleHugsItsWidestLine() async throws {
        let cases: [([String], UIContentSizeCategory)] = [(["-annotation-light"], .large), ([], .large), ([], .extraExtraExtraLarge)]
        for (extra, size) in cases {
            try await mounted(["-tron-chat-annotation-fixture", "-annotation-wrapped-prompt"] + extra, contentSize: size) { app in
                @MainActor func bubble(_ text: String) -> (label: CGRect, surface: CGRect, widest: CGFloat)? {
                    guard let label = MountedFixture.views(UILabel.self, in: app.top)
                        .first(where: { $0.attributedText?.string == text && $0.window != nil }),
                          let attributed = label.attributedText else { return nil }
                    var view = label.superview
                    while let current = view, !String(describing: type(of: current)).contains("ChatMessageNativeContent") {
                        view = current.superview
                    }
                    guard let surface = view else { return nil }
                    let frame = label.convert(label.bounds, to: nil)
                    let widest = ceil(attributed.boundingRect(
                        with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                    ).width)
                    return (frame, surface.convert(surface.bounds, to: nil), widest)
                }
                try await app.until("both prompts are drawn") {
                    bubble(HostedChatAnnotationFixture.wrappedPrompt) != nil && bubble("Status?") != nil
                }
                let wrapped = bubble(HostedChatAnnotationFixture.wrappedPrompt)!
                let short = bubble("Status?")!
                XCTAssertGreaterThan(wrapped.label.height, short.label.height * 1.5, "The fixture prompt must wrap\n\(app.tree())")
                XCTAssertLessThanOrEqual(wrapped.surface.width, wrapped.widest + 2 * ChatPromptContainerStyle.horizontalPadding + 2,
                                         "The bubble hugs its widest wrapped line (\(size.rawValue)): \(wrapped)")
                XCTAssertEqual(wrapped.surface.maxX, short.surface.maxX, accuracy: 1, "Prompt bubbles stay right-aligned")
                let attachment = XCTAttachment(image: app.render())
                attachment.name = "wrapped-bubble-\(extra.isEmpty ? "dark" : "light")-\(size.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
