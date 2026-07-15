import Testing
@testable import TronMac

@Suite("Permission")
struct PermissionTests {
    @Test("Full Disk Access URL points at Privacy_AllFiles pane")
    func fullDiskAccessSystemSettingsURL() {
        #expect(
            Permission.fullDiskAccess.systemSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
