import Foundation
import Testing
import Darwin
@testable import TronMac

/// Tests `BinaryInstaller` (lifted out of `InstallStep.swift`) — the
/// pure side-effect runner that copies the bundled binary, writes
/// `Info.plist`, and persists the LaunchAgent plist.
@Suite("BinaryInstaller")
struct BinaryInstallerTests {
    @Test("install copies binary into Tron.app/Contents/MacOS atomically and sets 0o755")
    func installCopiesBinary() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        let elf = Data([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01])
        try elf.write(to: source)

        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let plistPath = tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false)

        let plan = InstallPlan(
            sourceBinary: source,
            targetBundle: bundle,
            targetBinary: binary,
            plistPath: plistPath,
            plistContents: "<plist/>",
            requiresLoad: true
        )

        try BinaryInstaller.install(plan: plan)

        #expect(FileManager.default.fileExists(atPath: binary.path))
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let copied = try Data(contentsOf: binary)
        #expect(copied == elf)

        let perms = try FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o755)
    }

    @Test("install writes a valid Info.plist into Tron.app/Contents")
    func installWritesInfoPlist() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        try Data().write(to: source)

        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let plan = InstallPlan(
            sourceBinary: source,
            targetBundle: bundle,
            targetBinary: binary,
            plistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            plistContents: "<plist/>",
            requiresLoad: true
        )
        try BinaryInstaller.install(plan: plan)

        let infoURL = bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data = try Data(contentsOf: infoURL)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        #expect(dict?["CFBundleExecutable"] as? String == "tron")
        #expect(dict?["CFBundleIdentifier"] as? String == TronPaths.bundleID)
        #expect(dict?["CFBundlePackageType"] as? String == "APPL")
        #expect(dict?["LSUIElement"] as? Bool == true)
    }

    @Test("install replaces existing binary (atomic re-install)")
    func installReplacesExisting() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        // Pre-existing binary at the target.
        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("tron", isDirectory: false)
        try Data("OLD".utf8).write(to: binary)

        // Fresh source binary with new content.
        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        try Data("NEW".utf8).write(to: source)

        let plan = InstallPlan(
            sourceBinary: source,
            targetBundle: bundle,
            targetBinary: binary,
            plistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            plistContents: "<plist/>",
            requiresLoad: true
        )
        try BinaryInstaller.install(plan: plan)

        let copied = try String(contentsOf: binary, encoding: .utf8)
        #expect(copied == "NEW")
    }

    @Test("writePlist creates parent dir and writes contents")
    func writePlistCreatesParent() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let nested = tmp.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plist = nested.appendingPathComponent("com.tron.server.plist", isDirectory: false)

        let plan = InstallPlan(
            sourceBinary: tmp,
            targetBundle: tmp,
            targetBinary: tmp,
            plistPath: plist,
            plistContents: "<plist version=\"1.0\"/>",
            requiresLoad: true
        )

        try BinaryInstaller.writePlist(plan: plan)
        let body = try String(contentsOf: plist, encoding: .utf8)
        #expect(body == "<plist version=\"1.0\"/>")
    }

    @Test("install strips com.apple.quarantine xattr from copied binary")
    func installStripsQuarantine() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }

        let source = tmp.appendingPathComponent("tron-agent", isDirectory: false)
        try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: source)
        // Tag the source with the same xattr Gatekeeper would add to a
        // freshly-downloaded DMG payload. The format is the canonical
        // 5-field LaunchServices quarantine string.
        let qBytes = "0083;65bc8a01;Tron;|com.tron.mac".data(using: .utf8)!
        try qBytes.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            let rc = source.path.withCString { cPath in
                Darwin.setxattr(cPath, "com.apple.quarantine", base, buf.count, 0, 0)
            }
            #expect(rc == 0, "setxattr setup failed; cannot exercise the strip code path")
        }

        let bundle = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let plan = InstallPlan(
            sourceBinary: source,
            targetBundle: bundle,
            targetBinary: binary,
            plistPath: tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false),
            plistContents: "<plist/>",
            requiresLoad: true
        )
        try BinaryInstaller.install(plan: plan)

        // After install, the destination must NOT carry quarantine.
        var buffer = [UInt8](repeating: 0, count: 256)
        let size = binary.path.withCString { cPath in
            Darwin.getxattr(cPath, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
        }
        // -1 with errno ENOATTR (93 on Darwin) is the expected outcome.
        #expect(size == -1, "expected no quarantine xattr on installed binary, got \(size) bytes")
    }

    @Test("writePlist overwrites existing file")
    func writePlistOverwrites() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let plist = tmp.appendingPathComponent("plist", isDirectory: false)
        try Data("old".utf8).write(to: plist)

        let plan = InstallPlan(
            sourceBinary: tmp,
            targetBundle: tmp,
            targetBinary: tmp,
            plistPath: plist,
            plistContents: "new",
            requiresLoad: true
        )
        try BinaryInstaller.writePlist(plan: plan)
        let body = try String(contentsOf: plist, encoding: .utf8)
        #expect(body == "new")
    }
}
