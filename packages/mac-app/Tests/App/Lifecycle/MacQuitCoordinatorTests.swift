import Foundation
import Testing
@testable import TronMac

@Suite("Coordinated Quit", .serialized)
@MainActor struct MacQuitCoordinatorTests {
    @Test func nonOwnersAndCommandModesNeverCoordinateServiceShutdown() {
        #expect(MacQuitCoordinator.shouldCoordinate(mode: .onboarded, ownsLock: true, canManage: true))
        #expect(!MacQuitCoordinator.shouldCoordinate(mode: .onboarded, ownsLock: false, canManage: true))
        for mode in [MacStartupMode.testHost, .debugReadOnly, .command(.startServerAndQuit), .command(.uninstallAndQuit)] {
            #expect(!MacQuitCoordinator.shouldCoordinate(mode: mode, ownsLock: true, canManage: true))
        }
    }
    @Test func waitsForCleanExitBeforeNativeRetirementAndUnregister() async throws {
        let probe = QuitProbe([Self.running, Self.running, Self.stopped, Self.stopped, nil])
        try await fixture(probe) { coordinator, manager in
            try await coordinator.quit(); try await coordinator.quit()
            #expect(await probe.events == ["read", "shutdown", "read", "read", "native", "read", "read"])
            #expect(manager.calls.map(\.kind) == [.unload])
        }
    }
    @Test func successorAppearingDuringNativeRetirementCannotBeUnregistered() async throws {
        let probe = QuitProbe([Self.running, Self.stopped, Self.running])
        try await fixture(probe) { coordinator, manager in
            await #expect(throws: MacQuitCoordinator.Failure.self) { try await coordinator.quit() }
            #expect(await probe.events == ["read", "shutdown", "read", "native", "read"])
            #expect(manager.calls.isEmpty)
        }
    }

    @Test func replacementOrAbnormalExitCannotDisableNativeOrQuit() async throws {
        for replacement in [LaunchAgentRuntimeInfo(pid: 43, launchCount: 2, processStartIdentity: "other", gatewayExitPolicy: "stop-on-success"),
                            LaunchAgentRuntimeInfo(launchCount: 1, lastExitCode: 1, gatewayExitPolicy: "stop-on-success")] {
            let probe = QuitProbe([Self.running, replacement])
            try await fixture(probe) { coordinator, manager in
                await #expect(throws: MacQuitCoordinator.Failure.self) { try await coordinator.quit() }
                #expect(await probe.events == ["read", "shutdown", "read"])
                #expect(manager.calls.isEmpty)
            }
        }
    }
    @Test("initially stopped foreign registration is not authorized for Quit")
    func initiallyStoppedForeignRegistrationRefusesBeforeShutdown() async throws {
        let probe = QuitProbe([LaunchAgentRuntimeInfo(
            parentBundleIdentifier: "com.foreign.wrapper",
            executablePath: "/foreign/helper",
            gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue,
            gatewayChannelMarker: TronGatewayProfile.stable.channel,
            gatewayExitPolicy: "stop-on-success"
        )])
        try await fixture(probe) { coordinator, manager in
            await #expect(throws: MacQuitCoordinator.Failure.self) { try await coordinator.quit() }
            #expect(await probe.events == ["read"])
            #expect(manager.calls.isEmpty)
        }
    }

