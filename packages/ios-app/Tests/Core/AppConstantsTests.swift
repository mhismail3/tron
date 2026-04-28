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

    func testDmgDownloadPage_isGitHubReleasesURL() {
        let url = AppConstants.dmgDownloadPage
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("/tron/releases"))
    }

    func testTailscaleAppStorePage_isAppleAppStoreURL() {
        let url = AppConstants.tailscaleAppStorePage
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "apps.apple.com")
        XCTAssertTrue(url.path.contains("/app/tailscale/"))
    }
}
