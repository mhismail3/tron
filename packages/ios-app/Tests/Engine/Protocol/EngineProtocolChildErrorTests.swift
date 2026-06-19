import XCTest
@testable import TronMobile

final class EngineProtocolChildErrorTests: XCTestCase {
    func testChildErrorWithoutCanonicalFailureMapsToProtocolError() throws {
        let json = """
        {
            "kind": "not_found",
            "message": "function not found: filesystem::get_home",
            "details": {
                "id": "filesystem::get_home",
                "kind": "function"
            }
        }
        """.data(using: .utf8)!

        let childError = try JSONDecoder().decode(EngineChildError.self, from: json)
        let protocolError = childError.protocolError

        XCTAssertEqual(protocolError.code, EngineErrorCode.capabilityNotFound.rawValue)
        XCTAssertEqual(protocolError.category, "not_found")
        XCTAssertEqual(protocolError.message, "function not found: filesystem::get_home")
        XCTAssertEqual(protocolError.origin, "engine")
        XCTAssertTrue(protocolError.recoverable)
        XCTAssertFalse(protocolError.retryable)
        XCTAssertEqual(protocolError.details?["id"]?.stringValue, "filesystem::get_home")
        XCTAssertEqual(protocolError.details?["kind"]?.stringValue, "function")
        XCTAssertEqual(protocolError.details?["childErrorKind"]?.stringValue, "not_found")
        XCTAssertTrue(protocolError.diagnosticSummary.contains("CAPABILITY_NOT_FOUND"))
        XCTAssertFalse(protocolError.diagnosticSummary.contains("Invalid response"))
    }
}