    @Test func missingExitPolicyRefusesBeforeShutdown() async throws {
        let probe = QuitProbe([LaunchAgentRuntimeInfo(pid: 42, launchCount: 1, processStartIdentity: "first")])
        try await fixture(probe) { coordinator, manager in
            await #expect(throws: MacQuitCoordinator.Failure.self) { try await coordinator.quit() }
            #expect(await probe.events == ["read"]); #expect(manager.calls.isEmpty)
        }
    }
    @Test func lostAcknowledgementRetainsTheSameCommandForTheSameRuntime() async throws {
        let probe = QuitProbe([Self.running, Self.running, Self.stopped, Self.stopped, nil])
        await probe.failAcknowledgement()
        try await fixture(probe) { coordinator, manager in
            await #expect(throws: GatewayRestartClient.Failure.self) { try await coordinator.quit() }
            #expect(manager.calls.isEmpty)
            try await coordinator.quit()
            let commands = await probe.commands
            #expect(commands.count == 2 && commands[0] == commands[1])
            #expect(manager.calls.map(\.kind) == [.unload])
        }
    }
    @Test func nativeFailureLeavesGatewayRegistrationAndAllowsExplicitRetry() async throws {
        let probe = QuitProbe([Self.running, Self.stopped, Self.stopped, Self.stopped, nil])
        await probe.failNative()
        try await fixture(probe) { coordinator, manager in
            await #expect(throws: NativeHostError.self) { try await coordinator.quit() }
            #expect(manager.calls.isEmpty)
            try await coordinator.quit()
            #expect(await probe.commands.count == 1)
            #expect(manager.calls.map(\.kind) == [.unload])
        }
    }
    @Test func concurrentQuitAndCancelledWaiterStillJoinOneNativeRetirement() async throws {
        let probe = QuitProbe([Self.running, Self.stopped, Self.stopped, nil], holdNative: true)
        try await fixture(probe) { coordinator, manager in
            let first = Task { try await coordinator.quit() }
            _ = await probe.nativeEntered.value()
            let second = Task { try await coordinator.quit() }
            first.cancel()
            #expect(manager.calls.isEmpty)
            probe.nativeRelease.resolve(true)
            try await first.value; try await second.value
            #expect(await probe.commands.count == 1)
            #expect(manager.calls.map(\.kind) == [.unload])
        }
    }
    @Test func unregisterFailureIsNotSuccessfulQuit() async throws {
        let probe = QuitProbe([Self.running, Self.stopped, Self.stopped])
        try await fixture(probe) { coordinator, manager in
            manager.unloadOutcome = .unknown(message: "fixture refusal")
            await #expect(throws: MacQuitCoordinator.Failure.self) { try await coordinator.quit() }
            #expect(manager.calls.map(\.kind) == [.unload])
        }
    }
    private static let running = LaunchAgentRuntimeInfo(pid: 42, launchCount: 1, processStartIdentity: "first", gatewayExitPolicy: "stop-on-success")
    private static let stopped = LaunchAgentRuntimeInfo(launchCount: 1, lastExitCode: 0, gatewayExitPolicy: "stop-on-success")
    private func fixture(_ probe: QuitProbe, body: (MacQuitCoordinator, MockLaunchAgentManager) async throws -> Void) async throws {
        let root = TestTempDir.make(); defer { TestTempDir.cleanup(root) }
        let manager = MockLaunchAgentManager()
        var setup = MacAppStartupMaintenanceTests.makeSetup(tmp: root,
            currentVersion: .init(canonicalVersion: "test", buildNumber: "1"), launchAgentManager: manager)
        await probe.admitOwnedStoppedRegistration(helperPath: setup.serverHelperBinaryPath.path)
        setup.readGatewayForQuit = { try await probe.read() }
        setup.shutdownGateway = { try await probe.shutdown($0) }
        setup.suspendNativeHostForQuit = { try await probe.native() }
        try await body(MacQuitCoordinator(setup: setup, wait: {}), manager)
    }
}

private actor QuitProbe {
    private var observations: [LaunchAgentRuntimeInfo?]
    private(set) var events: [String] = []
    private(set) var commands: [String] = []
    private var badAck = false, badNative = false
    let nativeEntered = NativeHostReply<Bool>(), nativeRelease = NativeHostReply<Bool>()
    private let holdNative: Bool
    init(_ observations: [LaunchAgentRuntimeInfo?], holdNative: Bool = false) { self.observations = observations; self.holdNative = holdNative }
    func failAcknowledgement() { badAck = true }
    func failNative() { badNative = true }
    func admitOwnedStoppedRegistration(helperPath: String) {
        observations = observations.map { value in
            guard var value, value.pid == nil, value.lastExitCode == 0,
                  value.gatewayExitPolicy == "stop-on-success" else { return value }
            value.parentBundleIdentifier = MacRuntimeVariant.releaseBundleIdentifier
            value.executablePath = helperPath
            value.gatewaySupervisionMarker = TronPaths.gatewaySupervisionValue
            value.gatewayChannelMarker = TronGatewayProfile.stable.channel
            return value
        }
    }
    func read() throws -> LaunchAgentRuntimeInfo? {
        events.append("read")
        guard !observations.isEmpty else { throw LaunchAgentRuntimeReader.ObservationFailure.unavailable }
        return observations.removeFirst()
    }
    func shutdown(_ command: String) throws -> GatewayShutdownClient.Response {
        events.append("shutdown"); commands.append(command)
        if badAck { badAck = false; throw GatewayRestartClient.Failure.timeout }
        return .init(stopping: true, scheduled: true, activeSessionIds: ["fixture"])
    }
    func native() async throws {
        events.append("native"); nativeEntered.resolve(true)
        if holdNative { _ = await nativeRelease.value() }
        if badNative { badNative = false; throw NativeHostError.retirementFailed }
    }
}
