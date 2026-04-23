import Foundation
import Testing
@testable import TronMac

/// Tests for `ExistingInstallDetector` — branches the wizard uses to
/// decide whether to skip the Install step.
///
/// The detector takes injected paths so we don't touch the host's real
/// `~/.tron/`. The bundle-version resolver is a closure too so we can
/// confirm the resolver is invoked with the correct bundle root.
@Suite("ExistingInstallDetector")
struct ExistingInstallDetectorTests {
    @Test("clean host: nothing detected")
    func cleanHost() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let result = ExistingInstallDetector.detect(
            binaryPath: tmp.appendingPathComponent("Tron.app/Contents/MacOS/tron", isDirectory: false),
            authJSONPath: tmp.appendingPathComponent("auth.json", isDirectory: false),
            plistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            bundleVersionResolver: { _ in nil }
        )
        #expect(result == .none)
    }

    @Test("binary present: detected as installed (no version)")
    func binaryOnlyIsInstalled() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("tron", isDirectory: false)
        FileManager.default.createFile(atPath: binary.path, contents: Data([0x7f, 0x45]))

        let result = ExistingInstallDetector.detect(
            binaryPath: binary,
            authJSONPath: tmp.appendingPathComponent("missing-auth.json", isDirectory: false),
            plistPath: tmp.appendingPathComponent("missing.plist", isDirectory: false),
            bundleVersionResolver: { _ in nil }
        )

        if case .installed(let version) = result {
            #expect(version == nil)
        } else {
            Issue.record("expected .installed, got \(result)")
        }
    }

    @Test("binary + version resolver: version surfaced")
    func binaryWithVersion() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("tron", isDirectory: false)
        FileManager.default.createFile(atPath: binary.path, contents: Data())

        var observedRoot: URL?
        let result = ExistingInstallDetector.detect(
            binaryPath: binary,
            authJSONPath: tmp.appendingPathComponent("missing", isDirectory: false),
            plistPath: tmp.appendingPathComponent("missing.plist", isDirectory: false),
            bundleVersionResolver: { url in
                observedRoot = url
                return "0.5.0"
            }
        )

        if case .installed(let version) = result {
            #expect(version == "0.5.0")
        } else {
            Issue.record("expected .installed")
        }
        #expect(observedRoot == bundle, "resolver must receive the bundle root, not the binary path")
    }

    @Test("auth.json present + binary missing: partial")
    func authJSONOnlyIsPartial() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let auth = tmp.appendingPathComponent("auth.json", isDirectory: false)
        try Data("{\"k\":\"v\"}".utf8).write(to: auth)

        let result = ExistingInstallDetector.detect(
            binaryPath: tmp.appendingPathComponent("missing-bin", isDirectory: false),
            authJSONPath: auth,
            plistPath: tmp.appendingPathComponent("missing.plist", isDirectory: false),
            bundleVersionResolver: { _ in nil }
        )

        if case .partial(let reason) = result {
            #expect(reason.contains("auth.json"))
        } else {
            Issue.record("expected .partial, got \(result)")
        }
    }

    @Test("plist present + binary missing: partial")
    func plistOnlyIsPartial() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let plist = tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false)
        try Data("<plist/>".utf8).write(to: plist)

        let result = ExistingInstallDetector.detect(
            binaryPath: tmp.appendingPathComponent("missing-bin", isDirectory: false),
            authJSONPath: tmp.appendingPathComponent("missing-auth", isDirectory: false),
            plistPath: plist,
            bundleVersionResolver: { _ in nil }
        )

        if case .partial(let reason) = result {
            #expect(reason.contains("LaunchAgent") || reason.contains("plist"))
        } else {
            Issue.record("expected .partial, got \(result)")
        }
    }

    @Test("empty auth.json doesn't count as present")
    func emptyAuthDoesntCount() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let auth = tmp.appendingPathComponent("auth.json", isDirectory: false)
        FileManager.default.createFile(atPath: auth.path, contents: Data())

        let result = ExistingInstallDetector.detect(
            binaryPath: tmp.appendingPathComponent("missing-bin", isDirectory: false),
            authJSONPath: auth,
            plistPath: tmp.appendingPathComponent("missing.plist", isDirectory: false),
            bundleVersionResolver: { _ in nil }
        )

        #expect(result == .none, "empty auth.json must not be treated as present")
    }

    @Test("readMarketingVersion returns CFBundleShortVersionString")
    func marketingVersionReader() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let contents = tmp.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleShortVersionString": "0.5.0",
            "CFBundleIdentifier": "com.tron.agent",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false))

        let version = ExistingInstallDetector.readMarketingVersion(of: tmp)
        #expect(version == "0.5.0")
    }

    @Test("readMarketingVersion returns nil when Info.plist missing")
    func marketingVersionMissingPlist() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        #expect(ExistingInstallDetector.readMarketingVersion(of: tmp) == nil)
    }
}
