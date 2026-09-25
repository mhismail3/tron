import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarController")
@MainActor
struct MenuBarControllerTests {
    @Test("newest Debug refresh wins across restart and transport transition")
    func newestDebugRefreshWins() async {
        let sequence = DebugObservationSequence(
            first: admission(host: "100.64.0.8", pairable: true, pid: 41),
            second: admission(host: "127.0.0.1", pairable: false, pid: 42)
        )
        var debug = EnvironmentSetup.debug
        debug.observeDebugGateway = { _ in await sequence.next() }
        let controller = MenuBarController(setup: .live, debugSetup: debug)

        let first = controller.refreshDebugGatewayState()
        await sequence.waitForFirstRequest()
        let second = controller.refreshDebugGatewayState()
        await sequence.waitForSecondRequest()
        await second.value
        await sequence.releaseFirstRequest()
        await first.value

        #expect(controller.debugGatewayAdmission?.processID == 42)
        #expect(controller.debugGatewayAdmission?.transportHost == "127.0.0.1")
        #expect(controller.debugGatewayState == DebugGatewayMenuState.admitted(isPairable: false))
    }

    @Test("passive poll refreshes do not overwrite in-flight busy status")
    func passivePollDoesNotOverwriteBusyStatus() {
        let controller = MenuBarController(setup: .live)

        controller.applySnapshot(ServerStatusSnapshot(state: .busy(.restarting)))
        controller.applyPolledSnapshot(ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847)))

        #expect(controller.snapshot.state == .busy(.restarting))

        controller.applySnapshot(ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847)))
        #expect(controller.snapshot.state == .running(version: "0.5.0", port: 9847))
    }

    private func admission(host: String, pairable: Bool, pid: Int) -> DebugGatewayObserver.Admission {
        let fingerprint = String(repeating: "a", count: 64)
        let lifecycle = DebugGatewayObserver.Lifecycle(
            lifecycle: "ready", expectedHost: host, expectedPort: 9848,
            expectedHome: "/tmp/.tron-dev", supervisorPid: 40,
            supervisorStartIdentity: "supervisor", childPid: pid,
            childStartIdentity: "child-\(pid)", epoch: "epoch-\(pid)",
            sourceRevision: "revision", buildFingerprint: fingerprint
        )
        let payload = GatewayPayloadValidationResult(
            root: URL(fileURLWithPath: "/tmp/payload-\(pid)"),
            manifest: GatewayPayloadManifest(
                channel: "dev", version: "debug-\(pid)", gatewayVersion: "1.0.0",
                nodeVersion: "22", sourceRevision: "revision", runtimeEpoch: "epoch-\(pid)",
                payloadFingerprint: fingerprint
            )
        )
        return DebugGatewayObserver.Admission(
            lifecycle: lifecycle, processID: pid, uptime: nil,
            transportHost: host, pairingTransportAvailable: pairable,
            selectedPayload: payload,
            info: ServerPingInfo(
                version: "1.0.0", gatewayChannel: "dev", sourceRevision: "revision",
                buildFingerprint: fingerprint, runtimeEpoch: "epoch-\(pid)"
            )
        )
    }
}

/// Holds the first observation until the test has issued a newer refresh, so
/// the fence is exercised without a real-time sleep.
private actor DebugObservationSequence {
    let first: DebugGatewayObserver.Admission
    let second: DebugGatewayObserver.Admission
    private var calls = 0
    private var firstEntered = false
    private var secondEntered = false
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    init(first: DebugGatewayObserver.Admission, second: DebugGatewayObserver.Admission) {
        self.first = first
        self.second = second
    }

    func next() async -> DebugGatewayObserver.Observation {
        calls += 1
        if calls == 1 {
            firstEntered = true
            resumeEntryWaiters()
            await withCheckedContinuation { firstRelease = $0 }
            return .admitted(first)
        }
        secondEntered = true
        resumeEntryWaiters()
        return .admitted(second)
    }

    func waitForFirstRequest() async { await waitForEntry { self.firstEntered } }

    func waitForSecondRequest() async { await waitForEntry { self.secondEntered } }

    func releaseFirstRequest() {
        firstRelease?.resume()
        firstRelease = nil
    }

    private func waitForEntry(_ hasEntered: () -> Bool) async {
        if hasEntered() { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    private func resumeEntryWaiters() {
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
    }
}
