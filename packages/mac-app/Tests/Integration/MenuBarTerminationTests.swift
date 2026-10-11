import Foundation
import Testing
@testable import TronMac

@Suite("Menu bar termination")
struct MenuBarTerminationTests {
    @Test("real AppKit deferred termination completes, retries, and rejects dispatch-based controls")
    func appKitTermination() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-termination-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("probe")
        let compiled = await Subprocess.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: [
            "swiftc", "-swift-version", "6", "-parse-as-library",
            root.appendingPathComponent("Sources/App/Lifecycle/ApplicationTermination.swift").path,
            root.appendingPathComponent("scripts/fixtures/AppKitTerminationProbe.swift").path,
            "-o", executable.path,
        ], policy: .observation)
        try #require(compiled.exitCode == 0, "\(compiled.stderr)")

        for mode in ["runloop", "retry", "runloop", "direct", "dispatch"] {
            let result = await Subprocess.run(executable: executable, arguments: [mode], policy: .observation)
            #expect(result.stderr.contains("termination-requested"), "\(mode): \(result.stderr)")
            if mode == "direct" || mode == "dispatch" {
                // These reproduce the installed stack and the insufficient
                // DispatchQueue.main.async workaround, not a mocked scheduler.
                #expect(result.exitCode == 42, "\(mode): \(result.stderr)")
                #expect(result.stderr.contains("watchdog-expired"))
                #expect(!result.stderr.contains("reply-task-ran"))
            } else {
                #expect(result.exitCode == 0, "\(mode): \(result.stderr)")
                #expect(result.stderr.contains("action-returned"))
                #expect(result.stderr.contains("reply-task-ran"))
                #expect(result.stderr.contains("\nterminated\n"))
                if mode == "retry" { #expect(result.stderr.contains("termination-cancelled")) }
            }
        }
    }
}
