import XCTest
@testable import TronMobile

final class AppConstantsTests: XCTestCase {

    func testDefaultWorkspace_usesHomeDirectory() {
        let home = NSHomeDirectory()
        XCTAssertTrue(AppConstants.defaultWorkspace.hasPrefix(home),
                       "Should start with actual home dir, got: \(AppConstants.defaultWorkspace)")
    }

    func testDefaultWorkspace_endsWithWorkspace() {
        XCTAssertTrue(AppConstants.defaultWorkspace.hasSuffix("/Workspace"),
                       "Should end with /Workspace, got: \(AppConstants.defaultWorkspace)")
    }

    func testTsBetaPort_is8082() {
        XCTAssertEqual(AppConstants.tsBetaPort, "8082")
    }

    func testTsProdPort_is8080() {
        XCTAssertEqual(AppConstants.tsProdPort, "8080")
    }

    func testAgentRsPort_is9847() {
        XCTAssertEqual(AppConstants.agentRsPort, "9847")
    }

    func testTronRsPort_is9091() {
        XCTAssertEqual(AppConstants.tronRsPort, "9091")
    }

    func testDefaultHost_isLocalhost() {
        XCTAssertEqual(AppConstants.defaultHost, "localhost")
    }

    func testFallbackServerURL_isValid() {
        let url = AppConstants.fallbackServerURL
        XCTAssertNotNil(url.host)
        XCTAssertNotNil(url.port)
        XCTAssertEqual(url.scheme, "ws")
    }

    func testFallbackServerURL_usesTsBetaPort() {
        let url = AppConstants.fallbackServerURL
        XCTAssertEqual(url.port, 8082)
    }
}
