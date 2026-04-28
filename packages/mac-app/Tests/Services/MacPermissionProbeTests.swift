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

    @Test("Screen Recording trusts a fresh probe after System Settings changes")
    func screenRecordingUsesFreshProbeAfterSystemSettingsChanges() {
        #expect(MacPermissionProbe.classifyScreenRecording(
            preflightGranted: false,
            freshProbeResult: .granted
        ) == .granted)
        #expect(MacPermissionProbe.classifyScreenRecording(
            preflightGranted: false,
            freshProbeResult: .denied
        ) == .denied)
        #expect(MacPermissionProbe.classifyScreenRecording(
            preflightGranted: true,
            freshProbeResult: .denied
        ) == .granted)
        #expect(MacPermissionProbe.classifyScreenRecording(
            preflightGranted: false,
            freshProbeResult: .unreadable
        ) == .probeUnavailable)
    }

    @Test("Screen Recording command probe result parser is strict")
    func screenRecordingCommandProbeResultParser() {
        #expect(MacPermissionProbe.screenRecordingProbeResult(from: "granted\n") == .granted)
        #expect(MacPermissionProbe.screenRecordingProbeResult(from: "denied") == .denied)
        #expect(MacPermissionProbe.screenRecordingProbeResult(from: "maybe") == .unreadable)
    }

    @Test("Screen Recording fresh probe avoids LaunchServices activation")
    func screenRecordingFreshProbeAvoidsLaunchServicesActivation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probe = try String(
            contentsOf: packageRoot.appending(path: "Sources/Services/Onboarding/MacPermissionProbe.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: packageRoot.appending(path: "Sources/TronMacApp.swift"),
            encoding: .utf8
        )

        #expect(probe.contains("process.executableURL = executableURL"))
        #expect(!probe.contains("URL(fileURLWithPath: \"/usr/bin/open\")"))
        #expect(!probe.contains("\"-n\""))
        #expect(!probe.contains("\"-W\""))
        #expect(app.contains("NSApp.setActivationPolicy(.prohibited)"))
    }
}
