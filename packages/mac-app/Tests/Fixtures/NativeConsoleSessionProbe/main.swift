import Foundation
import IOKit.pwr_mgt
@testable import TronNativeCaptureHost

struct ProbeFailure: Error { let message: String }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw ProbeFailure(message: message) }
}
final class ConsoleState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NativeConsoleSessionState
    private var validationAllowed = true
    func validate() -> Bool { lock.withLock { validationAllowed } }
    func disallowValidation() { lock.withLock { validationAllowed = false } }
    init(_ value: NativeConsoleSessionState) { self.value = value }
    func get() -> NativeConsoleSessionState { lock.withLock { value } }
    func set(_ value: NativeConsoleSessionState) { lock.withLock { self.value = value } }
}
func state(console: Bool = true, login: Bool = true, locked: Bool = false, saver: Bool? = nil,
           asleep: Bool = false, lid: Bool? = nil, displays: Int = 1) -> NativeConsoleSessionState {
    NativeConsoleSessionState(onConsole: console, loginDone: login, screenLocked: locked, screensaverActive: saver,
                              displaysAsleep: asleep, lidClosed: lid, activeDisplayCount: displays, topologyGeneration: UUID())
}
func assertionCount() throws -> Int {
    var result: Unmanaged<CFDictionary>?
    try require(IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess, "IOPM assertions unavailable")
    let assertions = result!.takeRetainedValue() as NSDictionary
    let own = assertions[NSNumber(value: getpid())] as? [[String: Any]] ?? []
    return own.filter { $0[kIOPMAssertionNameKey] as? String == "Tron active computer turn" }.count
}
struct Session {
    let native: NativeCaptureSession
    let load = UUID()
    let boot: UUID
    let connection: UUID
    let session: UUID
    init(_ source: ConsoleState) async throws {
        let boot = UUID()
        native = NativeCaptureSession(bootID: boot, ownerID: UUID(), slot: NativeCaptureSlot(), fence: NativeCaptureFence(current: { true }),
            operations: NativeCaptureOperations(validate: { source.validate() }, catalog: { _ in throw ProbeFailure(message: "capture touched a refused console") },
                automationEndpoint: { NativeAutomationEndpoint(socket: "/tmp/tron-cua-probe/s", generation: boot) }, sessionState: { source.get() }))
        self.boot = boot
        connection = await native.connectionID
        session = await native.sessionID
        let hello = try await request("hello")
        try require(hello["status"] as? String == "ready", "hello failed")
    }
    func peerLost() async -> NativeCaptureRetirement {
        native.fence.close()
        return await native.drain()
    }
    func request(_ operation: String, read: UInt64? = nil) async throws -> [String: Any] {
        var object: [String: Any] = ["version": 1, "operation": operation, "loadID": load.uuidString]
        if let read { object["readSequence"] = read } else { object["commandID"] = UUID().uuidString }
        if operation != "hello" {
            object["bootID"] = boot.uuidString; object["connectionID"] = connection.uuidString; object["sessionID"] = session.uuidString
        }
        let request = try NativeCaptureRequest.decode(JSONSerialization.data(withJSONObject: object))
        let response = await native.execute(request)
        return try JSONSerialization.jsonObject(with: response.control) as! [String: Any]
    }
}
func run() async throws {
    let initial = NativeConsoleSession().snapshot()
    try require((0...64).contains(initial.activeDisplayCount), "unbounded real display snapshot")
    let ready = ConsoleState(state())
    for (snapshot, cause) in [(state(locked: true), "mac_locked"), (state(saver: true), "mac_locked"),
                              (state(asleep: true), "display_asleep"), (state(console: false), "no_console_session"),
                              (state(login: false), "no_console_session"), (state(lid: true, displays: 0), "no_active_display")] {
        let source = ConsoleState(snapshot)
        let session = try await Session(source)
        source.disallowValidation()
        let published = try await session.request("sessionState", read: 1)
        let fields = published["state"] as! [String: Any]
        try require(fields["cause"] as? String == cause, "wrong snapshot cause")
        try require(fields.count == 9 && fields["topologyGeneration"] as? String == snapshot.topologyGeneration.uuidString, "snapshot shape or topology")
        let start = DispatchTime.now().uptimeNanoseconds
        let response = try await session.request("catalog")
        try require(response["status"] as? String == cause, "capture admission lost cause")
        try require(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000, "refusal exceeded one second")
        _ = await session.peerLost()
        let computerSource = ConsoleState(snapshot)
        let computer = try await Session(computerSource)
        computerSource.disallowValidation()
        let refused = try await computer.request("automationEndpoint")
        try require(refused["status"] as? String == cause, "computer admission lost cause")
        _ = await computer.peerLost()
    }
    for exit in ["stop", "peerLost", "locked"] {
        let session = try await Session(ready)
        _ = try await session.request("automationEndpoint")
        _ = try await session.request("automationEndpoint")
        try require(try assertionCount() == 1, "activity assertion absent or duplicated")
        for sequence in 1...100 {
            let snapshot = try await session.request("sessionState", read: UInt64(sequence))
            try require(snapshot["status"] as? String == "sessionState", "disposable reads consumed command receipts")
        }
        switch exit {
        case "stop":
            let stopped = try await session.request("stop")
            try require(stopped["status"] as? String == "joined", "Stop did not join")
        case "peerLost":
            let joined = await session.peerLost()
            try require(joined.joined, "peer loss did not join")
        default:
            ready.set(state(locked: true))
            let refused = try await session.request("catalog")
            try require(refused["status"] as? String == "mac_locked", "active lease admitted locked desktop")
            _ = await session.peerLost()
            ready.set(state())
        }
        try require(try assertionCount() == 0, "activity assertion leaked after \(exit)")
    }
    print("PASS: real snapshot; finite capture/computer refusals; 100 disposable reads; scoped IOPM release after Stop, peer loss and lock")
}
Task {
    do { try await run(); exit(0) }
    catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
}
dispatchMain()
