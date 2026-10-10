import Foundation
import Testing
@testable import TronMac

@MainActor
struct MacQuitCoordinatorTests {
    private func runtime(_ pid: Int?, command: String? = nil) -> LaunchAgentRuntimeInfo? {
        LaunchAgentRuntimeInfo(pid: pid, processCommand: command)
    }

    @Test("Quit waits for the exact Gateway process to disappear before retiring the native host")
    func waitsForExactGatewayThenRetiresNativeHost() async throws {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(nil)])
        let coordinator = coordinator(fixture)
        try await coordinator.quit()
        let state = await fixture.state()
        #expect(state.stopIDs.count == 1)
        #expect(state.stopIDs[0].hasPrefix("mac-quit-"))
        #expect(state.reads == 3)
        #expect(state.nativeRetired)
    }

    @Test("uncertain stop response leaves the native host untouched")
    func uncertainStopDoesNotRetireNativeHost() async {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale")], stopFailuresRemaining: 1)
        await #expect(throws: GatewayRestartClient.Failure.timeout) { try await coordinator(fixture).quit() }
        #expect(!(await fixture.state().nativeRetired))
    }

    @Test("a retry for the same runtime reuses the accepted stop command ID")
    func retryReusesCommandID() async throws {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(nil)], stopFailuresRemaining: 1)
        let coordinator = coordinator(fixture)
        await #expect(throws: GatewayRestartClient.Failure.timeout) { try await coordinator.quit() }
        try await coordinator.quit()
        let state = await fixture.state()
        #expect(state.stopIDs.count == 2)
        #expect(state.stopIDs[0] == state.stopIDs[1])
        #expect(state.nativeRetired)
    }

    @Test("missing process start identity prevents a stop request")
    func missingStartIdentityBlocksStop() async {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale")])
        await #expect(throws: MacQuitCoordinator.Failure.runtimeUnavailable) {
            try await MacQuitCoordinator(
                readRuntime: { await fixture.readRuntime() },
                processStartIdentity: { _ in nil },
                runtimeOwnershipHealthy: { true },
                serviceEnabled: { true },
                stopGateway: { try await fixture.stop(commandID: $0) },
                retireNativeHost: { try await fixture.retire() },
                wait: {}
            ).quit()
        }
        #expect((await fixture.state()).stopIDs.isEmpty)
    }

    @Test("runtime replacement before stop fails closed")
    func runtimeReplacementFailsBeforeStop() async {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(72, command: "/bundled/tron --host tailscale")])
        await #expect(throws: MacQuitCoordinator.Failure.runtimeReplaced) { try await coordinator(fixture).quit() }
        let state = await fixture.state()
        #expect(state.stopIDs.isEmpty)
        #expect(!state.nativeRetired)
    }

    @Test("replacement after accepted stop prevents native retirement")
    func runtimeReplacementAfterStopFailsClosed() async {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(72, command: "/bundled/tron --host tailscale")])
        await #expect(throws: MacQuitCoordinator.Failure.runtimeReplaced) { try await coordinator(fixture).quit() }
        let state = await fixture.state()
        #expect(state.stopIDs.count == 1)
        #expect(!state.nativeRetired)
    }

    @Test("native retirement failure prevents successful Quit")
    func nativeFailurePropagates() async {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(nil)], nativeFailuresRemaining: 1)
        await #expect(throws: NativeHostError.retirementFailed) { try await coordinator(fixture).quit() }
        #expect(!(await fixture.state().nativeRetired))
    }

    @Test("a retried Quit resumes native retirement when the enabled service has no running Gateway")
    func stoppedGatewayResumesNativeRetirement() async throws {
        let fixture = QuitFixture(readings: [nil], ownershipHealthy: false)
        try await coordinator(fixture, serviceEnabled: true).quit()
        let state = await fixture.state()
        #expect(state.stopIDs.isEmpty)
        #expect(state.nativeRetired)
    }

    @Test("a Quit whose native retirement failed after the Gateway stopped succeeds on retry")
    func retryAfterNativeFailureResumesRetirement() async throws {
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(nil), runtime(nil)], nativeFailuresRemaining: 1)
        let coordinator = coordinator(fixture, serviceEnabled: true)
        await #expect(throws: NativeHostError.retirementFailed) { try await coordinator.quit() }
        // launchd no longer reports the exact Gateway process as owned by this app.
        await fixture.setOwnershipHealthy(false)
        try await coordinator.quit()
        let state = await fixture.state()
        #expect(state.stopIDs.count == 1)
        #expect(state.nativeRetired)
    }

    @Test("a running Gateway that this app does not own is never stopped or retired")
    func foreignRunningGatewayIsRefused() async {
        let fixture = QuitFixture(readings: [runtime(71, command: "/foreign/tron --host tailscale")], ownershipHealthy: false)
        await #expect(throws: MacQuitCoordinator.Failure.unmanaged) { try await coordinator(fixture, serviceEnabled: true).quit() }
        let state = await fixture.state()
        #expect(state.stopIDs.isEmpty)
        #expect(!state.nativeRetired)
    }

    @Test("a stopped Gateway whose service is not enabled is refused")
    func disabledServiceIsRefusedWhenGatewayStopped() async {
        let fixture = QuitFixture(readings: [nil], ownershipHealthy: false)
        await #expect(throws: MacQuitCoordinator.Failure.unmanaged) { try await coordinator(fixture, serviceEnabled: false).quit() }
        let state = await fixture.state()
        #expect(state.stopIDs.isEmpty)
        #expect(!state.nativeRetired)
    }

    private func coordinator(_ fixture: QuitFixture, serviceEnabled: Bool = true) -> MacQuitCoordinator {
        MacQuitCoordinator(
            readRuntime: { await fixture.readRuntime() },
            processStartIdentity: { _ in "pid-start" },
            runtimeOwnershipHealthy: { await fixture.ownershipIsHealthy() },
            serviceEnabled: { serviceEnabled },
            stopGateway: { try await fixture.stop(commandID: $0) },
            retireNativeHost: { try await fixture.retire() },
            wait: {}
        )
    }
}

private actor QuitFixture {
    private var readings: [LaunchAgentRuntimeInfo?]
    private var stopFailuresRemaining: Int
    private var nativeFailuresRemaining: Int
    private var ownershipHealthy: Bool
    private var readCount = 0
    private var commands: [String] = []
    private var retired = false

    init(
        readings: [LaunchAgentRuntimeInfo?],
        stopFailuresRemaining: Int = 0,
        nativeFailuresRemaining: Int = 0,
        ownershipHealthy: Bool = true
    ) {
        self.readings = readings
        self.stopFailuresRemaining = stopFailuresRemaining
        self.nativeFailuresRemaining = nativeFailuresRemaining
        self.ownershipHealthy = ownershipHealthy
    }

    func readRuntime() -> LaunchAgentRuntimeInfo? {
        readCount += 1
        return readings.isEmpty ? nil : readings.removeFirst()
    }

    func ownershipIsHealthy() -> Bool {
        ownershipHealthy
    }

    func setOwnershipHealthy(_ healthy: Bool) {
        ownershipHealthy = healthy
    }

    func stop(commandID: String) throws -> GatewayStopClient.Response {
        commands.append(commandID)
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw GatewayRestartClient.Failure.timeout
        }
        return .init(stopping: true, scheduled: true)
    }

    func retire() throws {
        if nativeFailuresRemaining > 0 {
            nativeFailuresRemaining -= 1
            throw NativeHostError.retirementFailed
        }
        retired = true
    }

    func state() -> (reads: Int, stopIDs: [String], nativeRetired: Bool) {
        (readCount, commands, retired)
    }
}
