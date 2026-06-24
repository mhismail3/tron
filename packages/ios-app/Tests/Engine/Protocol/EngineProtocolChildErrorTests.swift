import XCTest
@testable import TronMobile

final class EngineProtocolChildErrorTests: XCTestCase {
    func testChildErrorWithoutCanonicalFailureDoesNotInventProtocolError() throws {
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

        XCTAssertNil(childError.failure)
    }

    func testChildErrorDecodesCanonicalFailurePayload() throws {
        let json = """
        {
            "kind": "not_found",
            "message": "legacy child error text",
            "details": {
                "failure": {
                    "code": "CAPABILITY_NOT_FOUND",
                    "category": "not_found",
                    "message": "function not found: filesystem::get_home",
                    "retryable": false,
                    "recoverable": true,
                    "origin": "engine",
                    "details": {
                        "id": "filesystem::get_home",
                        "kind": "function"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let childError = try JSONDecoder().decode(EngineChildError.self, from: json)
        let failure = try XCTUnwrap(childError.failure)
        let protocolError = EngineProtocolError(failure: failure)

        XCTAssertEqual(protocolError.code, EngineErrorCode.capabilityNotFound.rawValue)
        XCTAssertEqual(protocolError.category, "not_found")
        XCTAssertEqual(protocolError.message, "function not found: filesystem::get_home")
        XCTAssertEqual(protocolError.origin, "engine")
        XCTAssertTrue(protocolError.recoverable)
        XCTAssertFalse(protocolError.retryable)
        XCTAssertEqual(protocolError.details?["id"]?.stringValue, "filesystem::get_home")
        XCTAssertEqual(protocolError.details?["kind"]?.stringValue, "function")
        XCTAssertTrue(protocolError.diagnosticSummary.contains("CAPABILITY_NOT_FOUND"))
        XCTAssertFalse(protocolError.diagnosticSummary.contains("Invalid response"))
    }
}
