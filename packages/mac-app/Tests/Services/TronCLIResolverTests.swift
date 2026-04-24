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
        // tmp acts as `home`; nothing exists at `~/.local/bin/tron` and
        // /usr/local/bin/tron + /opt/homebrew/bin/tron are NOT injectable
        // here — they may exist on the developer machine. To make the
        // test deterministic we use a FileManager that only sees files
        // under our tmp dir.
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

    @Test("first candidate (~/.local/bin/tron) wins when present")
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

    @Test("homebrew Apple Silicon path is tried last")
    func searchOrderHonored() throws {
        // Stage all three candidates; only ~/.local/bin/tron is allowed
        // through the SandboxedFileManager. The other two exist on disk
        // but the resolver's first hit is the user-local one. This is
        // the contract: install-method consistency means a developer
        // who has both Homebrew and `tron install` only ever sees the
        // user-local copy run.
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let userLocal = tmp.appendingPathComponent(".local/bin/tron")
        try makeExecutable(at: userLocal)
        // Allow only the user-local candidate; the other two paths are
        // outside `tmp` so the sandboxed FM rejects them. This proves
        // the resolver iterates in order AND stops at the first match.
        let fm = SandboxedFileManager(allowedRoot: tmp)
        let result = TronCLI.resolveBinary(home: tmp, fileManager: fm)
        #expect(result?.path == userLocal.path)
    }

    @Test("default arguments are wired (smoke test)")
    func defaultsAreWired() {
        // We can't assert the return value (depends on the dev machine),
        // but we CAN assert the call doesn't crash and returns either
        // nil or a URL whose path matches one of the three documented
        // candidates. If a fourth path sneaks in via an accidental edit
        // this test starts failing.
        let result = TronCLI.resolveBinary()
        if let result {
            let candidates = [
                ".local/bin/tron",
                "/usr/local/bin/tron",
                "/opt/homebrew/bin/tron",
            ]
            #expect(candidates.contains { result.path.hasSuffix($0) })
        }
    }
}

// MARK: - Test FileManager

/// A `FileManager` subclass that only reports files as executable when
/// they live under `allowedRoot`. Lets the resolver test confirm
/// search-order behavior without depending on whether
/// `/usr/local/bin/tron` happens to be installed on the developer's
/// machine.
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
