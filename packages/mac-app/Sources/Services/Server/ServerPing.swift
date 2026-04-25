import Foundation

/// Result of a single `system.ping` probe. The four non-success cases
/// drive distinct UI affordances in the menu bar / wizard so the user
/// gets the right action ("re-pair" vs "wait for boot" vs "check
/// network"). Replaces the old `ServerInfo?` return which conflated
/// "server is down" with "token rejected".
///
/// INVARIANT: the menu-bar tone mapping in
/// `ServerStatusPoller.singleSnapshot` MUST match this matrix:
/// - `.success` → `.running`
/// - `.unauthorized` → `.unauthorized`
/// - `.unreachable`, `.timeout` → `.stopped`
/// - `.malformedResponse` → `.unknown` (server is up but talking junk)
enum ServerPingResult: Sendable, Equatable {
    case success(ServerInfo)
    case unauthorized
    case unreachable
    case timeout
    case malformedResponse

    var info: ServerInfo? {
        if case .success(let info) = self { return info }
        return nil
    }
}

/// One-shot `system.ping` over WebSocket. Used by the install step's
/// "wait for server" loop AND by the menu bar's status poller.
enum ServerPing {
    static let requestID = "mac-system-ping"

    /// Performs a single ping with a default 3 s timeout. Classifies
    /// failures so the caller can render the right state without
    /// guessing.
    static func ping(host: String, port: Int, token: String?, timeout: TimeInterval = 3) async -> ServerPingResult {
        guard let url = URLComponents(string: "ws://\(host):\(port)/ws")?.url else {
            return .unreachable
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Delegate captures the HTTP upgrade status code so we can
        // distinguish a 401 rejection from a generic transport error.
        let capture = WSStatusCapture()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: capture,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let payload: [String: Any] = [
            "id": requestID,
            "method": "system.ping",
            "params": [
                "protocolVersion": 1,
                "clientVersion": "tron-mac-wrapper",
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .malformedResponse
        }

        do {
            try await task.send(.string(str))

            var sawServerFrame = false
            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .malformedResponse
                }

                switch decodeFrame(data: raw) {
                case .result(let info):
                    return .success(info)
                case .ignore:
                    sawServerFrame = true
                    continue
                case .error:
                    return .malformedResponse
                case .malformed:
                    return .malformedResponse
                }
            }

            return sawServerFrame ? .unauthorized : .malformedResponse
        } catch {
            // Server returned a non-101 status during upgrade — most
            // commonly 401 when auth fails. The delegate captured it.
            if let status = capture.snapshotStatusCode(), status == 401 {
                return .unauthorized
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .userAuthenticationRequired:
                    return .unauthorized
                case .timedOut:
                    return .timeout
                case .cannotConnectToHost,
                     .cannotFindHost,
                     .networkConnectionLost,
                     .notConnectedToInternet,
                     .dnsLookupFailed:
                    return .unreachable
                case .badServerResponse:
                    // No status code captured but server replied with
                    // something non-WS. Treat as unauthorized (most
                    // likely cause: wrong/missing token); the menu bar
                    // gets the same recovery affordance either way.
                    return .unauthorized
                default:
                    return .unreachable
                }
            }
            return .unreachable
        }
    }

    enum ResponseFrame: Equatable {
        case result(ServerInfo)
        case ignore
        case error
        case malformed
    }

    static func decodeFrame(data: Data, expectedID: String = requestID) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard responseID(json["id"], matches: expectedID) else {
            return .ignore
        }
        if json["error"] != nil || json["success"] as? Bool == false {
            return .error
        }
        guard let info = decode(data: data) else {
            return .malformed
        }
        return .result(info)
    }

    static func decode(data: Data) -> ServerInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return nil
        }
        let serverVersion = result["serverVersion"] as? String ?? ""
        let port = result["port"] as? Int ?? TronPaths.defaultServerPort
        let tailscaleIp = result["tailscaleIp"] as? String
        let paired = result["paired"] as? Bool ?? false
        return ServerInfo(version: serverVersion, port: port, tailscaleIp: tailscaleIp, paired: paired)
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }

    private static func responseID(_ value: Any?, matches expectedID: String) -> Bool {
        if let string = value as? String {
            return string == expectedID
        }
        return false
    }
}

