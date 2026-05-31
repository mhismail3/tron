import Foundation
import ServiceManagement

/// Result of a single `system::ping` engine probe. The four non-success cases
/// drive distinct UI affordances in the menu bar / wizard so the user
/// gets the right action ("re-pair" vs "wait for boot" vs "check
/// network").
///
/// INVARIANT: `ServerStatusPoller.singleSnapshot` MUST map ping
/// results into explicit menu-bar states:
/// - `.success` → `.running`
/// - `.unauthorized` → `.unauthorized`
/// - `.unreachable`, `.timeout`, `.malformedResponse` → ask launchd;
///   unloaded maps to `.paused`, loaded maps to `.failed(reason:)`.
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

/// One-shot `system::ping` over the engine WebSocket protocol. Used by the install step's
/// "wait for server" loop AND by the menu bar's status poller.
enum ServerPing {
    static let requestID = "mac-system-ping"
    static let helloID = "mac-engine-hello"

    /// Performs a single ping with a default 3 s timeout. Classifies
    /// failures so the caller can render the right state without
    /// guessing.
    static func ping(host: String, port: Int, token: String?, timeout: TimeInterval = 3) async -> ServerPingResult {
        guard let url = URLComponents(string: "ws://\(host):\(port)/engine")?.url else {
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

        let hello: [String: Any] = [
            "type": "hello",
            "id": helloID,
            "protocolVersion": 1,
            "clientName": "tron-mac",
            "clientVersion": "tron-mac-wrapper",
        ]
        let payload: [String: Any] = [
            "type": "invoke",
            "id": requestID,
            "functionId": "system::ping",
            "payload": [
                "protocolVersion": 1,
                "clientVersion": "tron-mac-wrapper",
            ]
        ]
        guard let helloData = try? JSONSerialization.data(withJSONObject: hello, options: []),
              let helloString = String(data: helloData, encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .malformedResponse
        }

        do {
            try await task.send(.string(helloString))
            try await task.send(.string(str))

            var sawServerFrame = false
            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .malformedResponse
                }

                switch decodeFrame(data: raw, defaultPort: port) {
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

    static func decodeFrame(
        data: Data,
        expectedID: String = requestID,
        defaultPort: Int = TronPaths.defaultServerPort
    ) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard responseID(json["id"], matches: expectedID) else {
            return .ignore
        }
        if json["error"] != nil || json["ok"] as? Bool == false {
            return .error
        }
        guard let info = decode(data: data, defaultPort: defaultPort) else {
            return .malformed
        }
        return .result(info)
    }

    static func decode(data: Data, defaultPort: Int = TronPaths.defaultServerPort) -> ServerInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let child = result["child"] as? [String: Any],
              let value = child["value"] as? [String: Any] else {
            return nil
        }
        let serverVersion = value["serverVersion"] as? String ?? ""
        let port = value["port"] as? Int ?? defaultPort
        let tailscaleIp = value["tailscaleIp"] as? String
        let paired = value["paired"] as? Bool ?? false
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

/// Live `LaunchAgentManaging` implementation. Registration goes
/// through `SMAppService`; `launchctl` is used only for diagnostics and
/// explicit restart/kickstart.
struct LiveLaunchAgentManager: LaunchAgentManaging {
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome {
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return .binaryMissing(path: plistPath.path)
        }
        guard FileManager.default.fileExists(atPath: TronPaths.serverHelperBinary.path) else {
            return .binaryMissing(path: TronPaths.serverHelperBinary.path)
        }

        let service = SMAppService.agent(plistName: "\(label).plist")
        let status = ExistingInstallDetector.serviceStatus(label: label)
        let currentVariant = MacRuntimeVariant.detect()
        let runtime = await runtimeInfo(label: label)
        let runningParent = runtime?.parentBundleIdentifier
        let shouldReplaceStaleRuntime = Self.runtimeRequiresReplacement(
            runtimeInfo: runtime,
            expectedHelperPath: TronPaths.serverHelperBinary.path
        )
        let shouldTakeOverRuntime = Self.shouldBootoutForTakeover(
            status: status,
            currentVariant: currentVariant,
            runningParentBundleIdentifier: runningParent,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        )
        let shouldRefreshCurrentRegistration = Self.shouldRefreshRegistrationForCurrentBundle(
            status: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            currentParentBundleVersion: Self.currentParentBundleVersion(),
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        ) || Self.shouldRefreshRegistrationForLaunchConstraints(
            status: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        )

        if let outcome = Self.preRegistrationOutcome(
            for: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            runningParentBundleIdentifier: runningParent,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent,
            expectedHelperPath: TronPaths.serverHelperBinary.path,
            shouldRefreshCurrentRegistration: shouldRefreshCurrentRegistration
        ) {
            return outcome
        }
        if shouldReplaceStaleRuntime || shouldTakeOverRuntime || shouldRefreshCurrentRegistration {
            _ = await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", "gui/\(currentUID())/\(label)"]
            )
        }
        let externalPortBound = await isPortBound(TronPaths.defaultServerPort)
        let databaseLockHeld = await isDatabaseLockHeld()
        if Self.shouldRefuseExternalServer(
            status: status,
            runningParentBundleIdentifier: runningParent,
            portBound: externalPortBound,
            databaseLockHeld: databaseLockHeld
        ) {
            return .launchdRefused(message: "Another Tron server is already running on port \(TronPaths.defaultServerPort). Stop it before installing Tron Server.")
        }

        if Self.shouldUnregisterBeforeRegister(
            status: status,
            runningParentBundleIdentifier: runningParent,
            shouldReplaceStaleRuntime: shouldReplaceStaleRuntime,
            shouldTakeOverRuntime: shouldTakeOverRuntime,
            shouldRefreshCurrentRegistration: shouldRefreshCurrentRegistration
        ) {
            do {
                try await service.unregister()
            } catch {
                return .launchdRefused(
                    message: "Tron Server is registered but launchd has no loaded job, and macOS refused to replace the registration: \(error.localizedDescription)"
                )
            }
        }

        do {
            try service.register()
        } catch {
            return .launchdRefused(message: error.localizedDescription)
        }

        switch service.status {
        case .enabled:
            return .ok
        case .requiresApproval:
            return .requiresApproval(message: "Approve Tron Server in Login Items to finish installation.")
        case .notFound:
            return .unknown(message: "ServiceManagement could not find the bundled Tron Server LaunchAgent after registration.")
        case .notRegistered:
            return .unknown(message: "Tron Server was not registered.")
        @unknown default:
            return .unknown(message: "Tron Server registration returned an unknown status.")
        }
    }

    static func preRegistrationOutcome(
        for status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant = MacRuntimeVariant.detect(),
        runtimeInfo: LaunchAgentRuntimeInfo? = nil,
        runningParentBundleIdentifier: String? = nil,
        canManageLaunchAgent: Bool = true,
        expectedHelperPath: String = TronPaths.serverHelperBinary.path,
        shouldRefreshCurrentRegistration: Bool = false
    ) -> LaunchAgentOutcome? {
        switch status {
        case .requiresApproval:
            return .requiresApproval(message: "Approve Tron Server in Login Items to finish installation.")
        case .enabled, .notRegistered, .notFound, .unknown:
            let runtimeIsStale = runtimeRequiresReplacement(runtimeInfo: runtimeInfo, expectedHelperPath: expectedHelperPath)
            let resolvedParent = runtimeInfo?.parentBundleIdentifier ?? runningParentBundleIdentifier

            if !canManageLaunchAgent {
                if runtimeIsStale || resolvedParent == nil {
                    return .launchdRefused(
                        message: "This Xcode Debug wrapper is in companion mode and cannot install or repair the production Tron Server. Use /Applications/Tron.app, or run the isolated install-testing scheme."
                    )
                }
                return .alreadyLoaded
            }

            if runtimeIsStale {
                return nil
            }

            guard let resolvedParent else {
                // SMAppService can report an enabled Login Item even
                // when launchd has no loaded job for the label, e.g. a
                // stale DerivedData Debug registration. Do not treat
                // that as ready; route through the registration path so
                // the current app bundle is the source of truth.
                return nil
            }

            if resolvedParent == currentVariant.expectedParentBundleIdentifier {
                if shouldRefreshCurrentRegistration {
                    return nil
                }
                return .alreadyLoaded
            }
            if currentVariant.precedence > MacRuntimeVariant.precedence(forParentBundleIdentifier: resolvedParent) {
                return nil
            }
            return .launchdRefused(
                message: "Tron Server is currently managed by \(resolvedParent). Stop that build before installing this one."
            )
        }
    }

    static func shouldBootoutForTakeover(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runningParentBundleIdentifier: String?,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status != .requiresApproval,
              let runningParentBundleIdentifier,
              runningParentBundleIdentifier != currentVariant.expectedParentBundleIdentifier else {
            return false
        }
        return currentVariant.precedence > MacRuntimeVariant.precedence(forParentBundleIdentifier: runningParentBundleIdentifier)
    }

    static func shouldRefuseExternalServer(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        runningParentBundleIdentifier: String?,
        portBound: Bool,
        databaseLockHeld: Bool
    ) -> Bool {
        guard status != .enabled,
              status != .requiresApproval,
              runningParentBundleIdentifier == nil else {
            return false
        }
        return portBound || databaseLockHeld
    }

    static func shouldUnregisterBeforeRegister(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        runningParentBundleIdentifier: String?,
        shouldReplaceStaleRuntime: Bool,
        shouldTakeOverRuntime: Bool,
        shouldRefreshCurrentRegistration: Bool
    ) -> Bool {
        status == .enabled
            && (runningParentBundleIdentifier == nil
                || shouldReplaceStaleRuntime
                || shouldTakeOverRuntime
                || shouldRefreshCurrentRegistration)
    }

    static func shouldRefreshRegistrationForCurrentBundle(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runtimeInfo: LaunchAgentRuntimeInfo?,
        currentParentBundleVersion: String?,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status == .enabled,
              let runtimeInfo,
              runtimeInfo.parentBundleIdentifier == currentVariant.expectedParentBundleIdentifier,
              let registeredVersion = runtimeInfo.parentBundleVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !registeredVersion.isEmpty,
              let currentParentBundleVersion = currentParentBundleVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentParentBundleVersion.isEmpty else {
            return false
        }
        return registeredVersion != currentParentBundleVersion
    }

    static func shouldRefreshRegistrationForLaunchConstraints(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runtimeInfo: LaunchAgentRuntimeInfo?,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status == .enabled,
              let runtimeInfo,
              runtimeInfo.parentBundleIdentifier == currentVariant.expectedParentBundleIdentifier else {
            return false
        }
        return runtimeInfo.needsLaunchConstraintRefresh
    }

    static func currentParentBundleVersion(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static func runtimeRequiresReplacement(
        runtimeInfo: LaunchAgentRuntimeInfo?,
        expectedHelperPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let runtimeInfo,
              runtimeInfo.pid == nil,
              let executablePath = runtimeInfo.executablePath,
              !executablePath.isEmpty else {
            return false
        }

        let expected = URL(fileURLWithPath: expectedHelperPath).standardizedFileURL.path
        let actual = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        return actual != expected || !fileExists(actual)
    }

    func unload(label: String) async -> LaunchAgentOutcome {
        let service = SMAppService.agent(plistName: "\(label).plist")
        if let outcome = Self.preUnregistrationOutcome(for: ExistingInstallDetector.serviceStatus(label: label)) {
            return outcome
        }
        do {
            try await service.unregister()
            return .ok
        } catch {
            return .unknown(message: error.localizedDescription)
        }
    }

    static func preUnregistrationOutcome(
        for status: ExistingInstallDetector.ServiceRegistrationStatus
    ) -> LaunchAgentOutcome? {
        switch status {
        case .notRegistered:
            return .ok
        case .notFound:
            return .binaryMissing(path: TronPaths.launchAgentPlistPath.path)
        case .enabled, .requiresApproval, .unknown:
            return nil
        }
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

    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(label)"]
        )
        guard result.exitCode == 0 else { return nil }
        let pid = parsePID(from: result.stdout)
        let uptime: String?
        if let pid {
            uptime = await processElapsedTime(pid: pid)
        } else {
            uptime = nil
        }
        return LaunchAgentRuntimeInfo(
            pid: pid,
            uptime: uptime,
            parentBundleIdentifier: parseLaunchctlValue(
                named: "parent bundle identifier",
                from: result.stdout
            ),
            parentBundleVersion: parseLaunchctlValue(named: "parent bundle version", from: result.stdout),
            programIdentifier: parseLaunchctlValue(named: "program identifier", from: result.stdout),
            executablePath: parseLaunchctlDictionaryValue(named: "Executable", from: result.stdout),
            needsLaunchConstraintRefresh: result.stdout.contains("needs LWCR update")
        )
    }

    private func parsePID(from launchctlOutput: String) -> Int? {
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid =") else { continue }
            let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private func parseLaunchctlValue(named key: String, from launchctlOutput: String) -> String? {
        let prefix = "\(key) ="
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func parseLaunchctlDictionaryValue(named key: String, from launchctlOutput: String) -> String? {
        let prefix = "\"\(key)\" => \""
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let range = text.range(of: prefix) else { continue }
            let remainder = text[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { continue }
            let value = String(remainder[..<end])
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func processElapsedTime(pid: Int) async -> String? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(pid)", "-o", "etime="]
        )
        guard result.exitCode == 0 else { return nil }
        let uptime = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return uptime.isEmpty ? nil : uptime
    }

    private func isPortBound(_ port: Int) async -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        )
        return result.exitCode == 0 && !result.stdout.isEmpty
    }

    private func isDatabaseLockHeld() async -> Bool {
        guard FileManager.default.fileExists(atPath: TronPaths.databaseLockPath.path) else {
            return false
        }
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [TronPaths.databaseLockPath.path]
        )
        return result.exitCode == 0 && !result.stdout.isEmpty
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
