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
        let fixture = QuitFixture(readings: [runtime(71, command: "/bundled/tron --host tailscale"), runtime(71, command: "/bundled/tron --host tailscale"), runtime(nil)], nativeFailure: true)
        await #expect(throws: NativeHostError.retirementFailed) { try await coordinator(fixture).quit() }
        #expect(!(await fixture.state().nativeRetired))
    }

    private func coordinator(_ fixture: QuitFixture) -> MacQuitCoordinator {
        MacQuitCoordinator(
            readRuntime: { await fixture.readRuntime() },
            processStartIdentity: { _ in "pid-start" },
            runtimeOwnershipHealthy: { true },
            stopGateway: { try await fixture.stop(commandID: $0) },
            retireNativeHost: { try await fixture.retire() },
            wait: {}
        )
    }
}

private actor QuitFixture {
    private var readings: [LaunchAgentRuntimeInfo?]
    private var stopFailuresRemaining: Int
    private let nativeFailure: Bool
    private var readCount = 0
    private var commands: [String] = []
    private var retired = false

    init(readings: [LaunchAgentRuntimeInfo?], stopFailuresRemaining: Int = 0, nativeFailure: Bool = false) {
        self.readings = readings
        self.stopFailuresRemaining = stopFailuresRemaining
        self.nativeFailure = nativeFailure
    }

    func readRuntime() -> LaunchAgentRuntimeInfo? {
        readCount += 1
        return readings.isEmpty ? nil : readings.removeFirst()
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
        if nativeFailure { throw NativeHostError.retirementFailed }
        retired = true
    }

    func state() -> (reads: Int, stopIDs: [String], nativeRetired: Bool) {
        (readCount, commands, retired)
    }
}
