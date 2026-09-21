import AppKit
import SwiftUI
import Testing
@testable import TronMac

@Suite("Wizard presentation request fencing", .serialized)
@MainActor
struct PresentationRequestFenceTests {
    @Test("Pairing Info does not publish a late failure after it disappears")
    func detachedPairingRequestCannotPublishFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-pairing-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let gate = ObservationGate()
        var setup = MacAppStartupMaintenanceTests.makeSetup(
            tmp: temporaryDirectory,
            currentVersion: MacAppVersionIdentity(canonicalVersion: "test", buildNumber: "1")
        )
        setup.profile = .debug
        setup.serverPort = TronGatewayProfile.debug.port
        setup.readBearerToken = { "test-token" }
        setup.observeDebugGateway = { _ in
            await gate.waitUntilReleased()
            return .unauthorized
        }

        let state = WizardState(stateURL: temporaryDirectory.appendingPathComponent("internal/mac/wizard-state.json"))
        let originalPayload = PairingPayload(host: "100.64.0.1", port: 9848, code: "test-code", label: "Test Mac")
        state.pairingPayload = originalPayload
        let hostingView = NSHostingView(rootView: PairingInfoStep(state: state)
            .environment(\.environmentSetup, setup)
            .frame(width: 640, height: 440))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        for _ in 0..<120 where !(await gate.hasEntered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasEntered)

        // Removing the production view retires its presentation lease while
        // the injected observation remains suspended in the owner boundary.
        window.contentView = nil
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(state.pairingPayload == originalPayload)
    }

    @Test("a replacement Pairing Info view keeps its success from a stale failure")
    func replacementRequestSurvivesOlderCancellation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-pairing-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let admission = Self.makeAdmission(home: temporaryDirectory)
        let observations = ObservationSequence(admission: admission)
        var setup = MacAppStartupMaintenanceTests.makeSetup(
            tmp: temporaryDirectory,
            currentVersion: MacAppVersionIdentity(canonicalVersion: "test", buildNumber: "1")
        )
        setup.profile = .debug
        setup.serverPort = TronGatewayProfile.debug.port
        setup.readBearerToken = { "test-token" }
        setup.observeDebugGateway = { _ in await observations.observe() }
        setup.readEnrollmentCode = { "replacement-code" }
        setup.probeTailscale = { .signedIn(address: "100.64.0.2") }

        let state = WizardState(stateURL: temporaryDirectory.appendingPathComponent("internal/mac/wizard-state.json"))
        state.pairingPayload = PairingPayload(host: "100.64.0.1", port: 9848, code: "old-code", label: "Old")
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }

        window.contentView = NSHostingView(rootView: PairingInfoStep(state: state)
            .environment(\.environmentSetup, setup)
            .frame(width: 640, height: 440))
        for _ in 0..<120 where !(await observations.firstRequestEntered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await observations.firstRequestEntered)

        // Replacing the root retires the first view while its admission await
        // is still suspended. The successor must be able to resolve pairing.
        window.contentView = NSHostingView(rootView: PairingInfoStep(state: state)
            .environment(\.environmentSetup, setup)
            .frame(width: 640, height: 440))
        for _ in 0..<200 where state.pairingPayload?.host != "100.64.0.2" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.pairingPayload?.host == "100.64.0.2")

        await observations.releaseFirstRequest()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.pairingPayload?.host == "100.64.0.2")
    }

    private static func makeAdmission(home: URL) -> DebugGatewayObserver.Admission {
        let manifest = GatewayPayloadManifest(
            channel: TronGatewayProfile.debug.channel,
            version: "test",
            gatewayVersion: "test",
            nodeVersion: "test",
            sourceRevision: "source",
            runtimeEpoch: "epoch",
            payloadFingerprint: "fingerprint"
        )
        let selected = GatewayPayloadValidationResult(root: home, manifest: manifest)
        let lifecycle = DebugGatewayObserver.Lifecycle(
            lifecycle: "ready", expectedHost: "127.0.0.1", expectedPort: TronGatewayProfile.debug.port,
            expectedHome: home.standardizedFileURL.path, supervisorPid: 1,
            supervisorStartIdentity: "supervisor", childPid: 2, childStartIdentity: "child",
            epoch: "epoch", sourceRevision: "source", buildFingerprint: "fingerprint"
        )
        return DebugGatewayObserver.Admission(
            lifecycle: lifecycle, processID: 2, uptime: nil, transportHost: "100.64.0.2",
            pairingTransportAvailable: true, selectedPayload: selected,
            info: ServerPingInfo(version: "test", gatewayChannel: TronGatewayProfile.debug.channel,
                                 sourceRevision: "source", buildFingerprint: "fingerprint", runtimeEpoch: "epoch")
        )
    }
}

private actor ObservationGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func waitUntilReleased() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ObservationSequence {
    private let admission: DebugGatewayObserver.Admission
    private var requestCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var firstReleased = false
    private(set) var firstRequestEntered = false

    init(admission: DebugGatewayObserver.Admission) {
        self.admission = admission
    }

    func observe() async -> DebugGatewayObserver.Observation {
        requestCount += 1
        guard requestCount == 1 else { return .admitted(admission) }
        firstRequestEntered = true
        if !firstReleased {
            await withCheckedContinuation { firstContinuation = $0 }
        }
        return .unauthorized
    }

    func releaseFirstRequest() {
        firstReleased = true
        firstContinuation?.resume()
        firstContinuation = nil
    }
}
