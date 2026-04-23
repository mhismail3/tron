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

    @Test("Accessibility URL points at Privacy_Accessibility pane")
    func accessibilityURL() {
        let url = PermissionDeepLink.url(for: .accessibility)
        #expect(url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @Test("Notifications URL points at notifications pane")
    func notificationsURL() {
        let url = PermissionDeepLink.url(for: .notifications)
        #expect(url.absoluteString == "x-apple.systempreferences:com.apple.preference.notifications")
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
