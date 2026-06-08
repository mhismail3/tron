import XCTest
@testable import TronMobile

/// Tests for InputBarState draft-related computed properties
@MainActor
final class InputBarStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeAttachment(id: UUID = UUID()) -> Attachment {
        Attachment(id: id, type: .image, data: Data([0x00]), mimeType: "image/jpeg", fileName: "test.jpg")
    }

    // MARK: - draftFingerprint

    func testDraftFingerprint_changesWithText() {
        let state = InputBarState()
        let fp1 = state.draftFingerprint

        state.text = "hello"
        let fp2 = state.draftFingerprint

        XCTAssertNotEqual(fp1, fp2)
    }

    func testDraftFingerprint_changesWithAttachments() {
        let state = InputBarState()
        let fp1 = state.draftFingerprint

        state.attachments = [makeAttachment()]
        let fp2 = state.draftFingerprint

        XCTAssertNotEqual(fp1, fp2)
    }

    func testDraftFingerprint_stableForSameState() {
        let state = InputBarState()
        state.text = "hello"

        let fp1 = state.draftFingerprint
        let fp2 = state.draftFingerprint

        XCTAssertEqual(fp1, fp2)
    }

    // MARK: - hasDraftContent

    func testHasDraftContent_emptyState_returnsFalse() {
        let state = InputBarState()
        XCTAssertFalse(state.hasDraftContent)
    }

    func testHasDraftContent_textOnly_returnsTrue() {
        let state = InputBarState()
        state.text = "hello"
        XCTAssertTrue(state.hasDraftContent)
    }

    func testHasDraftContent_attachmentsOnly_returnsTrue() {
        let state = InputBarState()
        state.attachments = [makeAttachment()]
        XCTAssertTrue(state.hasDraftContent)
    }

    func testHasDraftContent_whitespaceOnlyText_returnsFalse() {
        let state = InputBarState()
        state.text = "   \n\t  "
        XCTAssertFalse(state.hasDraftContent)
    }
}
