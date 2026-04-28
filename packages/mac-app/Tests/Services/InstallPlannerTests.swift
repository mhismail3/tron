import Foundation
import Testing
@testable import TronMac

@Suite("InstallPlanner")
struct InstallPlannerTests {
    @Test("missing helper binary produces clear error")
    func missingHelperBinary() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = makePaths(in: tmp)
        try createPlist(at: paths.plistPath)

        let result = InstallPlanner.plan(paths: paths)

        switch result {
        case .failure(.helperMissing(let url)):
            #expect(url == paths.helperBinary)
        default:
            Issue.record("expected .helperMissing, got \(result)")
        }
    }

    @Test("missing plist produces clear error")
    func missingPlist() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = makePaths(in: tmp)
        try createExecutable(at: paths.helperBinary)

        let result = InstallPlanner.plan(paths: paths)

        switch result {
        case .failure(.plistMissing(let url)):
            #expect(url == paths.plistPath)
        default:
            Issue.record("expected .plistMissing, got \(result)")
        }
    }

    @Test("fresh install produces helper and plist plan")
    func freshInstallProducesPlan() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = makePaths(in: tmp)
        try createExecutable(at: paths.helperBinary)
        try createPlist(at: paths.plistPath)

        let result = InstallPlanner.plan(paths: paths)

        if case .success(let plan) = result {
            #expect(plan.helperBundle == paths.helperBundle)
            #expect(plan.helperBinary == paths.helperBinary)
            #expect(plan.plistPath == paths.plistPath)
        } else {
            Issue.record("expected success")
        }
    }

    @Test("registered services still produce a startable plan")
    func registeredServiceStillProducesStartablePlan() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = makePaths(in: tmp)
        try createExecutable(at: paths.helperBinary)
        try createPlist(at: paths.plistPath)

        let result = InstallPlanner.plan(paths: paths)

        if case .success(let plan) = result {
            #expect(plan.plistPath == paths.plistPath)
            #expect(plan.helperBinary == paths.helperBinary)
        } else {
            Issue.record("expected success")
        }
    }

    @Test("plist rendering uses BundleProgram and argv-only ProgramArguments")
    func plistRenderingUsesBundleProgram() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let plist = InstallPlanner.renderPlist(paths: makePaths(in: tmp))

        #expect(plist.contains("<key>BundleProgram</key>"))
        #expect(plist.contains("Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"))
        #expect(plist.contains("<key>ProgramArguments</key>"))
        #expect(plist.contains("<string>tron</string>"))
        #expect(plist.contains("<string>--port</string>\n        <string>9847</string>"))
        #expect(plist.contains("<string>--quiet</string>"))
        let data = try #require(plist.data(using: .utf8))
        let decoded = try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        #expect(decoded["BundleProgram"] as? String == "Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron")
        #expect(decoded["ProgramArguments"] as? [String] == ["tron", "--port", "9847", "--quiet"])
        #expect((decoded["EnvironmentVariables"] as? [String: String]) == ["RUST_LOG": "info"])
        #expect(decoded["AssociatedBundleIdentifiers"] as? [String] == [
            "com.tron.mac",
            "com.tron.mac.dev",
        ])
    }

    private func makePaths(in tmp: URL, port: Int = 9847) -> InstallPlanner.TargetPaths {
        let app = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/Tron Server.app", isDirectory: true)
        return InstallPlanner.TargetPaths(
            helperBundle: helper,
            helperBinary: helper.appendingPathComponent("Contents/MacOS/tron", isDirectory: false),
            plistPath: app.appendingPathComponent("Contents/Library/LaunchAgents/com.tron.server.plist", isDirectory: false),
            label: "com.tron.server",
            port: port
        )
    }

    private func createExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
    }

    private func createPlist(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
}
