import Foundation
import Testing
@testable import TronMac

@Suite("Mac Operator host bridge")
struct MacOperatorHostBridgeTests {
    @MainActor
    @Test("host bridge owns its socket lifecycle and serves one closed request")
    func hostLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socket = directory.appendingPathComponent("mac-operator.sock")
        let bridge = MacOperatorHostBridge(
            socketURL: socket,
            safety: MacOperatorSafetyState()
        )
        try bridge.start()
        defer {
            bridge.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let responseData = try await Task.detached {
            try MacOperatorTestSocket.call(
                at: socket.path,
                value: [
                    "requestId": "mac-status-1",
                    "timeoutMs": 2_000,
                    "action": ["kind": "status"],
                ]
            )
        }.value
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(response["requestId"] as? String == "mac-status-1")
        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["emergencyStop"] as? Bool == false)

        bridge.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }

    @Test("emergency and stop cancel and drain the active client action")
    func hostCancellationLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socket = directory.appendingPathComponent("mac-operator.sock")
        let safety = MacOperatorSafetyState()
        let emergencyStarted = OperatorTestSignal()
        let emergencyCancelled = OperatorTestSignal()
        let stopStarted = OperatorTestSignal()
        let stopCancelled = OperatorTestSignal()
        let bridge = MacOperatorHostBridge(
            socketURL: socket,
            safety: safety
        ) { request in
            let started = request.requestID == "mac-emergency"
                ? emergencyStarted
                : stopStarted
            let cancelled = request.requestID == "mac-emergency"
                ? emergencyCancelled
                : stopCancelled
            await started.signal()
            do {
                try await Task.sleep(for: .seconds(30))
                return MacOperatorProtocol.successData(
                    requestID: request.requestID,
                    result: ["unexpected": true]
                )
            } catch {
                await cancelled.signal()
                return MacOperatorProtocol.failureData(
                    requestID: request.requestID,
                    code: "native_action_cancelled"
                )
            }
        }
        try bridge.start()
        defer {
            bridge.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let emergencyCall = Task.detached {
            try MacOperatorTestSocket.call(
                at: socket.path,
                value: [
                    "requestId": "mac-emergency",
                    "timeoutMs": 20_000,
                    "action": ["kind": "status"],
                ]
            )
        }
        await emergencyStarted.wait()
        bridge.emergencyStop()
        await emergencyCancelled.wait()
        #expect(safety.snapshot().isStopped)
        #expect(FileManager.default.fileExists(atPath: socket.path))
        _ = try await emergencyCall.value

        safety.resumeFromNativeUI()
        let stopCall = Task.detached {
            try MacOperatorTestSocket.call(
                at: socket.path,
                value: [
                    "requestId": "mac-stop",
                    "timeoutMs": 20_000,
                    "action": ["kind": "status"],
                ]
            )
        }
        await stopStarted.wait()
        bridge.stop()
        await stopCancelled.wait()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        _ = try await stopCall.value
    }
}
