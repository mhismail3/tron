import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class RecentInputHistoryTests: XCTestCase {
    private let storageKey = "tron.inputHistory"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func render<V: View>(_ view: V) {
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    func testRecentInputHistoryButtonVisibilityRequiresLocalHistoryIdleAndEditable() {
        let history = InputHistoryStore()

        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowButton(
            inputHistory: history,
            agentPhase: .idle,
            readOnly: false
        ))

        history.addToHistory("Summarize the current workspace")

        XCTAssertTrue(RecentInputHistoryPresentation.shouldShowButton(
            inputHistory: history,
            agentPhase: .idle,
            readOnly: false
        ))
        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowButton(
            inputHistory: history,
            agentPhase: .processing,
            readOnly: false
        ))
        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowButton(
            inputHistory: history,
            agentPhase: .idle,
            readOnly: true
        ))
        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowButton(
            inputHistory: nil,
            agentPhase: .idle,
            readOnly: false
        ))
    }

    func testRecentInputHistoryLabelsUseApprovedCopy() {
        XCTAssertEqual(RecentInputHistoryPresentation.title, "Recent Inputs")
        XCTAssertEqual(RecentInputHistoryPresentation.buttonAccessibilityLabel, "Show recent inputs")
        XCTAssertEqual(RecentInputHistoryPresentation.clearSystemImage, "trash")
        XCTAssertEqual(RecentInputHistoryPresentation.clearAccessibilityLabel, "Clear recent inputs")
        XCTAssertEqual(RecentInputHistoryPresentation.rowFontSize, TronTypography.sizeBody)
        XCTAssertEqual(RecentInputHistoryPresentation.rowLineLimit, 2)
        XCTAssertEqual(RecentInputHistoryPresentation.rowVerticalPadding, 2)
        XCTAssertFalse(RecentInputHistoryPresentation.title.contains("Library"))
    }

    func testRecentInputsSheetConstructs() {
        let history = InputHistoryStore()
        history.addToHistory("Draft a short release note")

        render(
            RecentInputHistorySheet(
                historyStore: history,
                onSelect: { _ in }
            )
        )
    }

    func testRecentInputSelectionCallbackInsertsSelectedText() {
        let selected = "Explain the latest failing test"
        var inserted: String?

        let sheet = RecentInputHistorySheet(
            historyStore: InputHistoryStore(),
            onSelect: { inserted = $0 }
        )
        sheet.onSelect(selected)

        XCTAssertEqual(inserted, selected)
    }
}
