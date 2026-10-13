import Darwin
import Foundation
import Testing
@testable import TronMac

/// Runs the real Gateway launcher that `bundle-gateway.sh` built into the test
/// host and checks the argv it execs against the Swift checks that compare a
/// live Gateway's `ps` command line with it. The launcher decides the argv in C;
/// Stable admission, registration repair and Debug admission expect it in
/// Swift. When the launcher gained its heap-limit argument, every Swift check
/// refused the Gateway it started and the menu showed "Update required",
/// because nothing ran the launcher's real output through them.
@Suite("Gateway launcher argv")
struct GatewayLauncherArgvTests {
    @Test("Stable admission and registration repair accept what the launcher execs for the LaunchAgent")
    func stableLaunch() throws {
        let fixture = try LauncherFixture()
        defer { fixture.cleanup() }
        let agent = try LaunchAgentDefinition(TronPaths.launchAgentPlistPath(profile: .stable))

        let command = try fixture.launch(arguments: agent.arguments, environment: agent.environment)

        #expect(StableGatewayProvenance.processCommand(
            command, owns: fixture.payloadRoot, expectedHost: "tailscale", profile: .stable
        ))
        let runtime = LaunchAgentRuntimeInfo(
            pid: 1,
            parentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            executablePath: fixture.helper.path,
            processCommand: command,
            gatewaySupervisionMarker: agent.environment["TRON_GATEWAY_SUPERVISED"],
            gatewayChannelMarker: agent.environment["TRON_GATEWAY_CHANNEL"]
        )
        #expect(!LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: runtime, expectedHelperPath: fixture.helper.path
        ))
    }

    @Test("Debug admission accepts what the launcher execs for scripts/tron dev")
    func debugLaunch() throws {
        let fixture = try LauncherFixture()
        defer { fixture.cleanup() }

        // `scripts/tron-dev` starts the installed launcher with exactly this
        // environment and these arguments.
        let command = try fixture.launch(
            arguments: ["--host", "127.0.0.1", "--port", String(TronGatewayProfile.debug.port)],
            environment: ["TRON_HOME_NAME": ".tron-dev", "TRON_GATEWAY_CHANNEL": "dev", "TRON_GATEWAY_SUPERVISED": "1"]
        )

        #expect(StableGatewayProvenance.processCommand(
            command, owns: fixture.payloadRoot, expectedHost: "127.0.0.1", profile: .debug
        ))
    }
}

/// A copy of the test host's launcher in a fixture app whose bundled payload's
/// Node runtimes are replaced by a recorder, under a HOME with no payload
/// store so the launcher selects the bundled payload.
private struct LauncherFixture {
    private let root: URL
    /// The launcher and payload as the launcher itself spells them: it resolves
    /// its own location with realpath(3) and execs realpaths.
    let helper: URL
    let payloadRoot: URL
    private let executable: URL
    private let home: URL
    private let argvRecord: URL

    /// Stands in for Node: records the argv it was exec'd with, joined as
    /// `ps -o command=` prints it, and exits. The launcher admits a runtime only
    /// at its 1 MiB production minimum, so a comment pads the script.
    private static let argvRecorder: Data = {
        var script = Data("#!/bin/sh\nprintf '%s\\n' \"$0 $*\" > \"$TRON_FIXTURE_ARGV\"\nexit 0\n".utf8)
        script.append(Data(repeating: UInt8(ascii: "#"), count: 1_048_576))
        return script
    }()

    init() throws {
        let fm = FileManager.default
        // Not the temporary directory: its realpath starts with /private, which
        // `standardizedFileURL` drops from the expected payload root while the
        // launcher execs the realpath. Installed payloads never live there.
        root = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("tron-launcher-argv-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Tron.app/Contents", isDirectory: true)
        // The whole helper bundle: its signature binds the executable to the
        // bundle, and macOS kills the bare Mach-O copied out of it.
        let helperBundle = contents.appendingPathComponent("Library/LoginItems/Tron Agent.app", isDirectory: true)
        try fm.createDirectory(at: helperBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: TronPaths.serverHelperBundle(profile: .stable), to: helperBundle)
        executable = helperBundle.appendingPathComponent("Contents/MacOS/tron")
        try fm.createDirectory(at: contents.appendingPathComponent("Resources", isDirectory: true), withIntermediateDirectories: true)
        try Data("fixture helper\n".utf8).write(to: contents.appendingPathComponent("Resources/TronSearchEmbeddingHelper"))
        let payload = contents.appendingPathComponent("Resources/Gateway", isDirectory: true)
        try makeGatewayPayload(
            root: payload, channel: "stable", version: "launcher-argv",
            fingerprint: String(repeating: "a", count: 64), runtimeExecutable: Self.argvRecorder,
            additionalFiles: [("app/build-inputs.json", Data("{\"schema\":1,\"sourceRevision\":\"0123456789abcdef0123456789abcdef01234567\",\"sourceInputFingerprint\":\"\(String(repeating: "b", count: 64))\"}\n".utf8))]
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        argvRecord = root.appendingPathComponent("argv")
        helper = try Self.realPath(executable)
        payloadRoot = try Self.realPath(payload)
    }

    func launch(arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging(
            ["HOME": home.path, "PATH": "/usr/bin:/bin", "TRON_FIXTURE_ARGV": argvRecord.path]
        ) { _, fixture in fixture }
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LauncherFailure(status: process.terminationStatus, stderr: message)
        }
        return try String(contentsOf: argvRecord, encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    /// The payload is published read-only; restore write access so it can be removed.
    func cleanup() {
        chmod(root.path, 0o755)
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func realPath(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

private struct LauncherFailure: Error, CustomStringConvertible {
    let status: Int32
    let stderr: String
    var description: String { "launcher exited \(status): \(stderr)" }
}

/// The launchd arguments (after the program name) and environment the
/// LaunchAgent plist gives the launcher.
private struct LaunchAgentDefinition {
    let arguments: [String]
    let environment: [String: String]

    init(_ plist: URL) throws {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        guard let dictionary = object as? [String: Any],
              let program = dictionary["ProgramArguments"] as? [String],
              let environment = dictionary["EnvironmentVariables"] as? [String: String] else {
            throw CocoaError(.propertyListReadCorrupt, userInfo: [NSFilePathErrorKey: plist.path])
        }
        arguments = Array(program.dropFirst())
        self.environment = environment
    }
}
