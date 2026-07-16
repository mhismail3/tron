import Testing
@testable import TronMac

@Suite("Permission")
struct PermissionTests {
    @Test("only Full Disk Access is required")
    func canonicalOrder() {
        #expect(Permission.allCases == [.fullDiskAccess])
    }

    @Test("Full Disk Access URL points at Privacy_AllFiles pane")
    func fullDiskAccessSystemSettingsURL() {
        #expect(
            Permission.fullDiskAccess.systemSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
