import Foundation
import os
import Testing
@testable import TronMac

@Suite("TronDevCommandRunner")
struct TronDevCommandRunnerTests {
    @Test("dev command arguments map to background-safe tron dev commands")
    func commandArguments() {
        #expect(TronDevCommand.startBackground.arguments == ["dev", "-d"])
        #expect(TronDevCommand.startBackgroundWithTests.arguments == ["dev", "-td"])
        #expect(TronDevCommand.startBackgroundWithBuildAndTests.arguments == ["dev", "-btd"])
        #expect(TronDevCommand.menuCommands.allSatisfy { $0.startsDevServer })
    }

    @Test("project root resolves from TRON_PROJECT_ROOT")
    func resolvesEnvironmentProjectRoot() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        try makeTronScript(in: tmp)

        let resolved = TronDevCommandRunner.resolveProjectRoot(
            environment: ["TRON_PROJECT_ROOT": tmp.path],
            bundleURL: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true),
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true)
        )

        #expect(resolved == tmp)
    }

    @Test("project root resolves by walking up from bundle URL")
    func resolvesAncestorProjectRoot() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        try makeTronScript(in: tmp)
        let bundle = tmp
            .appendingPathComponent("packages/mac-app/build/Debug/TronMac.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let resolved = TronDevCommandRunner.resolveProjectRoot(
            environment: [:],
            bundleURL: bundle,
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true)
        )

        #expect(resolved == tmp)
    }

    @Test("project root is nil when no scripts/tron exists")
    func missingProjectRootReturnsNil() {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let resolved = TronDevCommandRunner.resolveProjectRoot(
            environment: [:],
            bundleURL: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            currentDirectory: tmp
        )

        #expect(resolved == nil)
    }

    @Test("run builds bash invocation and reports success")
    func runBuildsInvocation() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        try makeTronScript(in: tmp)
        let capture = InvocationCapture()
        let result = await TronDevCommandRunner.run(
            command: .startBackgroundWithTests,
            environment: ["TRON_PROJECT_ROOT": tmp.path],
            bundleURL: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true),
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            logURL: tmp.appendingPathComponent("run/dev-menu-command.log", isDirectory: false),
            processRunner: { invocation in
                capture.set(invocation)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        #expect(result == .succeeded("Ran `scripts/tron dev -td`."))
        let invocation = try #require(capture.value)
        #expect(invocation.executable.path == "/bin/bash")
        #expect(invocation.arguments == [
            tmp.appendingPathComponent("scripts/tron", isDirectory: false).path,
            "dev",
            "-td",
        ])
        #expect(invocation.currentDirectory == tmp)
    }

    @Test("run reports first process error line and log path")
    func runReportsFailure() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        try makeTronScript(in: tmp)
        let logURL = tmp.appendingPathComponent("run/dev-menu-command.log", isDirectory: false)

        let result = await TronDevCommandRunner.run(
            command: .startBackground,
            environment: ["TRON_PROJECT_ROOT": tmp.path],
            bundleURL: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true),
            currentDirectory: URL(fileURLWithPath: "/", isDirectory: true),
            logURL: logURL,
            processRunner: { _ in
                ProcessResult(exitCode: 1, stdout: "", stderr: "\nfailed loudly\nmore")
            }
        )

        #expect(result == .failed("failed loudly\n\nFull output: \(logURL.path)"))
    }

    private func makeTronScript(in root: URL) throws {
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: scripts.appendingPathComponent("tron", isDirectory: false).path,
            contents: Data("#!/bin/bash\n".utf8)
        )
    }
}

private final class InvocationCapture: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Optional<TronDevCommandInvocation>.none)

    var value: TronDevCommandInvocation? {
        lock.withLock { $0 }
    }

    func set(_ invocation: TronDevCommandInvocation) {
        lock.withLock {
            $0 = invocation
        }
    }
}
