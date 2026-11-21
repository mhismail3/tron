import XCTest
@testable import TronMobile

@MainActor
final class ChatHapticsViewTests: ShuffledTestCase {
    private let chat = ["-tron-chat-haptics-fixture"]

    func testLiveEventsPlayTheirHapticOnce() async throws {
        try await mountHaptics(chat + ["-chat-haptics-photos", "3"]) { app in
            let field = try await openComposer(app)
            field.paste(nil)
            try await waitHaptics(app, "attachmentAdded,attachmentAdded,attachmentAdded")

            try await send("hello", app)
            var expected = "attachmentAdded,attachmentAdded,attachmentAdded,promptSent,runFinished"
            try await waitHaptics(app, expected)

            try await app.activate("fixture.deliver-worker")
            expected += ",workerMessage"
            try await waitHaptics(app, expected)

            try await app.activate("fixture.ask-question")
            expected += ",questionPresented"
            try await app.until("the question sheet") { app.button("Cancel form") != nil }
            try await waitHaptics(app, expected)

            try await app.activate("fixture.reopen-chat")
            try await app.until("the question sheet returns") { app.button("Cancel form") != nil }
            try await app.activate("Cancel form")
            try await app.until("the question sheet closes") { app.button("Cancel form") == nil }
            try await app.until("the answered question") { app.labelled("Ask user") != nil }
            XCTAssertTrue(try XCTUnwrap(app.labelled("Ask user")).accessibilityActivate())
            try await app.until("the cancelled answer") { app.staticText("Cancelled — no answers submitted") != nil }
            try await app.activate("Done")
            try await app.until("the answer sheet closes") { app.button("Done") == nil }
            expected += ",sheetPresented"
            try await assertHaptics(app, expected, "re-presenting and answering the question play nothing; its tool sheet taps once")

            try await send("fail", app)
            try await waitGateway(app, "rejected:1")
            expected += ",actionFailed"
            try await assertHaptics(app, expected, "a rejected send plays one error, never a success tap")

            try await send("slow", app)
            expected += ",promptSent"
            try await waitGateway(app, "phase:running")
            try await waitHaptics(app, expected)
            try await app.activate("Stop Tron")
            try await waitGateway(app, "aborts:1")
            try await waitGateway(app, "phase:idle")
            try await assertHaptics(app, expected, "a stopped run plays no completion")
        }
    }

    func testAttachmentTicksAreOnePerPhotoAndCapped() async throws {
        for (photos, ticks) in [(1, 1), (9, 6)] {
            try await mountHaptics(chat + ["-chat-haptics-photos", "\(photos)"]) { app in
                let field = try await openComposer(app)
                field.paste(nil)
                let expected = Array(repeating: "attachmentAdded", count: ticks).joined(separator: ",")
                try await waitHaptics(app, expected)
                try await assertHaptics(app, expected, "\(photos) photo(s) tick \(ticks) time(s)")
            }
        }
    }

    func testToolSheetPlaysOneImpactPerPresentation() async throws {
        try await mountHaptics(chat + ["-chat-haptics-photos", "0", "-chat-haptics-history"]) { app in
            try await app.until("the restored question") { app.button("Cancel form") != nil }
            try await app.activate("Cancel form")
            try await app.until("the restored question closes") { app.button("Cancel form") == nil }
            try await assertHaptics(app, "none", "the restored question and its dismissal play nothing")
            var expected: [String] = []
            for _ in 0..<2 {
                try await app.until("the tool row") { app.labelled("Ask user") != nil }
                XCTAssertTrue(try XCTUnwrap(app.labelled("Ask user")).accessibilityActivate())
                try await app.until("the tool sheet") { app.button("Done") != nil }
                expected.append("sheetPresented")
                try await waitHaptics(app, expected.joined(separator: ","))
                try await app.activate("Done")
                try await app.until("the tool sheet closes") { app.button("Done") == nil }
                try await assertHaptics(app, expected.joined(separator: ","), "dismissing the tool sheet plays nothing")
            }
        }
    }

    func testSheetPresentedAtMountPlaysNone() async throws {
        try await mountHaptics(["-tron-settings-fixture", "-sheet-haptics-restored"]) { app in
            try await app.until("the sheet at mount") { app.staticText("Sheet at mount") != nil }
            try await app.until("the haptics probe") { app.element("fixture.haptics") != nil }
            try await assertHaptics(app, "none", "a sheet presented at mount plays nothing")
            try await app.activate("Done")
            try await app.until("the sheet at mount closes") { app.staticText("Sheet at mount") == nil }
            try await assertHaptics(app, "none", "its dismissal plays nothing")
        }
    }

    func testAcceptedFormAnswerPlaysSuccessOnce() async throws {
        try await mountHaptics(chat + ["-chat-haptics-photos", "0"]) { app in
            _ = try await openComposer(app)
            try await app.activate("fixture.ask-question")
            try await app.until("the question sheet") { app.button("Cancel form") != nil }
            try await waitHaptics(app, "questionPresented")
            try await app.until("the staging option") { staging(app) != nil }
            XCTAssertTrue(try XCTUnwrap(staging(app)).accessibilityActivate())
            try await app.activate("Submit all answers")
            try await app.until("the question sheet closes") { app.button("Cancel form") == nil }
            try await assertHaptics(app, "questionPresented,answerSubmitted", "only an accepted answer confirms success; sheet dismissal stays silent")
            try await app.activate("fixture.reopen-chat")
            try await assertHaptics(app, "questionPresented,answerSubmitted", "replayed answers are silent")
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

    private func send(_ text: String, _ app: MountedFixture) async throws {
        try await app.until("the composer") { composer(app) != nil }
        composer(app)?.insertText(text)
        try await app.activate("Send message")
    }

    private func composer(_ app: MountedFixture) -> UITextView? {
        MountedFixture.views(UITextView.self, in: app.top).last { $0.accessibilityLabel == "Message input" }
    }

    private func staging(_ app: MountedFixture) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "").contains("Staging")
        }
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