/// One-shot `system.probePermissions` RPC client. Returns the agent's
/// TCC grant state — which is the state the Permissions wizard cares
/// about, because the AGENT is the binary that actually uses FDA /
/// Screen Recording / Accessibility at runtime.
///
/// The RPC is defined in
/// `packages/agent/src/server/rpc/handlers/system.rs`
/// (`ProbePermissionsHandler`). It uses native FFI and never prompts,
/// so this client can poll every couple of seconds without racing the
/// System Settings deep-link UX.
///
/// Failure modes are folded into `.probeUnavailable` on the per-
/// permission result so the wizard renders a retry affordance rather
/// than looping forever — e.g. the agent is mid-restart after a kickstart.
enum PermissionProbeRPC {
    static let requestID = "mac-probe-permissions"

    /// Probes the three wizard permissions against the agent. If the
    /// server is unreachable or the response is malformed, all three
    /// come back as `.probeUnavailable` so the UI can surface a single
    /// "server restarting…" banner instead of three confused spinners.
    static func probeAll(
        host: String,
        port: Int,
        token: String?,
        timeout: TimeInterval = 3
    ) async -> [Permission: PermissionStatus] {
        guard let url = URLComponents(string: "ws://\(host):\(port)/ws")?.url else {
            return fallback()
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let payload: [String: Any] = [
            "id": requestID,
            "method": "system.probePermissions",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return fallback()
        }

        do {
            try await task.send(.string(str))

            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return fallback()
                }

                switch decodeFrame(raw) {
                case .result(let statuses):
                    return statuses
                case .ignore:
                    continue
                case .error, .malformed:
                    return fallback()
                }
            }

            return fallback()
        } catch {
            return fallback()
        }
    }

    enum ResponseFrame: Equatable {
        case result([Permission: PermissionStatus])
        case ignore
        case error
        case malformed
    }

    static func decodeFrame(_ data: Data, expectedID: String = requestID) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard responseID(json["id"], matches: expectedID) else {
            return .ignore
        }
        if json["error"] != nil || json["success"] as? Bool == false {
            return .error
        }
        guard let statuses = decode(data) else {
            return .malformed
        }
        return .result(statuses)
    }

    static func decode(_ data: Data) -> [Permission: PermissionStatus]? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return nil
        }
        func status(for key: String) -> PermissionStatus {
            // Server emits lowercase tokens ("granted" / "denied" /
            // "unknown"). Anything else degrades to probeUnavailable so
            // a future server bump that introduces new tokens still
            // renders a retry affordance, not a crash.
            switch result[key] as? String {
            case "granted": return .granted
            case "denied":  return .denied
            default:        return .probeUnavailable
            }
        }
        return [
            .fullDiskAccess:  status(for: "fullDiskAccess"),
            .screenRecording: status(for: "screenRecording"),
            .accessibility:   status(for: "accessibility"),
        ]
    }

    /// Uniform fallback: every permission reports `.probeUnavailable`.
    /// The wizard treats this as "server probably mid-restart, try again
    /// in a moment" and keeps polling.
    private static func fallback() -> [Permission: PermissionStatus] {
        [
            .fullDiskAccess:  .probeUnavailable,
            .screenRecording: .probeUnavailable,
            .accessibility:   .probeUnavailable,
        ]
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }

    private static func responseID(_ value: Any?, matches expectedID: String) -> Bool {
        if let string = value as? String {
            return string == expectedID
        }
        return false
    }
}

