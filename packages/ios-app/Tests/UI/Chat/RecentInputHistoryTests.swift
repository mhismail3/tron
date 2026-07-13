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

    func testRecentInputHistoryMenuActionVisibilityRequiresLocalHistoryIdleAndEditable() {
        let history = InputHistoryStore()
        history.clearHistory()

        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowMenuAction(
            inputHistory: history,
            agentPhase: .idle,
            readOnly: false
        ))

        history.addToHistory("Summarize the current workspace")

        XCTAssertTrue(RecentInputHistoryPresentation.shouldShowMenuAction(
            inputHistory: history,
            agentPhase: .idle,
            readOnly: false
        ))
        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowMenuAction(
            inputHistory: history,
            agentPhase: .processing,
            readOnly: false
        ))
        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowMenuAction(
            inputHistory: history,
            agentPhase: .idle,
            readOnly: true
        ))
        XCTAssertFalse(RecentInputHistoryPresentation.shouldShowMenuAction(
            inputHistory: nil,
            agentPhase: .idle,
            readOnly: false
        ))
    }

    func testRecentInputHistoryLabelsUseApprovedCopy() {
        XCTAssertEqual(RecentInputHistoryPresentation.title, "Recent Inputs")
        XCTAssertEqual(RecentInputHistoryPresentation.clearSystemImage, "trash")
        XCTAssertEqual(RecentInputHistoryPresentation.clearAccessibilityLabel, "Clear recent inputs")
        XCTAssertEqual(RecentInputHistoryPresentation.clearConfirmationTitle, "Clear recent inputs?")
        XCTAssertEqual(RecentInputHistoryPresentation.clearConfirmationActionTitle, "Clear Recent Inputs")
        XCTAssertFalse(RecentInputHistoryPresentation.clearConfirmationMessage.isEmpty)
        XCTAssertEqual(RecentInputHistoryPresentation.rowFontSize, TronTypography.sizeBody)
        XCTAssertEqual(RecentInputHistoryPresentation.rowLineLimit, 1)
        XCTAssertEqual(RecentInputHistoryPresentation.rowVerticalInset, 5)
        XCTAssertEqual(RecentInputHistoryPresentation.rowHorizontalInset, 18)
        XCTAssertFalse(RecentInputHistoryPresentation.title.contains("Library"))
    }

    func testRecentInputPreviewMarksOmittedMultilineContent() {
        XCTAssertEqual(
            RecentInputHistoryPresentation.preview(for: "Inspect the workspace\nThen summarize failures"),
            "Inspect the workspace…"
        )
        XCTAssertEqual(
            RecentInputHistoryPresentation.preview(for: "\n  First meaningful line  \r\nSecond line"),
            "First meaningful line…"
        )
        XCTAssertEqual(
            RecentInputHistoryPresentation.preview(for: "Single line prompt"),
            "Single line prompt"
        )
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
