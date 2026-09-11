import Foundation
import Darwin
import TronNativeCaptureHost

/// Owns the embedded Cua process and its parent-liveness pipe. This is an
/// optional automation backend: failure here must not prevent the permission
/// or capture services from starting.
final class CuaProcessOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let verifyExecutable: @Sendable (URL) -> Bool
    private var process: Process?
    private var input: Pipe?
    private var endpointValue: NativeAutomationEndpoint?
    private var sealed = false
    private var retirement: Task<Void, Never>?

    init(bundle: URL = Bundle.main.bundleURL,
         verifyExecutable: @escaping @Sendable (URL) -> Bool = CuaProcessOwner.signedExecutable) {
        executable = bundle.appendingPathComponent("Contents/Library/Native/cua-driver")
        self.verifyExecutable = verifyExecutable
    }

    /// Starts at most one child for this host generation. A missing optional
    /// asset, incompatible binary, or spawn failure simply disables automation.
    @discardableResult func start() -> Bool {
        lock.withLock {
            guard !sealed, process == nil, FileManager.default.isExecutableFile(atPath: executable.path), verifyExecutable(executable),
                  let hostBundleID = Bundle.main.bundleIdentifier else { return false }
            let generation = UUID()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tron-cua-\(generation.uuidString.lowercased())", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } catch { return false }
            // Keep the pathname within sockaddr_un even under macOS's long
            // per-user temporary directory. Generation lives in the directory.
            let socket = directory.appendingPathComponent("s").path
            guard socket.utf8.count < 104 else { try? FileManager.default.removeItem(at: directory); return false }
            let child = Process()
            let stdin = Pipe()
            child.executableURL = executable
            child.arguments = [
                "serve", "--embedded", "--parent-liveness-stdio", "--no-permissions-gate",
                "--host-bundle-id", hostBundleID, "--permission-mode", "standard",
                "--socket", socket,
            ]
            child.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
                "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false", "CUA_TELEMETRY_ENABLED": "false",
            ]
            child.standardInput = stdin
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] ended in
                if ended.terminationStatus != 0 {
                    FileHandle.standardError.write(Data("Native automation child exited with status \(ended.terminationStatus).\n".utf8))
                }
                try? FileManager.default.removeItem(at: directory)
                self?.lock.withLock {
                    self?.process = nil
                    self?.input = nil
                    self?.endpointValue = nil
                }
            }
            do {
                try child.run()
                process = child
                input = stdin
                endpointValue = NativeAutomationEndpoint(socket: socket, generation: generation)
                return true
            } catch {
                try? FileManager.default.removeItem(at: directory)
                // Keep the host alive for permission/capture operations.
                process = nil; input = nil; endpointValue = nil
                return false
            }
        }
    }

    private static func signedExecutable(_ executable: URL) -> Bool {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"YCK386LBJ7\" and identifier \"cua-driver\""
        return (try? NativeCodeSigning.pin(requirement, to: executable)) != nil
    }

    func endpoint() -> NativeAutomationEndpoint? {
        lock.withLock {
            guard !sealed, let process, process.isRunning, let endpointValue else { return nil }
            var info = stat()
            guard lstat(endpointValue.socket, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == geteuid() else { return nil }
            return endpointValue
        }
    }

    /// Seals startup, closes the liveness pipe, and waits for the actual child
    /// exit. No timeout or forced termination substitutes for native cleanup.
    func retire() async {
        let task = lock.withLock {
            if let retirement { return retirement }
            sealed = true
            let child = process, pipe = input
            let directory = endpointValue.map { URL(fileURLWithPath: $0.socket).deletingLastPathComponent() }
            endpointValue = nil
            let task = Task<Void, Never>.detached(priority: .utility) {
                pipe?.fileHandleForWriting.closeFile()
                child?.waitUntilExit()
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
            retirement = task
            return task
        }
        await task.value
    }
}
