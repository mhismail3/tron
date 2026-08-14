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

    @Test("BackendState=Running with IPv4: signed-in")
    func backendRunningWithIPv4() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let json = """
        {
          "Version": "1.58.2",
          "BackendState": "Running",
          "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
          "Self": {
            "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"]
          }
        }
        """

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: json, stderr: "") }
        )
        if case .signedIn(let ip) = status {
            #expect(ip == "100.64.0.1")
        } else {
            Issue.record("expected .signedIn, got \(status)")
        }
    }

    @Test("BackendState=Stopped (user hit Disconnect): installed-not-signed-in")
    func backendStopped() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        // Tailscale can retain an assigned address while disconnected;
        // `BackendState` remains authoritative.
        let json = """
        {
          "Version": "1.58.2",
          "BackendState": "Stopped",
          "TailscaleIPs": ["100.64.0.1"],
          "Self": {
            "TailscaleIPs": ["100.64.0.1"]
          }
        }
        """

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: json, stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("BackendState=NeedsLogin (not signed in): installed-not-signed-in")
    func backendNeedsLogin() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let json = """
        {
          "Version": "1.58.2",
          "BackendState": "NeedsLogin",
          "AuthURL": "https://login.tailscale.com/a/abc123"
        }
        """

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: json, stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("BackendState=Starting (daemon coming up): installed-not-signed-in")
    func backendStarting() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let json = """
        { "BackendState": "Starting" }
        """

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: json, stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("CLI exits non-zero (daemon not running): installed-not-signed-in")
    func cliExitsNonZero() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "failed to connect to local Tailscale service"
            ) }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("CLI prints non-JSON garbage: installed-not-signed-in (defensive)")
    func cliReturnsGarbage() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: "not json at all", stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("BackendState=Running but no IPv4 in payload: installed-not-signed-in")
    func runningButNoIPv4() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let json = """
        {
          "BackendState": "Running",
          "TailscaleIPs": ["fd7a:115c:a1e0::1"],
          "Self": { "TailscaleIPs": ["fd7a:115c:a1e0::1"] }
        }
        """

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: json, stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("BackendState=Running without a local Self address is not ready")
    func runningWithTopLevelIPOnly() async throws {
        let cli = try makeFakeCLI()
        defer { TestTempDir.cleanup(cli.deletingLastPathComponent()) }

        let json = """
        {
          "BackendState": "Running",
          "TailscaleIPs": ["100.101.102.103"]
        }
        """

        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [cli],
            runProcess: { _ in ProcessResult(exitCode: 0, stdout: json, stderr: "") }
        )
        #expect(status == .installedNotSignedIn)
    }

    @Test("multiple CLI paths: skips non-executable paths")
    func skipsNonExecutablePaths() async throws {
        let tmp = try TestTempDir.make()
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
        let json = """
        {
          "BackendState": "Running",
          "TailscaleIPs": ["100.96.2.3"],
          "Self": { "TailscaleIPs": ["100.96.2.3"] }
        }
        """
        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [first, second],
            runProcess: { url in
                seen = url
                return ProcessResult(exitCode: 0, stdout: json, stderr: "")
            }
        )

        #expect(seen == second, "first non-executable path should be skipped")
        if case .signedIn(let ip) = status {
            #expect(ip == "100.96.2.3")
        } else {
            Issue.record("expected .signedIn")
        }
    }

    @Test("multiple CLI paths: falls through from stale executable to connected CLI")
    func fallsThroughFromStaleExecutableToConnectedCLI() async throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let stale = tmp.appendingPathComponent("stale/tailscale", isDirectory: false)
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stale.path)

        let connected = tmp.appendingPathComponent("connected/tailscale", isDirectory: false)
        try FileManager.default.createDirectory(at: connected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: connected)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: connected.path)

        var seen: [URL] = []
        let status = await TailscaleProbe.probe(
            tailscaleAppExists: { _ in true },
            cliPaths: [stale, connected],
            runProcess: { url in
                seen.append(url)
                if url == stale {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: #"{"BackendState":"NeedsLogin"}"#,
                        stderr: ""
                    )
                }
                return ProcessResult(
                    exitCode: 0,
                    stdout: #"{"BackendState":"Running","Self":{"TailscaleIPs":["100.95.255.62"]}}"#,
                    stderr: ""
                )
            }
        )

        #expect(seen == [stale, connected])
        if case .signedIn(let ip) = status {
            #expect(ip == "100.95.255.62")
        } else {
            Issue.record("expected .signedIn after secondary CLI, got \(status)")
        }
    }

    // MARK: - Tailscale range validation

    @Test("range validation accepts only 100.64.0.0/10")
    func rangeAccepts() {
        #expect(TailscaleProbe.isTailscaleIPv4("100.64.0.1"))
        #expect(TailscaleProbe.isTailscaleIPv4("100.127.255.255"))
        #expect(!TailscaleProbe.isTailscaleIPv4("100.63.255.255"))
        #expect(!TailscaleProbe.isTailscaleIPv4("100.128.0.0"))
        #expect(!TailscaleProbe.isTailscaleIPv4("10.0.0.1"))
    }

    @Test("range validation rejects malformed addresses")
    func rangeRejectsMalformed() {
        #expect(!TailscaleProbe.isTailscaleIPv4(""))
        #expect(!TailscaleProbe.isTailscaleIPv4("not.an.ip"))
        #expect(!TailscaleProbe.isTailscaleIPv4("100.64.0"))
        #expect(!TailscaleProbe.isTailscaleIPv4("100.64.0.1.2"))
        #expect(!TailscaleProbe.isTailscaleIPv4("100.64.0.256"))
        #expect(!TailscaleProbe.isTailscaleIPv4("fe80::1"))
    }

    // MARK: - helpers

    /// Creates a 0o755-executable empty file under a fresh temp dir and
    /// returns its URL, so the probe's `isExecutableFile` check passes.
    /// Caller is responsible for removing the parent via
    /// `FileManager.default.removeItem(at: cli.deletingLastPathComponent())`.
    private func makeFakeCLI(file: StaticString = #file, line: UInt = #line) throws -> URL {
        let tmp = try TestTempDir.make()
        let cli = tmp.appendingPathComponent("tailscale", isDirectory: false)
        try Data().write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }
}
