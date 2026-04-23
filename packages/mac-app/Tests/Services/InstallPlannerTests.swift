import Foundation
import Testing
@testable import TronMac

/// Tests `InstallPlanner` - a pure-value planner that turns a source
/// binary + target paths into an executable plan. Covers the three
/// branches of existing-install handling and the plist-rendering parity
/// with `scripts/tron`.
@Suite("InstallPlanner")
struct InstallPlannerTests {
    @Test("missing source binary produces clear error")
    func missingSourceBinary() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let missing = tmp.appendingPathComponent("does-not-exist", isDirectory: false)
        let paths = InstallPlanner.TargetPaths(
            targetBundle: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            targetBinary: tmp.appendingPathComponent("Tron.app/Contents/MacOS/tron", isDirectory: false),
            plistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            label: "com.tron.server",
            port: 9847,
            tronHome: tmp,
            homeDir: tmp,
            repoRoot: nil
        )

        let result = InstallPlanner.plan(sourceBinary: missing, paths: paths, existingInstall: .none)

        switch result {
        case .failure(.sourceBinaryMissing(let url)):
            #expect(url == missing)
        default:
            Issue.record("expected .sourceBinaryMissing, got \(result)")
        }
    }

    @Test("happy path builds plan with requiresLoad=true on fresh install")
    func freshInstallRequiresLoad() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        FileManager.default.createFile(atPath: source.path, contents: Data([0x7f, 0x45, 0x4c, 0x46]))

        let paths = makePaths(in: tmp)
        let result = InstallPlanner.plan(sourceBinary: source, paths: paths, existingInstall: .none)

        switch result {
        case .success(let plan):
            #expect(plan.requiresLoad)
            #expect(plan.sourceBinary == source)
            #expect(plan.targetBundle == paths.targetBundle)
            #expect(plan.targetBinary == paths.targetBinary)
            #expect(plan.plistPath == paths.plistPath)
            #expect(plan.plistContents.contains("com.tron.server"))
        case .failure(let failure):
            Issue.record("expected success, got \(failure)")
        }
    }

    @Test("existing install without plist still requires load")
    func existingInstallNoPlistRequiresLoad() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        FileManager.default.createFile(atPath: source.path, contents: Data())

        let paths = makePaths(in: tmp)
        // plist intentionally NOT created
        let result = InstallPlanner.plan(
            sourceBinary: source,
            paths: paths,
            existingInstall: .installed(version: "0.5.0")
        )

        switch result {
        case .success(let plan):
            #expect(plan.requiresLoad,
                    "install marked 'installed' but plist missing - still needs load")
        case .failure(let f):
            Issue.record("expected success, got \(f)")
        }
    }

    @Test("existing install with plist is idempotent (requiresLoad=false)")
    func existingInstallWithPlistIsIdempotent() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let paths = makePaths(in: tmp)
        // Simulate plist already on disk from a prior install. Create
        // the parent LaunchAgents dir first — FileManager.createFile
        // silently fails if the parent is missing, which would defeat
        // the point of this test.
        try FileManager.default.createDirectory(
            at: paths.plistPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: paths.plistPath.path, contents: Data())
        #expect(FileManager.default.fileExists(atPath: paths.plistPath.path),
                "test fixture: plist file must exist before planning")

        let result = InstallPlanner.plan(
            sourceBinary: source,
            paths: paths,
            existingInstall: .installed(version: "0.5.0")
        )

        if case .success(let plan) = result {
            #expect(!plan.requiresLoad, "idempotent re-run should not re-bootstrap")
        } else {
            Issue.record("expected success")
        }
    }

    @Test("partial install still requires load")
    func partialInstallRequiresLoad() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        FileManager.default.createFile(atPath: source.path, contents: Data())

        let paths = makePaths(in: tmp)
        let result = InstallPlanner.plan(
            sourceBinary: source,
            paths: paths,
            existingInstall: .partial(reason: "plist missing")
        )

        if case .success(let plan) = result {
            #expect(plan.requiresLoad)
        } else {
            Issue.record("expected success")
        }
    }

    @Test("plist contents mirror scripts/tron heredoc")
    func plistRenderingMatchesShellScript() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = makePaths(in: tmp, port: 9847)
        let plist = InstallPlanner.renderPlist(paths: paths)

        // Structural anchors that must never drift from scripts/tron:
        #expect(plist.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(plist.contains("<key>Label</key>\n    <string>com.tron.server</string>"))
        #expect(plist.contains("<key>ProgramArguments</key>"))
        #expect(plist.contains("<string>--port</string>\n        <string>9847</string>"))
        #expect(plist.contains("<string>--quiet</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>\n    <true/>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("<key>Crashed</key>\n        <true/>"))
        #expect(plist.contains("<key>ThrottleInterval</key>\n    <integer>10</integer>"))
        #expect(plist.contains("<key>HOME</key>"))
        #expect(plist.contains("<key>TRON_DATA_DIR</key>"))
        #expect(plist.contains("<key>RUST_LOG</key>\n        <string>info</string>"))
        #expect(plist.contains("<key>NumberOfFiles</key>\n        <integer>4096</integer>"))
        #expect(plist.contains("<key>AssociatedBundleIdentifiers</key>"))
        #expect(plist.contains("<string>\(TronPaths.bundleID)</string>"))
        #expect(plist.hasSuffix("</plist>"))
    }

    @Test("repoRoot appears in environment variables when set")
    func repoRootAppearsInEnvironment() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let repo = tmp.appendingPathComponent("repo", isDirectory: true)
        var paths = makePaths(in: tmp)
        paths.repoRoot = repo
        let plist = InstallPlanner.renderPlist(paths: paths)
        #expect(plist.contains("<key>TRON_REPO_ROOT</key>"))
        #expect(plist.contains("<string>\(repo.path)</string>"))
    }

    @Test("repoRoot is omitted when nil")
    func repoRootOmittedWhenNil() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        var paths = makePaths(in: tmp)
        paths.repoRoot = nil
        let plist = InstallPlanner.renderPlist(paths: paths)
        #expect(!plist.contains("TRON_REPO_ROOT"))
    }

    @Test("xml entities are escaped in paths")
    func xmlEscapingInPaths() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        var paths = makePaths(in: tmp)
        // URLs allow <, >, & in path components on POSIX; the renderer
        // must escape them in the plist XML body.
        let weirdLabel = "com.tron.server<test>&\""
        paths.label = weirdLabel

        let plist = InstallPlanner.renderPlist(paths: paths)
        #expect(plist.contains("com.tron.server&lt;test&gt;&amp;&quot;"))
        #expect(!plist.contains(weirdLabel))
    }

    // MARK: - Helpers

    private func makePaths(in tmp: URL, port: Int = 9847) -> InstallPlanner.TargetPaths {
        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let plist = tmp.appendingPathComponent("Library/LaunchAgents/com.tron.server.plist", isDirectory: false)
        return InstallPlanner.TargetPaths(
            targetBundle: bundle,
            targetBinary: binary,
            plistPath: plist,
            label: "com.tron.server",
            port: port,
            tronHome: tmp,
            homeDir: tmp,
            repoRoot: nil
        )
    }
}
