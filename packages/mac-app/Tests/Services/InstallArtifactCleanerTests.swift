import Foundation
import Testing
@testable import TronMac

@Suite("InstallArtifactCleaner")
struct InstallArtifactCleanerTests {
    @Test("clean unloads launch agent and removes only app bundle plus plist")
    func cleanRemovesLaunchArtifacts() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let app = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let binaryDir = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let binary = binaryDir.appendingPathComponent("tron", isDirectory: false)
        let plist = tmp.appendingPathComponent("Library/LaunchAgents/com.tron.server.plist", isDirectory: false)
        let database = tmp.appendingPathComponent("database/log.db", isDirectory: false)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try Data("plist".utf8).write(to: plist)
        try Data("database".utf8).write(to: database)

        let manager = MockLaunchAgentManager()
        manager.loaded = true

        let outcome = await InstallArtifactCleaner.clean(
            installedBundle: app,
            launchAgentPlistPath: plist,
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel
        )

        #expect(outcome.isSuccess)
        #expect(!FileManager.default.fileExists(atPath: app.path))
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(FileManager.default.fileExists(atPath: database.path))
        #expect(manager.calls.map(\.kind) == [.isLoaded, .unload])
    }

    @Test("clean removes empty deployment directory")
    func cleanRemovesEmptyDeploymentDirectory() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let deployment = tmp.appendingPathComponent("deployment", isDirectory: true)
        try FileManager.default.createDirectory(at: deployment, withIntermediateDirectories: true)
        let manager = MockLaunchAgentManager()

        let outcome = await InstallArtifactCleaner.clean(
            installedBundle: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            launchAgentPlistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel,
            emptyDirectoriesToRemove: [deployment]
        )

        #expect(outcome.isSuccess)
        #expect(!FileManager.default.fileExists(atPath: deployment.path))
    }

    @Test("clean preserves non-empty deployment directory")
    func cleanPreservesNonEmptyDeploymentDirectory() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let deployment = tmp.appendingPathComponent("deployment", isDirectory: true)
        let devBundle = deployment.appendingPathComponent("Tron-Dev.app", isDirectory: true)
        try FileManager.default.createDirectory(at: devBundle, withIntermediateDirectories: true)
        let manager = MockLaunchAgentManager()

        let outcome = await InstallArtifactCleaner.clean(
            installedBundle: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            launchAgentPlistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel,
            emptyDirectoriesToRemove: [deployment]
        )

        #expect(outcome.isSuccess)
        #expect(FileManager.default.fileExists(atPath: devBundle.path))
    }

    @Test("clean skips unload when launch agent is not loaded")
    func cleanSkipsUnloadWhenNotLoaded() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let app = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let plist = tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: plist)

        let manager = MockLaunchAgentManager()
        manager.loaded = false

        let outcome = await InstallArtifactCleaner.clean(
            installedBundle: app,
            launchAgentPlistPath: plist,
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel
        )

        #expect(outcome.isSuccess)
        #expect(manager.calls.map(\.kind) == [.isLoaded])
    }

    @Test("clean stops before deleting files when unload fails")
    func cleanStopsOnUnloadFailure() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let app = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let plist = tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: plist)

        let manager = MockLaunchAgentManager()
        manager.loaded = true
        manager.unloadOutcome = .launchdRefused(message: "permission denied")

        let outcome = await InstallArtifactCleaner.clean(
            installedBundle: app,
            launchAgentPlistPath: plist,
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel
        )

        #expect(outcome == .failed("Could not unload LaunchAgent: permission denied"))
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(FileManager.default.fileExists(atPath: plist.path))
        #expect(manager.calls.map(\.kind) == [.isLoaded, .unload])
    }
}
