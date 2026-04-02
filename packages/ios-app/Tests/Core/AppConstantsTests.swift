import XCTest
@testable import TronMobile

final class AppConstantsTests: XCTestCase {

    func testDefaultWorkspace_isEmpty() {
        // defaultWorkspace is empty — workspace is selected dynamically at runtime
        XCTAssertEqual(AppConstants.defaultWorkspace, "")
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
