import XCTest
import SwiftUI
@testable import TronMobile

final class DiffFormattingTests: XCTestCase {

    // MARK: - marker

    func test_marker_addition_returnsPlus() {
        XCTAssertEqual(DiffFormatting.marker(for: .addition), "+")
    }

    func test_marker_deletion_returnsMinus() {
        XCTAssertEqual(DiffFormatting.marker(for: .deletion), "\u{2212}")
    }

    func test_marker_context_returnsEmpty() {
        XCTAssertEqual(DiffFormatting.marker(for: .context), "")
    }

    func test_marker_separator_returnsEmpty() {
        XCTAssertEqual(DiffFormatting.marker(for: .separator), "")
    }

    // MARK: - markerColor

    func test_markerColor_addition_returnsTronSuccess() {
        XCTAssertEqual(DiffFormatting.markerColor(for: .addition), .tronSuccess)
    }

    func test_markerColor_deletion_returnsTronError() {
        XCTAssertEqual(DiffFormatting.markerColor(for: .deletion), .tronError)
    }

    func test_markerColor_context_returnsClear() {
        XCTAssertEqual(DiffFormatting.markerColor(for: .context), .clear)
    }

    func test_markerColor_separator_returnsClear() {
        XCTAssertEqual(DiffFormatting.markerColor(for: .separator), .clear)
    }

    // MARK: - lineNumColor

    func test_lineNumColor_addition_returnsTronSuccess() {
        XCTAssertEqual(DiffFormatting.lineNumColor(for: .addition), .tronSuccess)
    }

    func test_lineNumColor_deletion_returnsTronError() {
        XCTAssertEqual(DiffFormatting.lineNumColor(for: .deletion), .tronError)
    }

    func test_lineNumColor_context_returnsTronTextMuted() {
        XCTAssertEqual(DiffFormatting.lineNumColor(for: .context), .tronTextMuted)
    }

    func test_lineNumColor_separator_returnsTronTextMuted() {
        XCTAssertEqual(DiffFormatting.lineNumColor(for: .separator), .tronTextMuted)
    }

    // MARK: - lineBackground

    func test_lineBackground_addition_returnsSuccessOpacity() {
        XCTAssertEqual(DiffFormatting.lineBackground(for: .addition), Color.tronSuccess.opacity(0.08))
    }

    func test_lineBackground_deletion_returnsErrorOpacity() {
        XCTAssertEqual(DiffFormatting.lineBackground(for: .deletion), Color.tronError.opacity(0.08))
    }

    func test_lineBackground_context_returnsClear() {
        XCTAssertEqual(DiffFormatting.lineBackground(for: .context), .clear)
    }

    func test_lineBackground_separator_returnsClear() {
        XCTAssertEqual(DiffFormatting.lineBackground(for: .separator), .clear)
    }
}
