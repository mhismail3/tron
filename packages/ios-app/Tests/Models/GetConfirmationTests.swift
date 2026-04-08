import XCTest
@testable import TronMobile

/// Tests for GetConfirmation models and state handling
///
/// These tests verify:
/// - Model JSON decoding/encoding
/// - Status transitions
/// - Risk level enum behavior
/// - Tool data state management
/// - Edge cases (unicode, special characters)
final class GetConfirmationTests: XCTestCase {

    // MARK: - Tests: GetConfirmationParams Decoding

    func testParamsDecodingAllFields() throws {
        let json = """
        {
            "action": "Install ffmpeg via brew",
            "reason": "Needed for video processing",
            "riskLevel": "low"
        }
        """.data(using: .utf8)!

        let params = try JSONDecoder().decode(GetConfirmationParams.self, from: json)

        XCTAssertEqual(params.action, "Install ffmpeg via brew")
        XCTAssertEqual(params.reason, "Needed for video processing")
        XCTAssertEqual(params.riskLevel, .low)
    }

    func testParamsDecodingMediumRisk() throws {
        let json = """
        {"action": "Modify config", "reason": "Update settings", "riskLevel": "medium"}
        """.data(using: .utf8)!

        let params = try JSONDecoder().decode(GetConfirmationParams.self, from: json)
        XCTAssertEqual(params.riskLevel, .medium)
    }

    func testParamsDecodingHighRisk() throws {
        let json = """
        {"action": "Deploy to prod", "reason": "Release v2.0", "riskLevel": "high"}
        """.data(using: .utf8)!

        let params = try JSONDecoder().decode(GetConfirmationParams.self, from: json)
        XCTAssertEqual(params.riskLevel, .high)
    }

