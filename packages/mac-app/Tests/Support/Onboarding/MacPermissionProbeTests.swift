import Foundation
import Testing
@testable import TronMac

@Suite("MacPermissionProbe")
struct MacPermissionProbeTests {
    @Test("Full Disk Access is granted when the TCC database opens")
    func fullDiskAccessGrantedByTCCDatabase() {
        #expect(MacPermissionProbe.classifyFullDiskAccess(
            tcc: .readable,
            mail: .permissionDenied,
            safari: .permissionDenied
        ) == .granted)
    }

    @Test("Full Disk Access is denied when the TCC database is permission denied")
    func fullDiskAccessDeniedByTCCDatabase() {
        #expect(MacPermissionProbe.classifyFullDiskAccess(
            tcc: .permissionDenied,
            mail: .readable,
            safari: .readable
        ) == .denied)
    }

    @Test("Full Disk Access falls back to protected user data")
    func fullDiskAccessFallsBackToUserData() {
        #expect(MacPermissionProbe.classifyFullDiskAccess(
            tcc: .unavailable,
            mail: .readable,
            safari: .permissionDenied
        ) == .granted)
        #expect(MacPermissionProbe.classifyFullDiskAccess(
            tcc: .unavailable,
            mail: .unavailable,
            safari: .permissionDenied
        ) == .denied)
    }

    @Test("Full Disk Access reports unavailable when no protected probe path answers")
    func fullDiskAccessUnavailableWhenNoProbeAnswers() {
        #expect(MacPermissionProbe.classifyFullDiskAccess(
            tcc: .unavailable,
            mail: .unavailable,
            safari: .unavailable
        ) == .probeUnavailable)
    }
}
