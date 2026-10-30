import CryptoKit
import Foundation
import MacTerminalSSH

// Test-only CLI exercising the application's SSH implementation against real sshd.
struct ConnectRequest: Decodable {
    let endpoint: MacTerminalEndpoint
    let privateKeyPEM: String
    let input: String
    let sessionName: String
    let resize: [Int]?
    let detachWhen: String?
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
    case .serviceStopped: "serviceStopped"
    case .hostKeyMismatch: "hostKeyMismatch"
    case .authenticationRefused: "authenticationRefused"
    case .noPinnedHostKey: "noPinnedHostKey"
    case .shellRefused: "shellRefused"
    case .tmuxMissing: "tmuxMissing"
    case .invalidEndpoint: "invalidEndpoint"
    case .disconnected: "disconnected"
    }
}

switch CommandLine.arguments.dropFirst().first {
case "keygen":
    let key = P256.Signing.PrivateKey()
    emit(["privateKeyPEM": key.pemRepresentation, "publicKey": MacTerminalPrivateKey.software(key).openSSHPublicKey])
case "connect":
    let request = try JSONDecoder().decode(ConnectRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let key = try P256.Signing.PrivateKey(pemRepresentation: request.privateKeyPEM)
    do {
        let session = try await MacTerminalClient.connect(
            endpoint: request.endpoint, privateKey: .software(key), sessionName: request.sessionName, columns: 80, rows: 24)
        let resize = request.resize.flatMap { $0.count == 2 ? $0 : nil }
        var awaitingResize = resize != nil
        var lastSize = "no size response"
        // RFC 4254 window-change is fire-and-forget. Observe the real pane,
        // not local send completion, before issuing size-sensitive input.
        let sizePattern = try NSRegularExpression(pattern: "TRON_PTY_SIZE_5:([0-9]+) +([0-9]+)")
        let resizePoll: Task<Void, Error>? = resize.map { size in
            session.resize(columns: size[0], rows: size[1])
            return Task {
                let end = ContinuousClock.now.advanced(by: .seconds(5))
                while ContinuousClock.now < end {
                    try Task.checkCancellation()
                    // Echoed input cannot satisfy the expanded output marker.
                    session.write(Array("printf \"\\nTRON_PTY_SIZE_$((2+3)):%s\\n\" \"$(stty size)\"\n".utf8))
                    try await Task.sleep(for: .milliseconds(100))
                }
                session.close()
            }
        }
        if !awaitingResize { session.write(Array(request.input.utf8)) }
        var output: [UInt8] = []
        var status: Int?
        let deadline = Task { try await Task.sleep(for: .seconds(20)); session.close() }
        defer { resizePoll?.cancel(); deadline.cancel(); session.close() }
        for await event in session.events {
            switch event {
            case .output(let bytes):
                output += bytes
                if awaitingResize, let resize {
                    let text = String(decoding: output, as: UTF8.self)
                    for match in sizePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                        guard let rowsRange = Range(match.range(at: 1), in: text),
                              let columnsRange = Range(match.range(at: 2), in: text) else { continue }
                        let rows = String(text[rowsRange]), columns = String(text[columnsRange])
                        lastSize = "\(rows) \(columns)"
                        if Int(rows) == resize[1], Int(columns) == resize[0] { awaitingResize = false }
                    }
                    if !awaitingResize {
                        resizePoll?.cancel()
                        session.write(Array(request.input.utf8))
                    }
                }
                if let marker = request.detachWhen, String(decoding: output, as: UTF8.self).contains(marker) { session.close() }
            case .diagnostic: break
            case .closed(let exit): status = exit
            }
        }
        if awaitingResize {
            emit(["outcome": "error", "error": "resizeTimeout", "message": "SSH resize did not apply within 5s; last observed size: \(lastSize)"])
        } else {
            emit(["outcome": "ok", "output": String(decoding: output, as: UTF8.self), "exitStatus": status.map { $0 as Any } ?? NSNull()])
        }
    } catch let error as MacTerminalError {
        emit(["outcome": "error", "error": caseName(error), "message": error.localizedDescription])
    }
default:
    FileHandle.standardError.write(Data("usage: mac-terminal-probe keygen | connect\n".utf8))
    exit(64)
}
