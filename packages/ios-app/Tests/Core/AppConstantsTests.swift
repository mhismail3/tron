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

    func testBetaPort_is9846() {
        XCTAssertEqual(AppConstants.betaPort, "9846")
    }

    func testProdPort_is9847() {
        XCTAssertEqual(AppConstants.prodPort, "9847")
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

    func testFallbackServerURL_usesProdPort() {
        let url = AppConstants.fallbackServerURL
        XCTAssertEqual(url.port, 9847)
    }
}
