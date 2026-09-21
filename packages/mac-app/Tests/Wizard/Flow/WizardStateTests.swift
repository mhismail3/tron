import Foundation
import os
import Testing
@testable import TronMac

@Suite("WizardState")
@MainActor
struct WizardStateTests {
    static func isolatedURL() -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tron-wizard-\(UUID().uuidString)", isDirectory: true)
        return (root.appendingPathComponent("internal/mac/wizard-state.json"), {
            try? FileManager.default.removeItem(at: root)
        })
    }

    @Test("fresh state starts at welcome without a durable record")
    func freshStarts() {
        let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
        let state = WizardState(stateURL: url)
        #expect(state.step == .welcome)
        #expect(state.persistenceFailure == nil)
        #expect(state.installOutcome == nil)
    }

    @Test("step changes publish a versioned private file and revive")
    func stepPersists() throws {
        let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
        let state = WizardState(stateURL: url)
        state.advance(); state.advance()
        #expect(state.step == .install)
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["step"] as? String == WizardStep.install.rawValue)
        #expect(((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        #expect(WizardState(stateURL: url).step == .install)
    }

    @Test("safe cold resume clamps transient steps and done")
    func coldResumeClamp() {
        for step in [WizardStep.permissions, .pairingInfo, .done] {
            let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
            let state = WizardState(stateURL: url, initialStep: step)
            #expect(state.step == step)
            #expect(WizardState(stateURL: url).step == .welcome)
        }
    }

    @Test("safe persisted steps revive")
    func safePersistedStepsRevive() {
        let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
        let state = WizardState(stateURL: url, initialStep: .install)
        #expect(state.step == .install)
        #expect(WizardState(stateURL: url).step == .install)
    }

    @Test("navigation remains bounded and explicit")
    func navigationBounds() {
        let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
        let state = WizardState(stateURL: url)
        for _ in 0..<20 { state.advance() }
        #expect(state.step == .done)
        state.goBack()
        #expect(state.slideDirection == .backward)
        state.skipToPairing()
        #expect(state.step == .pairingInfo)
    }

    @Test("malformed and newer records fail closed without being overwritten")
    func malformedRecord() throws {
        let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":99,"step":"install","future":true}"#.utf8)
        try original.write(to: url)
        #expect(WizardState(stateURL: url).step == .welcome)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a malformed record is replaced only by an explicit initial step")
    func explicitInitialStepMayReplaceInvalidRecord() throws {
        let (url, cleanup) = Self.isolatedURL(); defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":99,"step":"install"}"#.utf8).write(to: url)
        #expect(WizardState(stateURL: url, initialStep: .welcome).step == .welcome)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["version"] as? Int == WizardState.stateFileVersion)
        #expect(object?["step"] as? String == WizardStep.welcome.rawValue)
    }
}

@Suite("Wizard completion")
@MainActor
struct WizardCompletionTests {
    private enum SentinelError: Error, Sendable { case writeFailed }

    @Test("sentinel write gates the single completion notification")
    func sentinelWriteGatesNotification() throws {
        let center = NotificationCenter()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let observer = center.addObserver(forName: .tronWizardDidComplete, object: nil, queue: nil) { _ in count.withLock { $0 += 1 } }
        defer { center.removeObserver(observer) }
        #expect(throws: SentinelError.self) {
            try commitWizardCompletion(touchSentinel: { throw SentinelError.writeFailed }, notificationCenter: center)
        }
        #expect(count.withLock { $0 } == 0)
        try commitWizardCompletion(touchSentinel: {}, notificationCenter: center)
        #expect(count.withLock { $0 } == 1)
    }
}