/// One-shot `system.requestPermission` RPC client. This is deliberately
/// separate from `PermissionProbeRPC`: probing must stay silent, while
/// this request is called only after a user clicks a Permissions-step
/// gear button.
enum PermissionRequestRPC {
    static func request(
        _ permission: Permission,
        host: String,
        port: Int,
        token: String?,
        timeout: TimeInterval = 4
    ) async -> Bool {
        guard let url = URLComponents(string: "ws://\(host):\(port)/ws")?.url else {
            return false
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let requestID = "mac-request-permission-\(permission.rawValue)"
        let payload: [String: Any] = [
            "id": requestID,
            "method": "system.requestPermission",
            "params": ["permission": permission.rawValue],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return false
        }

        do {
            try await task.send(.string(str))
            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else { return false }
                switch decodeFrame(raw, expectedID: requestID) {
                case .result(let responsePermission, _):
                    return responsePermission == permission
                case .ignore:
                    continue
                case .error, .malformed:
                    return false
                }
            }
            return false
        } catch {
            return false
        }
    }

    enum ResponseFrame: Equatable {
        case result(Permission, PermissionStatus)
        case ignore
        case error
        case malformed
    }

    static func decodeFrame(_ data: Data, expectedID: String) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard responseID(json["id"], matches: expectedID) else {
            return .ignore
        }
        if json["error"] != nil || json["success"] as? Bool == false {
            return .error
        }
        guard let result = json["result"] as? [String: Any],
              let rawPermission = result["permission"] as? String,
              let permission = Permission(rawValue: rawPermission) else {
            return .malformed
        }

        let status: PermissionStatus
        switch result["status"] as? String {
        case "granted":
            status = .granted
        case "denied":
            status = .denied
        default:
            status = .probeUnavailable
        }
        return .result(permission, status)
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }

    private static func responseID(_ value: Any?, matches expectedID: String) -> Bool {
        if let string = value as? String {
            return string == expectedID
        }
        return false
    }
}

/// Captures the HTTP upgrade response status code via the URLSession
/// delegate callbacks. Thread-safe via NSLock so it can be touched from
/// the URLSession's delegate queue and the awaiter.
private final class WSStatusCapture: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode: Int?

    func snapshotStatusCode() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return statusCode
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse {
            lock.lock()
            statusCode = http.statusCode
            lock.unlock()
        }
    }
}

/// Live `LaunchAgentManaging` implementation that shells out to
/// `launchctl`. Tests use `MockLaunchAgentManager` instead.
struct LiveLaunchAgentManager: LaunchAgentManaging {
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome {
        if await isLoaded(label: label) {
            return .alreadyLoaded
        }
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return .binaryMissing(path: plistPath.path)
        }
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootstrap", "gui/\(currentUID())", plistPath.path]
        )
        return result.exitCode == 0
            ? .ok
            : .launchdRefused(message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    func unload(label: String) async -> LaunchAgentOutcome {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", "gui/\(currentUID())/\(label)"]
        )
        // bootout returns 0 when removed; non-zero often "not loaded".
        return result.exitCode == 0
            ? .ok
            : .unknown(message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    func restart(label: String) async -> LaunchAgentOutcome {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["kickstart", "-k", "gui/\(currentUID())/\(label)"]
        )
        return result.exitCode == 0
            ? .ok
            : .launchdRefused(message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    func isLoaded(label: String) async -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(label)"]
        )
        return result.exitCode == 0
    }

    private func currentUID() -> Int {
        Int(getuid())
    }
}

/// Result type for `Subprocess.run`. Sendable-clean so it can cross
/// actor boundaries (e.g. `MainActor` callers awaiting work spawned on
/// a background queue).
struct ProcessResult: Equatable, Sendable {
    var exitCode: Int
    var stdout: String
    var stderr: String

    init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Lightweight subprocess runner shared across the wrapper. Async to
/// avoid blocking the MainActor.
///
/// Uses `Process.terminationHandler` (not `waitUntilExit`) so the call
/// site is fully async — the continuation resumes on the libdispatch
/// queue Foundation uses for process events. Stdout / stderr are read
/// inside the handler so we can't deadlock on a child that fills the
/// pipe buffer.
enum Subprocess {
    static func run(executable: URL, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                ))
                return
            }
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
