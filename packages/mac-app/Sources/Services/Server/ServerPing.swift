import Foundation

/// One-shot `system.ping` over WebSocket. Returns the parsed
/// `ServerInfo` response on success, nil otherwise. Used by the
/// install step's "wait for server" loop AND by the menu bar's status
/// poller.
enum ServerPing {
    /// Performs a single ping with a default 3 s timeout.
    static func ping(host: String, port: Int, token: String?, timeout: TimeInterval = 3) async -> ServerInfo? {
        guard var components = URLComponents(string: "ws://\(host):\(port)/ws") else { return nil }
        components.scheme = "ws"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Send a single `system.ping` request; ignore everything else.
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "system.ping",
            "params": [
                "protocolVersion": 1,
                "clientVersion": "tron-mac-wrapper",
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }

        do {
            try await task.send(.string(str))
            let message = try await task.receive()
            switch message {
            case .data(let data):
                return decode(data: data)
            case .string(let s):
                return decode(data: Data(s.utf8))
            @unknown default:
                return nil
            }
        } catch {
            return nil
        }
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

/// Lightweight subprocess runner shared across the wrapper. Async to
/// avoid blocking the MainActor.
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
