import XCTest
@testable import TronMobile

final class ChatTimelineAuxiliaryStateTests: XCTestCase {
    func testLoadingWinsUntilInitialLoadCompletes() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: false,
                messagesIsEmpty: true
            ),
            .loading
        )
    }

    func testEmptyChatAfterInitialLoadStaysBlank() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: true,
                messagesIsEmpty: true
            ),
            .none
        )
    }

    func testMessagesSuppressAuxiliaryState() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: false,
                messagesIsEmpty: false
            ),
            .none
        )
    }
}
