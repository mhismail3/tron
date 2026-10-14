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
            case .closed(let exit): status = exit
            }
        }
        deadline.cancel()
        emit(["outcome": "ok", "output": String(decoding: output, as: UTF8.self), "exitStatus": status.map { $0 as Any } ?? NSNull()])
    } catch let error as MacTerminalError {
        emit(["outcome": "error", "error": caseName(error), "message": error.localizedDescription])
    }
default:
    FileHandle.standardError.write(Data("usage: mac-terminal-probe keygen | connect\n".utf8))
    exit(64)
}
