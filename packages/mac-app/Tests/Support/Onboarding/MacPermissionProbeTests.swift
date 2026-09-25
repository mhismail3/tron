import Foundation
import Testing
@testable import TronMac

@Suite("MacPermissionProbe")
struct MacPermissionProbeTests {

    @Test("native host trust is identifier-bound, not PID-bound")
    func nativeHostTrustRequirements() throws {
        let wrapper = try NativeHostTrust.requirement(identifier: "com.tron.mac", team: "EXAMPLE123")
        let host = try NativeHostTrust.requirement(identifier: NativeHostTrust.bundleIdentifier, team: "EXAMPLE123")
        #expect(wrapper == "anchor apple generic and certificate leaf[subject.OU] = \"EXAMPLE123\" and identifier \"com.tron.mac\"")
        #expect(host.contains(NativeHostTrust.bundleIdentifier))
        #expect(throws: NativeHostTrustError.self) { try NativeHostTrust.requirement(identifier: "untrusted", team: "EXAMPLE123") }
        #expect(throws: NativeHostTrustError.self) { try NativeHostTrust.requirement(identifier: "com.tron.mac", team: nil) }
    }

    @Test("an unsigned path cannot become a pinned XPC peer")
    func unsignedPeerRejected() throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let base = try NativeHostTrust.requirement(identifier: NativeHostTrust.bundleIdentifier, team: "EXAMPLE123")
        #expect(throws: NativeCodeSigningError.self) { try NativeCodeSigning.pin(base, to: root) }
    }

    @Test("optional native pre-consent cannot block or satisfy core setup")
    func coreSetupGate() {
        #expect(Permission.coreSetupSatisfied(by: [.fullDiskAccess: .granted]))
        #expect(!Permission.coreSetupSatisfied(by: [.accessibility: .granted, .screenRecording: .granted]))
        #expect(!Permission.coreSetupSatisfied(by: [.fullDiskAccess: .probeUnavailable]))
    }

    @Test("wrapper probe remains FDA-only")
    func wrapperProbeDoesNotClaimGuiPermission() async {
        #expect(await MacPermissionProbe.probe(.accessibility) == .probeUnavailable)
        #expect(await MacPermissionProbe.probe(.screenRecording) == .probeUnavailable)
    }

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
