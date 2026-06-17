import XCTest
@testable import TronMobile

final class ChatTimelineAuxiliaryStateTests: XCTestCase {
    func testLoadingWinsUntilInitialLoadCompletes() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: false,
                messagesIsEmpty: true,
                workspaceDeleted: false
            ),
            .loading
        )
    }

    func testEmptyShowsOnlyAfterInitialLoadWithNoMessages() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: true,
                messagesIsEmpty: true,
                workspaceDeleted: false
            ),
            .empty
        )
    }

    func testMessagesSuppressAuxiliaryState() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: false,
                messagesIsEmpty: false,
                workspaceDeleted: false
            ),
            .none
        )
    }

    func testWorkspaceDeletedSuppressesEmptyState() {
        XCTAssertEqual(
            ChatTimelineAuxiliaryState.derive(
                initialLoadComplete: true,
                messagesIsEmpty: true,
                workspaceDeleted: true
            ),
            .none
        )
    }
}
