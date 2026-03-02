import XCTest
import SwiftUI
@testable import TronMobile

final class LedgerFormattingTests: XCTestCase {

    // MARK: - colorForEntryType

    func test_colorForEntryType_feature_returnsGreen() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("feature"), .green)
    }

    func test_colorForEntryType_bugfix_returnsRed() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("bugfix"), .red)
    }

    func test_colorForEntryType_refactor_returnsCyan() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("refactor"), .cyan)
    }

    func test_colorForEntryType_docs_returnsBlue() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("docs"), .blue)
    }

    func test_colorForEntryType_config_returnsOrange() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("config"), .orange)
    }

    func test_colorForEntryType_research_returnsYellow() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("research"), .yellow)
    }

    func test_colorForEntryType_conversation_returnsPurple() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("conversation"), .purple)
    }

    func test_colorForEntryType_personal_returnsPink() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("personal"), .pink)
    }

    func test_colorForEntryType_preference_returnsMint() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("preference"), .mint)
    }

    func test_colorForEntryType_knowledge_returnsIndigo() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("knowledge"), .indigo)
    }

    func test_colorForEntryType_unknown_returnsSecondary() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("something_new"), .tronTextSecondary)
    }

    func test_colorForEntryType_isCaseInsensitive() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType("Feature"), .green)
        XCTAssertEqual(LedgerFormatting.colorForEntryType("BUGFIX"), .red)
        XCTAssertEqual(LedgerFormatting.colorForEntryType("Personal"), .pink)
    }

    func test_colorForEntryType_emptyString_returnsSecondary() {
        XCTAssertEqual(LedgerFormatting.colorForEntryType(""), .tronTextSecondary)
    }

    // MARK: - colorForFileOp

    func test_colorForFileOp_create_returnsGreen() {
        XCTAssertEqual(LedgerFormatting.colorForFileOp("C"), .green)
    }

    func test_colorForFileOp_modify_returnsYellow() {
        XCTAssertEqual(LedgerFormatting.colorForFileOp("M"), .yellow)
    }

    func test_colorForFileOp_delete_returnsRed() {
        XCTAssertEqual(LedgerFormatting.colorForFileOp("D"), .red)
    }

    func test_colorForFileOp_unknown_returnsMuted() {
        XCTAssertEqual(LedgerFormatting.colorForFileOp("X"), .tronTextMuted)
    }

    func test_colorForFileOp_isCaseInsensitive() {
        XCTAssertEqual(LedgerFormatting.colorForFileOp("c"), .green)
        XCTAssertEqual(LedgerFormatting.colorForFileOp("m"), .yellow)
        XCTAssertEqual(LedgerFormatting.colorForFileOp("d"), .red)
    }
}
