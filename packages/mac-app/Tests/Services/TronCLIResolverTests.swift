import Foundation
import Testing
@testable import TronMac

/// Verifies the search-order contract documented in
/// `Sources/Services/Server/TronCLI.swift`. Both the menu-bar action
/// handler and the feedback action lean on this resolver — if the order
/// or matching logic regresses, both surfaces silently misbehave (logs
/// captured against the wrong binary, restart shelled to a stale install,
/// etc.). The test scaffolds real files under a temporary `home` so we
/// exercise `FileManager.isExecutableFile(atPath:)` against an actual
/// inode rather than a mock.
@Suite("TronCLI binary resolver")
struct TronCLIResolverTests {
    // MARK: - Helpers

    /// Creates an executable file at `path` (chmod 0o755) so
    /// `isExecutableFile(atPath:)` returns true. Parent directories are
    /// created on demand because `~/.local/bin/` doesn't exist on a
    /// fresh test temp dir.
    private func makeExecutable(at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\necho stub\n".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
    }

    /// Creates a non-executable file at `path` (chmod 0o644). Used to
    /// confirm the resolver skips files that exist but aren't executable.
    private func makeNonExecutable(at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not executable".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: path.path
        )
    }

    // MARK: - No candidates

    @Test("returns nil when no candidate exists")
    func noCandidates() {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let fm = SandboxedFileManager(allowedRoot: tmp)
        let result = TronCLI.resolveBinary(home: tmp, fileManager: fm)
        #expect(result == nil)
    }

    @Test("returns nil when candidate file exists but is not executable")
    func nonExecutableSkipped() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let candidate = tmp.appendingPathComponent(".local/bin/tron")
        try makeNonExecutable(at: candidate)
        let fm = SandboxedFileManager(allowedRoot: tmp)
        let result = TronCLI.resolveBinary(home: tmp, fileManager: fm)
        #expect(result == nil)
    }

    // MARK: - Single candidate

    @Test("bundled runtime CLI is preferred when present")
    func bundledRuntimeCLIWins() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let bundled = tmp.appendingPathComponent("BundleResources/tron-cli")
        let local = tmp.appendingPathComponent(".local/bin/tron")
        try makeExecutable(at: bundled)
        try makeExecutable(at: local)
        let fm = SandboxedFileManager(allowedRoot: tmp)
        let result = TronCLI.resolveBinary(home: tmp, bundledRuntimeCLI: bundled, fileManager: fm)
        #expect(result?.path == bundled.path)
    }

    @Test("user-local runtime CLI wins when bundled CLI is absent")
    func localBinPreferred() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let candidate = tmp.appendingPathComponent(".local/bin/tron")
        try makeExecutable(at: candidate)
        let fm = SandboxedFileManager(allowedRoot: tmp)
        let result = TronCLI.resolveBinary(home: tmp, fileManager: fm)
        #expect(result?.path == candidate.path)
    }

    // MARK: - Search order

    @Test("installed deployment runtime CLI wins after user-local")
    func deploymentRuntimeCLIIsSupported() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let deployment = tmp.appendingPathComponent(".tron/system/deployment/tron-cli")
        try makeExecutable(at: deployment)
        let fm = SandboxedFileManager(allowedRoot: tmp)
        let result = TronCLI.resolveBinary(home: tmp, fileManager: fm)
        #expect(result?.path == deployment.path)
    }

    @Test("default arguments are wired (smoke test)")
    func defaultsAreWired() {
        // We can't assert the return value (depends on the dev machine),
        // but we CAN assert the call doesn't crash and returns either
        // nil or a URL whose path matches one of the documented runtime
        // CLI candidates. If a legacy Homebrew path sneaks back in,
        // this test starts failing.
        let result = TronCLI.resolveBinary()
        if let result {
            let candidates = [
                "Contents/Resources/tron-cli",
                ".local/bin/tron",
                ".tron/system/deployment/tron-cli",
            ]
            #expect(candidates.contains { result.path.hasSuffix($0) })
        }
    }
}

// MARK: - Test FileManager

/// A `FileManager` subclass that only reports files as executable when
/// they live under `allowedRoot`. Lets the resolver test confirm
/// search-order behavior without depending on real runtime CLI files on
/// the developer's machine.
private final class SandboxedFileManager: FileManager, @unchecked Sendable {
    let allowedRoot: URL

    init(allowedRoot: URL) {
        self.allowedRoot = allowedRoot.standardizedFileURL
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL
        guard resolved.path.hasPrefix(allowedRoot.path) else { return false }
        return super.isExecutableFile(atPath: path)
    }
}
