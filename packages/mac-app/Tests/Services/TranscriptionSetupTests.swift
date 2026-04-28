import Foundation
import Testing
@testable import TronMac

@Suite("TranscriptionResourceInstaller")
struct TranscriptionResourceInstallerTests {
    @Test("copies worker and requirements without deleting model cache")
    func copiesRequiredFilesAndPreservesCache() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("bundle/Transcription", isDirectory: true)
        let destination = tmp.appendingPathComponent("system/transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("models/hf", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("worker".utf8).write(to: source.appendingPathComponent("worker.py"))
        try Data("parakeet-mlx\n".utf8).write(to: source.appendingPathComponent("requirements.txt"))
        try Data("cache".utf8).write(to: destination.appendingPathComponent("models/hf/sentinel"))

        try TranscriptionResourceInstaller.install(from: source, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("worker.py").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("requirements.txt").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("models/hf/sentinel").path))
    }

    @Test("missing required resource fails loudly")
    func missingRequiredResourceFails() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("bundle/Transcription", isDirectory: true)
        let destination = tmp.appendingPathComponent("system/transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("worker".utf8).write(to: source.appendingPathComponent("worker.py"))

        do {
            try TranscriptionResourceInstaller.install(from: source, to: destination)
            Issue.record("expected missing requirements.txt to fail")
        } catch TranscriptionResourceInstaller.Failure.missingResourceFile(let file) {
            #expect(file == "requirements.txt")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite("TranscriptionSetupCoordinator")
struct TranscriptionSetupCoordinatorTests {
    @Test("disabled preference writes setting without restarting server")
    func disabledPreferenceDoesNotRestart() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("bundle/Transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("worker".utf8).write(to: source.appendingPathComponent("worker.py"))
        try Data("parakeet-mlx\n".utf8).write(to: source.appendingPathComponent("requirements.txt"))
        let manager = MockLaunchAgentManager()
        let settingsPath = tmp.appendingPathComponent("system/settings.json", isDirectory: false)
        let destination = tmp.appendingPathComponent("system/transcription", isDirectory: true)

        let result = await TranscriptionSetupCoordinator.apply(
            enabled: false,
            sidecarSource: source,
            sidecarDestination: destination,
            settingsPath: settingsPath,
            bearerToken: nil,
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel,
            pingServer: { _ in .unreachable }
        )

        #expect(result == .disabled)
        #expect(manager.calls.filter { $0.kind == .restart }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("worker.py").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("requirements.txt").path))
        let data = try Data(contentsOf: settingsPath)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require(root["server"] as? [String: Any])
        let transcription = try #require(server["transcription"] as? [String: Any])
        #expect(transcription["enabled"] as? Bool == false)
    }

    @Test("enabled preference copies sidecar and restarts server")
    func enabledPreferenceCopiesAndRestarts() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("bundle/Transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("worker".utf8).write(to: source.appendingPathComponent("worker.py"))
        try Data("parakeet-mlx\n".utf8).write(to: source.appendingPathComponent("requirements.txt"))
        let manager = MockLaunchAgentManager()

        let result = await TranscriptionSetupCoordinator.apply(
            enabled: true,
            sidecarSource: source,
            sidecarDestination: tmp.appendingPathComponent("system/transcription", isDirectory: true),
            settingsPath: tmp.appendingPathComponent("system/settings.json", isDirectory: false),
            bearerToken: "token",
            launchAgentManager: manager,
            label: TronPaths.launchAgentLabel,
            pingServer: { token in
                #expect(token == "token")
                return .success(ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: nil, paired: false))
            }
        )

        #expect(result == .enabled)
        #expect(manager.calls.filter { $0.kind == .restart }.count == 1)
    }
}
