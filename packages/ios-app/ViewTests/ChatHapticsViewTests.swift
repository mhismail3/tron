import XCTest
@testable import TronMobile

@MainActor
final class ChatHapticsViewTests: ShuffledTestCase {
    func testAttachmentTicksAreOnePerPhotoAndCapped() async throws {
        for (photos, ticks) in [(1, 1), (9, 6)] {
            try await mountHaptics(["-tron-chat-haptics-fixture", "-chat-haptics-photos", "\(photos)"]) { app in
                let field = try await openComposer(app)
                field.paste(nil)
                let expected = Array(repeating: "attachmentAdded", count: ticks).joined(separator: ",")
                try await waitHaptics(app, expected)
                try await assertHaptics(app, expected, "\(photos) photo(s) tick \(ticks) time(s)")
            }
        }
    }

    private func mountHaptics(_ arguments: [String], _ body: (MountedFixture) async throws -> Void) async throws {
        TronHapticsProbe.shared.played = []
        try await mounted(arguments, body)
    }

    private func openComposer(_ app: MountedFixture) async throws -> UITextView {
        try await app.until("the composer") { composer(app) != nil }
        try await waitGateway(app, "opens:1")
        try await assertHaptics(app, "none", "opening the chat plays nothing")
        return try XCTUnwrap(composer(app))
    }

    private func composer(_ app: MountedFixture) -> UITextView? {
        MountedFixture.views(UITextView.self, in: app.top).last { $0.accessibilityLabel == "Message input" }
    }

    private func waitHaptics(_ app: MountedFixture, _ played: String) async throws {
        try await app.until("haptics:\(played)") { app.element("fixture.haptics")?.accessibilityLabel == "haptics:\(played)" }
    }

    private func waitGateway(_ app: MountedFixture, _ fragment: String) async throws {
        try await app.until("gateway \(fragment)") { app.element("fixture.gateway")?.accessibilityLabel?.contains(fragment) == true }
    }

    private func assertHaptics(_ app: MountedFixture, _ played: String, _ message: String) async throws {
        for _ in 0..<60 { await MountedFixture.nextFrame() }
        XCTAssertEqual(app.element("fixture.haptics")?.accessibilityLabel, "haptics:\(played)", message)
    }
}
