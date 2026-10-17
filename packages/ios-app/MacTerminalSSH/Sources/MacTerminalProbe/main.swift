import CryptoKit
import Foundation
import MacTerminalSSH

// The Mac Terminal journey's client: the app's own MacTerminalSSH code, driven
// from a test against a real sshd. It is a test tool, never shipped.
//
//   mac-terminal-probe keygen
//     -> {"privateKeyPEM": ..., "publicKey": "ecdsa-sha2-nistp256 AAAA..."}
//   mac-terminal-probe connect   (stdin: {"endpoint": MacTerminalEndpoint,
//                                 "privateKeyPEM": ..., "input": "...",
//                                 "resize": [columns, rows]?})
//     -> {"outcome": "ok", "output": ..., "exitStatus": n}
//      | {"outcome": "error", "error": "<case>", "message": ...}
//   mac-terminal-probe host      (stdin: {"endpoint", "privateKeyPEM",
//                                 "command": [argv], "steps": [Step]})
//     runs the steps over one shell-host link (MacTerminalHostLink), then
//     closes it, which only detaches:
//       {"do": "open"} -> {"shell": id}
//       {"do": "attach", "shell": id, "after": n} -> {"text": replay, "reset": bool}
//       {"do": "write", "shell": id, "data": "..."}
//       {"do": "await", "shell": id, "text": "..."} -> {"text": output so far}
//       {"do": "awaitExit", "shell": id} -> {"exitCode": n?, "closedReason": s?}
//       {"do": "list"} -> {"shells": [MacShell]}
//       {"do": "terminate", "shell": id}
//     -> {"outcome": "ok", "results": [...]} | {"outcome": "error", ...}

struct HostStep: Decodable {
    let `do`: String
    let shell: String?
    let after: Int?
    let data: String?
    let text: String?
}

struct HostRequest: Decodable {
    let endpoint: MacTerminalEndpoint
    let privateKeyPEM: String
    let command: [String]
    let steps: [HostStep]
}

/// Output and exits seen on the link, per shell, for `await` steps.
actor HostObservations {
    var output: [String: String] = [:]
    var exits: [String: (Int?, String?)] = [:]

    func record(_ event: MacShellEvent) {
        switch event {
        case .output(let shell, let chunk): output[shell, default: ""] += chunk.data
        case .exited(let shell, let code, let reason): exits[shell] = (code, reason)
        }
    }

    func seed(_ shell: String, _ text: String) { output[shell, default: ""] += text }
    func text(_ shell: String) -> String { output[shell] ?? "" }
    func exit(_ shell: String) -> (Int?, String?)? { exits[shell] }
}

func runHost(_ request: HostRequest) async throws -> [[String: Any]] {
    let key = try P256.Signing.PrivateKey(pemRepresentation: request.privateKeyPEM)
    let link = try await MacTerminalHostLink.open(endpoint: request.endpoint, privateKey: .software(key), command: request.command)
    defer { link.close() }
    let observations = HostObservations()
    let listener = Task { for await event in link.events { await observations.record(event) } }
    defer { listener.cancel() }
    func until(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw MacTerminalHostError.refused(code: "timeout", message: "timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    var results: [[String: Any]] = []
    for step in request.steps {
        let shell = step.shell ?? ""
        switch step.do {
        case "open":
            let replay = try await link.openShell(columns: 100, rows: 30)
            await observations.seed(replay.shell.id, replay.chunks.map(\.data).joined())
            results.append(["shell": replay.shell.id])
        case "attach":
            let replay = try await link.attach(shell, after: step.after ?? 0)
            let text = replay.chunks.map(\.data).joined()
            await observations.seed(shell, text)
            results.append(["text": text, "reset": replay.reset, "sequence": replay.shell.sequence])
        case "write":
            link.write(shell, step.data ?? "")
            results.append([:])
        case "await":
            let wanted = step.text ?? ""
            try await until { await observations.text(shell).contains(wanted) }
            results.append(["text": await observations.text(shell)])
        case "awaitExit":
            try await until { await observations.exit(shell) != nil }
            let exit = await observations.exit(shell)
            results.append(["exitCode": exit?.0 as Any? ?? NSNull(), "closedReason": exit?.1 as Any? ?? NSNull()])
        case "list":
            let shells = try await link.list()
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shells))
            results.append(["shells": encoded])
        case "terminate":
            try await link.terminate(shell)
            results.append([:])
        default:
            throw MacTerminalHostError.refused(code: "invalid", message: "unknown step \(step.do)")
        }
    }
    return results
}

struct ConnectRequest: Decodable {
    let endpoint: MacTerminalEndpoint
    let privateKeyPEM: String
    let input: String
    let resize: [Int]?
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func caseName(_ error: MacTerminalError) -> String {
    switch error {
    case .notOnTailnet: "notOnTailnet"
    case .macUnreachable: "macUnreachable"
    case .remoteLoginOff: "remoteLoginOff"
    case .hostKeyMismatch: "hostKeyMismatch"
    case .authenticationRefused: "authenticationRefused"
    case .noPinnedHostKey: "noPinnedHostKey"
    case .shellRefused: "shellRefused"
    case .disconnected: "disconnected"
    }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "keygen":
    let key = P256.Signing.PrivateKey()
    emit([
        "privateKeyPEM": key.pemRepresentation,
        "publicKey": MacTerminalPrivateKey.software(key).openSSHPublicKey,
    ])
case "connect":
    let request = try JSONDecoder().decode(ConnectRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let key = try P256.Signing.PrivateKey(pemRepresentation: request.privateKeyPEM)
    do {
        let session = try await MacTerminalClient.connect(
            endpoint: request.endpoint, privateKey: .software(key), columns: 80, rows: 24)
        if let resize = request.resize, resize.count == 2 {
            session.resize(columns: resize[0], rows: resize[1])
        }
        session.write(Array(request.input.utf8))
        var output: [UInt8] = []
        var status: Int?
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            session.close()
        }
        for await event in session.events {
            switch event {
            case .output(let bytes): output += bytes
            case .diagnostic: break
            case .closed(let exit): status = exit
            }
        }
        deadline.cancel()
        emit(["outcome": "ok", "output": String(decoding: output, as: UTF8.self), "exitStatus": status.map { $0 as Any } ?? NSNull()])
    } catch let error as MacTerminalError {
        emit(["outcome": "error", "error": caseName(error), "message": error.localizedDescription])
    }
case "host":
    let request = try JSONDecoder().decode(HostRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    do {
        emit(["outcome": "ok", "results": try await runHost(request)])
    } catch let error as MacTerminalError {
        emit(["outcome": "error", "error": caseName(error), "message": error.localizedDescription])
    } catch let error as MacTerminalHostError {
        emit(["outcome": "error", "error": "host", "message": error.localizedDescription])
    }
default:
    FileHandle.standardError.write(Data("usage: mac-terminal-probe keygen | connect | host\n".utf8))
    exit(64)
}
