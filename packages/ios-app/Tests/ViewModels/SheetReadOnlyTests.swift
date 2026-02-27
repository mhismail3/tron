import XCTest
@testable import TronMobile

final class SheetReadOnlyTests: XCTestCase {

    // MARK: - Idle + Not Deleted = Editable

    func testSheetReadOnly_idleAndNotDeleted_isFalse() {
        XCTAssertFalse(
            SheetReadOnlyPolicy.isReadOnly(workspaceDeleted: false, agentPhase: .idle)
        )
    }

    // MARK: - Active Agent = Read Only

    func testSheetReadOnly_processingAndNotDeleted_isTrue() {
        XCTAssertTrue(
            SheetReadOnlyPolicy.isReadOnly(workspaceDeleted: false, agentPhase: .processing)
        )
    }

    func testSheetReadOnly_postProcessingAndNotDeleted_isTrue() {
        XCTAssertTrue(
            SheetReadOnlyPolicy.isReadOnly(workspaceDeleted: false, agentPhase: .postProcessing)
        )
    }

    // MARK: - Workspace Deleted = Read Only

    func testSheetReadOnly_idleAndDeleted_isTrue() {
        XCTAssertTrue(
            SheetReadOnlyPolicy.isReadOnly(workspaceDeleted: true, agentPhase: .idle)
        )
    }

    func testSheetReadOnly_processingAndDeleted_isTrue() {
        XCTAssertTrue(
            SheetReadOnlyPolicy.isReadOnly(workspaceDeleted: true, agentPhase: .processing)
        )
    }
}
