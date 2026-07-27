import ApplicationServices
import Darwin
import Foundation
import Testing
@testable import TronMac

private actor OperatorTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if signalled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Suite("Mac Operator boundary")
struct MacOperatorProtocolTests {
    private func decode(_ value: [String: Any]) throws -> MacOperatorRequest {
        try MacOperatorProtocol.decodeRequest(
            JSONSerialization.data(withJSONObject: value)
        )
    }

    @Test("closed protocol rejects shell, script, path, and device fields")
    func rejectsGeneralPurposeControl() throws {
        let forbidden: [[String: Any]] = [
            [
                "requestId": "mac-test-1",
                "timeoutMs": 1_000,
                "action": [
                    "kind": "observe",
                    "bundleId": "com.example.app",
                    "script": "do shell script",
                ],
            ],
            [
                "requestId": "mac-test-2",
                "timeoutMs": 1_000,
                "action": ["kind": "shell", "command": ["rm", "-rf", "/"]],
            ],
            [
                "requestId": "mac-test-3",
                "timeoutMs": 1_000,
                "action": [
                    "kind": "screenshot",
                    "bundleId": "com.example.app",
                    "observationId": "observation-1",
                    "path": "/tmp/capture.png",
                ],
            ],
            [
                "requestId": "mac-test-4",
                "timeoutMs": 1_000,
                "action": ["kind": "device", "udid": "simulator"],
            ],
        ]

        for value in forbidden {
            #expect(throws: MacOperatorProtocolError.self) {
                try decode(value)
            }
        }
    }

    @Test("coordinate fallback requires exact fresh-observation shape")
    func coordinateFallbackShape() throws {
        let request = try decode([
            "requestId": "mac-test-5",
            "timeoutMs": 2_000,
            "action": [
                "kind": "coordinate_click",
                "bundleId": "com.example.app",
                "observationId": "observation-1",
                "screenshotId": "screenshot-1",
                "normalizedX": 0.25,
                "normalizedY": 0.75,
            ],
        ])

        #expect(request.action == .coordinateClick(
            bundleIdentifier: "com.example.app",
            observationID: "observation-1",
            screenshotID: "screenshot-1",
            normalizedX: 0.25,
            normalizedY: 0.75
        ))

        #expect(throws: MacOperatorProtocolError.self) {
            try decode([
                "requestId": "mac-test-6",
                "timeoutMs": 2_000,
                "action": [
                    "kind": "coordinate_click",
                    "bundleId": "com.example.app",
                    "observationId": "observation-1",
                    "normalizedX": 0.25,
                    "normalizedY": 0.75,
                ],
            ])
        }
    }

    @Test("set value is bounded and cannot target arbitrary attributes")
    func setValueBounds() throws {
        let valid = try decode([
            "requestId": "mac-test-7",
            "timeoutMs": 2_000,
            "action": [
                "kind": "set_value",
                "bundleId": "com.example.app",
                "observationId": "observation-1",
                "elementRef": "element-2",
                "text": "bounded content",
            ],
        ])
        #expect(valid.action == .setValue(
            bundleIdentifier: "com.example.app",
            observationID: "observation-1",
            elementReference: "element-2",
            text: "bounded content"
        ))

        #expect(throws: MacOperatorProtocolError.self) {
            try decode([
                "requestId": "mac-test-8",
                "timeoutMs": 2_000,
                "action": [
                    "kind": "set_value",
                    "bundleId": "com.example.app",
                    "observationId": "observation-1",
                    "elementRef": "element-2",
                    "attribute": "AXURL",
                    "text": "https://example.test",
                ],
            ])
        }
    }

    @Test("emergency stop invalidates generations and only native code resumes it")
    func emergencyStopGeneration() {
        let state = MacOperatorSafetyState()
        let initial = state.snapshot()
        #expect(!initial.isStopped)

        state.stop()
        let stopped = state.snapshot()
        #expect(stopped.isStopped)
        #expect(stopped.generation == initial.generation + 1)

        state.resumeFromNativeUI()
        let resumed = state.snapshot()
        #expect(!resumed.isStopped)
        #expect(resumed.generation == stopped.generation + 1)
    }

    @Test("focused-window identity rejects a same-app window switch")
    func focusedWindowIdentity() {
        let observedWindow = AXUIElementCreateSystemWide()
        #expect(MacOperatorActuator.matchesFocusedWindow(
            observedWindow: observedWindow,
            observedWindowNumber: 41,
            observedProcessIdentifier: 700,
            focusedWindow: observedWindow,
            focusedWindowNumber: 41,
            focusedProcessIdentifier: 700
        ))
        #expect(!MacOperatorActuator.matchesFocusedWindow(
            observedWindow: observedWindow,
            observedWindowNumber: 41,
            observedProcessIdentifier: 700,
            focusedWindow: observedWindow,
            focusedWindowNumber: 42,
            focusedProcessIdentifier: 700
        ))
    }

    @Test("responses redact control characters and remain closed")
    func sanitizedFailureResponse() throws {
        let data = MacOperatorProtocol.failureData(
            requestID: "mac-test-9",
            code: "failed\nsecret"
        )
        let value = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(value["requestId"] as? String == "mac-test-9")
        #expect(value["ok"] as? Bool == false)
        #expect(value["error"] as? String == "failedsecret")
        #expect(Set(value.keys) == ["requestId", "ok", "error"])
    }

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
            try Self.callSocket(
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
            try Self.callSocket(
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
            try Self.callSocket(
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

    private static func callSocket(
        at path: String,
        value: [String: Any]
    ) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let length = MemoryLayout<sa_family_t>.size + path.utf8.count + 1
        address.sun_len = UInt8(length)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString {
                    _ = strlcpy(destination, $0, capacity)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(length))
            }
        }
        guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
        let request = try JSONSerialization.data(withJSONObject: value)
        try request.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  Darwin.send(descriptor, base, request.count, 0) == request.count
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            response.append(buffer, count: count)
        }
        return response
    }
}
