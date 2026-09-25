import Darwin
import Foundation
import Security

/// Kernel birth + executable path, NOT an exec incarnation or an input grant.
struct NativeCaptureProcess: Equatable, Sendable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    let executable: String

    static func read(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_ruid == getuid(),
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000,
              info.pbi_status != SZOMB, info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0,
              proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw NativeCaptureHostError.unauthorized }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                    executable: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}

/// Small file identity fence, not a payload cache or a second selection store.
private struct CaptureSelectionStamp: Equatable, Sendable {
    let exists: Bool
    let device: Int32
    let inode: UInt64
    let modified: Int64
    let nanos: Int64
    let bytes: Data
    static func read(_ url: URL) throws -> Self {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return Self(exists: false, device: 0, inode: 0, modified: 0, nanos: 0, bytes: Data()) }
        guard fd >= 0 else { throw NativeCaptureHostError.unauthorized }
        defer { _ = Darwin.close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= GatewayPayloadStore.maxManifestBytes else { throw NativeCaptureHostError.unauthorized }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count,
              fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else { throw NativeCaptureHostError.unauthorized }
        return Self(exists: true, device: before.st_dev, inode: before.st_ino,
                    modified: Int64(before.st_mtimespec.tv_sec), nanos: Int64(before.st_mtimespec.tv_nsec), bytes: Data(bytes))
    }
}

public struct NativeCaptureContext: Sendable {
    let automationEndpoint: @Sendable () -> NativeAutomationEndpoint?
    public init(outerBundle: URL, teamRequirement: String,
                automationEndpoint: @escaping @Sendable () -> NativeAutomationEndpoint? = { nil }) {
        self.outerBundle = outerBundle; self.teamRequirement = teamRequirement
        self.automationEndpoint = automationEndpoint
    }
    let outerBundle: URL
    let teamRequirement: String
    var helper: URL { outerBundle.appendingPathComponent("Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron") }
    var store: GatewayPayloadStore {
        GatewayPayloadStore(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(TronGatewayProfile.stable.homeName), channel: TronGatewayProfile.stable.channel)
    }
    func payload() throws -> GatewayPayloadValidationResult {
        guard let result = GatewayPayloadResolver.resolve(
            external: GatewayPayloadValidator.validateSelection(store: store),
            bundled: GatewayPayloadValidator.validate(payloadRoot: outerBundle.appendingPathComponent("Contents/Resources/Gateway"), expectedChannel: "stable")) else {
            throw NativeCaptureHostError.unauthorized
        }
        return result
    }
}

/// A connection pins signed Node bytes before messages are delivered. Fresh
/// launchd evidence independently proves this is the actual Stable job, not
/// another process loading those bytes. No credential or caller provenance input.
final class NativeCapturePeer: @unchecked Sendable {
    let process: NativeCaptureProcess
    let codeRequirement: String
    private let context: NativeCaptureContext
    private let payload: GatewayPayloadValidationResult
    private let selection: CaptureSelectionStamp
    private let manifest: CaptureSelectionStamp
    private let auditSession: au_asid_t

    init(connection: NSXPCConnection, context: NativeCaptureContext) throws {
        guard connection.effectiveUserIdentifier == getuid() else { throw NativeCaptureHostError.unauthorized }
        var audit = auditinfo_addr_t()
        guard getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0,
              connection.auditSessionIdentifier == audit.ai_asid else { throw NativeCaptureHostError.unauthorized }
        auditSession = connection.auditSessionIdentifier
        self.context = context
        let process = try NativeCaptureProcess.read(connection.processIdentifier)
        let pointer = try CaptureSelectionStamp.read(context.store.currentManifestURL)
        let payload = try context.payload()
        self.process = process; self.payload = payload
        guard pointer == (try CaptureSelectionStamp.read(context.store.currentManifestURL)),
              ["node-arm64", "node-x64"].contains(where: { payload.root.appendingPathComponent("runtime/\($0)").path == process.executable }) else {
            throw NativeCaptureHostError.unauthorized
        }
        selection = pointer
        manifest = try CaptureSelectionStamp.read(payload.root.appendingPathComponent("manifest.json"))
        codeRequirement = try NativeCodeSigning.pin(context.teamRequirement, to: URL(fileURLWithPath: process.executable))
        guard isCurrent() else { throw NativeCaptureHostError.unauthorized }
    }

    func isCurrent() -> Bool {
        var audit = auditinfo_addr_t()
        return (try? NativeCaptureProcess.read(process.pid)) == process
            && getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0 && audit.ai_asid == auditSession
            && (try? CaptureSelectionStamp.read(context.store.currentManifestURL)) == selection
            && (try? CaptureSelectionStamp.read(payload.root.appendingPathComponent("manifest.json"))) == manifest
    }

    func validate() async -> Bool {
        guard isCurrent(), let runtime = try? await LaunchAgentRuntimeReader.read(label: TronGatewayProfile.stable.launchAgentLabel),
              isCurrent(), runtime.pid == Int(process.pid), !runtime.needsLaunchConstraintRefresh,
              StableGatewayProvenance.validates(runtime, payload: payload, expectedHelperPath: context.helper.path) else { return false }
        // launchd observation includes ps awaits; compare birth/executable and
        // immutable payload selection again rather than accepting the old PID.
        return isCurrent()
    }
}
