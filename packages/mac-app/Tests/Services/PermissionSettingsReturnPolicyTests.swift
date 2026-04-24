import Testing
@testable import TronMac

@Suite("PermissionSettingsReturnPolicy")
struct PermissionSettingsReturnPolicyTests {
    @Test("plain app activation only rechecks")
    func activationWithoutSettingsRoundTripOnlyRechecks() {
        #expect(PermissionSettingsReturnPolicy.action(for: nil) == .recheckOnly)
    }

    @Test("already-granted permission does not restart on return")
    func grantedPermissionOnlyRechecks() {
        let pending = PermissionSettingsReturn(
            permission: .accessibility,
            statusBeforeOpen: .granted
        )

        #expect(PermissionSettingsReturnPolicy.action(for: pending) == .recheckOnly)
    }

    @Test("missing permission restarts once after Settings return")
    func missingPermissionRestarts() {
        for status in [PermissionStatus.denied, .notDetermined, .probeUnavailable] {
            let pending = PermissionSettingsReturn(
                permission: .screenRecording,
                statusBeforeOpen: status
            )

            #expect(PermissionSettingsReturnPolicy.action(for: pending) == .restartAndRecheck)
        }
    }
}
