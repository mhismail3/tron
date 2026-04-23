import Foundation
import Testing
@testable import TronMac

@Suite("TailscaleProbe")
struct TailscaleProbeTests {
    @Test("not installed: returns .notInstalled")
    func notInstalled() async throws {
        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in false },
            cliPaths: [],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        )
        #expect(status == .notInstalled)
    }

    @Test("app present, no CLI: installed-not-signed-in")
    func appWithoutCLI() async throws {
        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("CLI present, exit 0, IPv4 returned: signed-in")
    func cliReturnsIPv4() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let cli = tmp.appendingPathComponent("tailscale", isDirectory: false)
        try Data().write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: "100.64.0.1\n", stderr: "") }
        )
        if case .signedIn(let ip) = status {
            #expect(ip == "100.64.0.1")
        } else {
            Issue.record("expected .signedIn, got \(status)")
        }
    }

    @Test("CLI exits 0 but prints nothing: not signed in")
    func cliExitsZeroEmpty() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let cli = tmp.appendingPathComponent("tailscale", isDirectory: false)
        try Data().write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("CLI exits non-zero: not signed in (treated as logged-out)")
    func cliExitsNonZero() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let cli = tmp.appendingPathComponent("tailscale", isDirectory: false)
        try Data().write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "logged out") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("multiple CLI paths: first executable wins")
    func firstExecutableWins() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        // First path: not executable.
        let first = tmp.appendingPathComponent("first/tailscale", isDirectory: false)
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: first)
        // Note: don't set executable bit on first.

        // Second path: executable.
        let second = tmp.appendingPathComponent("second/tailscale", isDirectory: false)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: second)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path)

        var seen: URL?
        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [first, second],
            runProcess: { url in
                seen = url
                return ProcessResult(exitCode: 0, stdout: "100.1.2.3", stderr: "")
            }
        )

        #expect(seen == second, "first non-executable path should be skipped")
        if case .signedIn(let ip) = status {
            #expect(ip == "100.1.2.3")
        } else {
            Issue.record("expected .signedIn")
        }
    }

    // MARK: - isIPv4

    @Test("isIPv4 accepts dotted-quad")
    func isIPv4Accepts() {
        #expect(TailscaleProbe.isIPv4("0.0.0.0"))
        #expect(TailscaleProbe.isIPv4("100.64.0.1"))
        #expect(TailscaleProbe.isIPv4("255.255.255.255"))
    }

    @Test("isIPv4 rejects malformed")
    func isIPv4Rejects() {
        #expect(!TailscaleProbe.isIPv4(""))
        #expect(!TailscaleProbe.isIPv4("not.an.ip"))
        #expect(!TailscaleProbe.isIPv4("1.2.3"))
        #expect(!TailscaleProbe.isIPv4("1.2.3.4.5"))
        #expect(!TailscaleProbe.isIPv4("256.0.0.1"))
        #expect(!TailscaleProbe.isIPv4("-1.0.0.0"))
        #expect(!TailscaleProbe.isIPv4("a.b.c.d"))
        #expect(!TailscaleProbe.isIPv4("fe80::1"))
    }
}