    func testParamsDecodingInvalidRiskLevel() throws {
        let json = """
        {"action": "Test", "reason": "Test", "riskLevel": "extreme"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(GetConfirmationParams.self, from: json))
    }

    // MARK: - Tests: ConfirmationRiskLevel

    func testRiskLevelRawValues() {
        XCTAssertEqual(ConfirmationRiskLevel.low.rawValue, "low")
        XCTAssertEqual(ConfirmationRiskLevel.medium.rawValue, "medium")
        XCTAssertEqual(ConfirmationRiskLevel.high.rawValue, "high")
    }

    func testRiskLevelEquatable() {
        XCTAssertEqual(ConfirmationRiskLevel.low, ConfirmationRiskLevel.low)
        XCTAssertNotEqual(ConfirmationRiskLevel.low, ConfirmationRiskLevel.high)
    }

    // MARK: - Tests: ConfirmationDecision

    func testDecisionRawValues() {
        XCTAssertEqual(ConfirmationDecision.approved.rawValue, "Approved")
        XCTAssertEqual(ConfirmationDecision.denied.rawValue, "Denied")
    }

    func testDecisionEncoding() throws {
        let encoder = JSONEncoder()
        let approvedData = try encoder.encode(ConfirmationDecision.approved)
        XCTAssertEqual(String(data: approvedData, encoding: .utf8), "\"Approved\"")

        let deniedData = try encoder.encode(ConfirmationDecision.denied)
        XCTAssertEqual(String(data: deniedData, encoding: .utf8), "\"Denied\"")
    }

    // MARK: - Tests: GetConfirmationStatus

    func testStatusEquatable() {
        XCTAssertEqual(GetConfirmationStatus.pending, GetConfirmationStatus.pending)
        XCTAssertEqual(GetConfirmationStatus.approved, GetConfirmationStatus.approved)
        XCTAssertEqual(GetConfirmationStatus.denied, GetConfirmationStatus.denied)
        XCTAssertEqual(GetConfirmationStatus.superseded, GetConfirmationStatus.superseded)
        XCTAssertEqual(GetConfirmationStatus.generating, GetConfirmationStatus.generating)
        XCTAssertNotEqual(GetConfirmationStatus.pending, GetConfirmationStatus.approved)
    }

    // MARK: - Tests: GetConfirmationResult

    func testResultApproved() throws {
        let result = GetConfirmationResult(
            decision: .approved,
            note: "Go ahead",
            submittedAt: "2026-03-26T10:00:00Z"
        )

        XCTAssertEqual(result.decision, .approved)
        XCTAssertEqual(result.note, "Go ahead")
        XCTAssertEqual(result.submittedAt, "2026-03-26T10:00:00Z")
    }

    func testResultDeniedNoNote() throws {
        let result = GetConfirmationResult(
            decision: .denied,
            note: nil,
            submittedAt: "2026-03-26T10:00:00Z"
        )

        XCTAssertEqual(result.decision, .denied)
        XCTAssertNil(result.note)
    }

    func testResultEncoding() throws {
        let result = GetConfirmationResult(
            decision: .approved,
            note: "LGTM",
            submittedAt: "2026-03-26T10:00:00Z"
        )

        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["decision"] as? String, "Approved")
        XCTAssertEqual(json?["note"] as? String, "LGTM")
        XCTAssertEqual(json?["submittedAt"] as? String, "2026-03-26T10:00:00Z")
    }

    // MARK: - Tests: GetConfirmationToolData

    func testToolDataInitialization() {
        let params = GetConfirmationParams(
            action: "Delete ~/old-project/",
            reason: "User requested cleanup",
            riskLevel: .high
        )

        let data = GetConfirmationToolData(
            toolCallId: "call_abc",
            params: params,
            status: .pending,
            decision: nil,
            note: nil,
            result: nil
        )

        XCTAssertEqual(data.toolCallId, "call_abc")
        XCTAssertEqual(data.params.action, "Delete ~/old-project/")
        XCTAssertEqual(data.params.riskLevel, .high)
        XCTAssertEqual(data.status, .pending)
        XCTAssertNil(data.decision)
        XCTAssertNil(data.note)
        XCTAssertNil(data.result)
    }

    func testToolDataStatusTransitions() {
        var data = GetConfirmationToolData(
            toolCallId: "call_abc",
            params: GetConfirmationParams(action: "Test", reason: "Test", riskLevel: .low),
            status: .generating
        )

        XCTAssertEqual(data.status, .generating)

        data.status = .pending
        XCTAssertEqual(data.status, .pending)

        data.status = .approved
        data.decision = .approved
        XCTAssertEqual(data.status, .approved)
        XCTAssertEqual(data.decision, .approved)
    }

    func testToolDataSuperseded() {
        var data = GetConfirmationToolData(
            toolCallId: "call_abc",
            params: GetConfirmationParams(action: "Test", reason: "Test", riskLevel: .low),
            status: .pending
        )

        data.status = .superseded
        XCTAssertEqual(data.status, .superseded)
    }

    func testToolDataEquality() {
        let params = GetConfirmationParams(action: "Test", reason: "Test", riskLevel: .low)

        let data1 = GetConfirmationToolData(
            toolCallId: "call_1",
            params: params,
            status: .pending
        )

        let data2 = GetConfirmationToolData(
            toolCallId: "call_1",
            params: params,
            status: .pending
        )

        let data3 = GetConfirmationToolData(
            toolCallId: "call_2",
            params: params,
            status: .pending
        )

        XCTAssertEqual(data1, data2)
        XCTAssertNotEqual(data1, data3)
    }

    // MARK: - Tests: Edge Cases

    func testUnicodeInParams() throws {
        let json = """
        {
            "action": "Delete ~/project-\u{1F4E6}/",
            "reason": "Cleanup requested \u{2705}",
            "riskLevel": "high"
        }
        """.data(using: .utf8)!

        let params = try JSONDecoder().decode(GetConfirmationParams.self, from: json)
        XCTAssertTrue(params.action.contains("\u{1F4E6}"))
        XCTAssertTrue(params.reason.contains("\u{2705}"))
    }

    func testLongActionAndReason() throws {
        let longAction = String(repeating: "a", count: 1000)
        let longReason = String(repeating: "b", count: 2000)
        let json = """
        {"action": "\(longAction)", "reason": "\(longReason)", "riskLevel": "medium"}
        """.data(using: .utf8)!

        let params = try JSONDecoder().decode(GetConfirmationParams.self, from: json)
        XCTAssertEqual(params.action.count, 1000)
        XCTAssertEqual(params.reason.count, 2000)
    }

}
