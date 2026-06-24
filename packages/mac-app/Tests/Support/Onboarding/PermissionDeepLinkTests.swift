import Foundation
import Testing
@testable import TronMac

@Suite("PermissionDeepLink")
struct PermissionDeepLinkTests {
    @Test("FDA URL points at Privacy_AllFiles pane")
    func fdaURL() {
        let url = PermissionDeepLink.url(for: .fullDiskAccess)
        #expect(url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @Test("each Permission has a deep link")
    func everyPermissionHasURL() {
        for permission in Permission.allCases {
            // Just check that we don't crash (URLs are force-unwrapped
            // in the production code).
            let url = PermissionDeepLink.url(for: permission)
            #expect(url.scheme == "x-apple.systempreferences")
        }
    }
}
