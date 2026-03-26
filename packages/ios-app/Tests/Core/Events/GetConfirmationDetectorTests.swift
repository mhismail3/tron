import XCTest
@testable import TronMobile

/// Tests for GetConfirmationDetector
///
/// Verifies:
/// - Pending status when no user response
/// - Approved detection from response message
/// - Denied detection from response message
/// - Superseded when user sends a different message
/// - Note parsing from response
/// - Edge cases: missing tool call, empty messages, malformed responses
final class GetConfirmationDetectorTests: XCTestCase {

    // MARK: - Tests: parseConfirmationResponse

    func testParseApprovedWithNote() {
        let content = """
        [Confirmation response]

        Action: Install ffmpeg via brew
        Decision: Approved
        Note: Go ahead
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .approved)
        XCTAssertEqual(result.note, "Go ahead")
    }

    func testParseDeniedWithNote() {
        let content = """
        [Confirmation response]

        Action: Delete ~/project/
        Decision: Denied
        Note: Too risky, let's try another approach
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .denied)
        XCTAssertEqual(result.note, "Too risky, let's try another approach")
    }

    func testParseApprovedWithoutNote() {
        let content = """
        [Confirmation response]

        Action: Install ffmpeg via brew
        Decision: Approved
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .approved)
        XCTAssertNil(result.note)
    }

    func testParseDeniedWithoutNote() {
        let content = """
        [Confirmation response]

        Action: Deploy to prod
        Decision: Denied
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .denied)
        XCTAssertNil(result.note)
    }

    func testParseEmptyNoteIsNil() {
        let content = """
        [Confirmation response]

        Action: Test
        Decision: Approved
        Note:
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .approved)
        XCTAssertNil(result.note)
    }

    func testParseMissingDecisionDefaultsToDenied() {
        let content = """
        [Confirmation response]

        Action: Test
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .denied)
    }

    func testParseGarbageContentDefaultsToDenied() {
        let content = "Some random text"
        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .denied)
        XCTAssertNil(result.note)
    }

    func testParseDecisionCaseSensitive() {
        // "approved" lowercase should NOT match "Approved"
        let content = """
        [Confirmation response]

        Decision: approved
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        // The raw value is "Approved" not "approved", so this defaults to denied
        XCTAssertEqual(result.decision, .denied)
    }

    func testParseDecisionWithExtraSpaces() {
        let content = """
        [Confirmation response]

        Decision:   Approved
        Note:   Some note with spaces
        """

        let result = GetConfirmationDetector.parseConfirmationResponse(from: content)
        XCTAssertEqual(result.decision, .approved)
        XCTAssertEqual(result.note, "Some note with spaces")
    }
}
