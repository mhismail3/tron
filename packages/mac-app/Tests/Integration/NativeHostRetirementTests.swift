import Darwin
import Foundation
import Security
import Testing
@testable import TronMac

/// The wrapper pins the native helper's code signature on its XPC connection, so
/// libxpc validates every reply against the live sender. These tests drive the
/// production retirement owner in a separate process that a disposable launchd
/// job demand-launches through a real Mach service, exactly as the wrapper's
/// Quit, Disable, Restart Helper and Uninstall paths reach the helper.
@Suite("Native helper retirement over a real Mach service", .serialized)
struct NativeHostRetirementTests {
    @Test("a signature-pinning wrapper receives the confirmation, then the helper exits")
    func confirmationReachesPinnedWrapper() async throws {
        let job = try RetirementJob()
        defer { job.cleanup() }
        // Each round demand-launches a fresh helper process; one lucky delivery
        // cannot pass the check.
        for round in 1...3 {
            let connection = try job.connect()
            let confirmed = await job.retire(through: connection)
            #expect(confirmed, "round \(round): the pinned wrapper must receive the helper's true reply")
            let state = try job.state()
            #expect(state.running && state.runs == round,
                    "round \(round): the helper must stay alive while the wrapper still holds the connection")
            connection.invalidate()
            try await job.waitUntilExited(runs: round)
        }
    }

    @Test("a wrapper that disappears before reading the reply still lets the retired helper exit")
    func peerLossStillExits() async throws {
        let job = try RetirementJob()
        defer { job.cleanup() }
        let connection = try job.connect()
        #expect(await job.probe(through: connection), "the probe launches the helper before retirement")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? NativeHostPermissionService
        proxy?.prepareForServiceRetirement { _ in }
        connection.invalidate()
        try await job.waitUntilExited(runs: 1)
    }
}

private final class RetirementJob: @unchecked Sendable {
    let label = "com.tron.mac.integration-tests.native-retirement.\(UUID().uuidString.lowercased())"
    private let root: URL
    private let requirement: String
    private var bootstrapped = false
    private var service: String { "gui/\(getuid())/\(label)" }

    init() throws {
        let probe = try #require(ProcessInfo.processInfo.environment["TRON_NATIVE_HOST_RETIREMENT_PROBE"],
                                 "the scheme must provide the built retirement probe")
        requirement = try Self.designatedRequirement(of: URL(fileURLWithPath: probe))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-retirement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [probe, label], "MachServices": [label: true],
            "ThrottleInterval": 1, // demand relaunch between rounds, without launchd's 10 s default
        ]
        let plistURL = root.appendingPathComponent("job.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        try launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        bootstrapped = true
    }

    /// Same shape as the wrapper's connection: a Mach-service client that pins
    /// the helper's signature, so replies from a dead sender are refused.
    func connect() throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: label)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: NativeHostPermissionService.self)
        connection.activate()
        return connection
    }

    func retire(through connection: NSXPCConnection) async -> Bool {
        let reply = NativeHostReply<Bool>()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.resolve(false) })
                as? NativeHostPermissionService else { return false }
        proxy.prepareForServiceRetirement { reply.resolve($0) }
        return await reply.value()
    }

    func probe(through connection: NSXPCConnection) async -> Bool {
        let reply = NativeHostReply<Bool>()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.resolve(false) })
                as? NativeHostPermissionService else { return false }
        proxy.probePermissions { _ in reply.resolve(true) }
        return await reply.value()
    }

    struct State { let running: Bool; let runs: Int; let lastExit: String? }

    func state() throws -> State {
        let output = try launchctl(["print", service])
        func value(_ key: String) -> String? {
            output.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("\(key) = ") }.map { String($0.dropFirst(key.count + 3)) }
        }
        return State(running: value("state") == "running", runs: Int(value("runs") ?? "") ?? 0,
                     lastExit: value("last exit code"))
    }

    func waitUntilExited(runs: Int) async throws {
        for _ in 0..<200 {
            let current = try state()
            if !current.running, current.runs == runs {
                #expect(current.lastExit == "0", "the helper must exit through clean retirement")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the retired helper did not exit after its wrapper connection closed")
    }

    func cleanup() {
        if bootstrapped {
            do { _ = try launchctl(["bootout", service]); bootstrapped = false }
            catch { Issue.record("fixture job cleanup failed: \(error)") }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func designatedRequirement(of url: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "probe has no designated requirement"])
        }
        return text as String
    }

    @discardableResult
    private func launchctl(_ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableRuntimeMismatch,
                             userInfo: [NSLocalizedDescriptionKey: "launchctl \(args.first ?? "") failed: \(process.terminationStatus)"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
