import Foundation
import os
import Testing
@testable import TronMac

@Suite("MenuBarActionHandler")
@MainActor
struct MenuBarActionHandlerTests {
    @Test("stopped registered Gateway starts without loading or restarting registration")
    func stoppedRegisteredStartsOnly() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let manager = MockLaunchAgentManager()
        manager.loaded = true
        manager.runtimeInfo = registeredRuntime()
        manager.startOutcome = .ok
        let restartCalls = CallCounter()
        var setup = makeSetup(root: root, manager: manager)
        setup.restartGateway = {
            restartCalls.increment()
            return GatewayRestartClient.Response(restarting: true, scheduled: true, activeSessionIds: [])
        }
        let presentation = PresentationRecorder()

        await makeHandler(setup: setup, presentation: presentation).perform(.restartServer)

        #expect(manager.calls.map(\.kind) == [.isLoaded, .runtimeInfo, .start])
        #expect(restartCalls.value == 0)
        #expect(presentation.notificationCount == 1)
        #expect(presentation.errorCount == 0)
    }

    @Test("absent Gateway uses registration load and does not issue a start or restart")
    func absentLoads() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let manager = MockLaunchAgentManager()
        manager.loaded = false
        manager.runtimeInfo = nil
        manager.loadOutcome = .ok
        let restartCalls = CallCounter()
        var setup = makeSetup(root: root, manager: manager)
        setup.restartGateway = {
            restartCalls.increment()
            return GatewayRestartClient.Response(restarting: true, scheduled: true, activeSessionIds: [])
        }
        let presentation = PresentationRecorder()

        await makeHandler(setup: setup, presentation: presentation).perform(.restartServer)

        #expect(manager.calls.map(\.kind) == [.isLoaded, .load])
        #expect(manager.calls.last?.plistPath == setup.launchAgentPlistPath)
        #expect(restartCalls.value == 0)
        #expect(presentation.notificationCount == 1)
        #expect(presentation.errorCount == 0)
    }

    @Test("running authenticated Gateway uses the Gateway restart without launchd start")
    func runningUsesAuthenticatedRestart() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let manager = MockLaunchAgentManager()
        manager.loaded = true
        manager.runtimeInfo = registeredRuntime(pid: 42)
        let restartCalls = CallCounter()
        var setup = makeSetup(root: root, manager: manager)
        setup.restartGateway = {
            restartCalls.increment()
            return GatewayRestartClient.Response(restarting: true, scheduled: true, activeSessionIds: ["session"])
        }
        let presentation = PresentationRecorder()

        await makeHandler(setup: setup, presentation: presentation).perform(.restartServer)

        #expect(manager.calls.map(\.kind) == [.isLoaded, .runtimeInfo])
        #expect(restartCalls.value == 1)
        #expect(presentation.notificationCount == 1)
        #expect(presentation.errorCount == 0)
    }

    @Test("loaded row with missing runtime observation refuses without mutation")
    func missingRuntimeObservationRefuses() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let manager = MockLaunchAgentManager()
        manager.loaded = true
        manager.runtimeInfo = nil
        let restartCalls = CallCounter()
        var setup = makeSetup(root: root, manager: manager)
        setup.restartGateway = {
            restartCalls.increment()
            return GatewayRestartClient.Response(restarting: true, scheduled: true, activeSessionIds: [])
        }
        let presentation = PresentationRecorder()

        await makeHandler(setup: setup, presentation: presentation).perform(.restartServer)

        #expect(manager.calls.map(\.kind) == [.isLoaded, .runtimeInfo])
        #expect(restartCalls.value == 0)
        #expect(presentation.notificationCount == 1)
        #expect(presentation.errorCount == 1)
    }

    @Test("running unowned Gateway refuses without mutation")
    func unownedRuntimeRefuses() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let manager = MockLaunchAgentManager()
        manager.loaded = true
        var runtime = registeredRuntime(pid: 42)
        runtime.parentBundleIdentifier = "com.foreign.wrapper"
        manager.runtimeInfo = runtime
        let restartCalls = CallCounter()
        var setup = makeSetup(root: root, manager: manager)
        setup.runtimeOwnershipHealthy = { false }
        setup.restartGateway = {
            restartCalls.increment()
            return GatewayRestartClient.Response(restarting: true, scheduled: true, activeSessionIds: [])
        }
        let presentation = PresentationRecorder()

        await makeHandler(setup: setup, presentation: presentation).perform(.restartServer)

        #expect(manager.calls.map(\.kind) == [.isLoaded, .runtimeInfo])
        #expect(restartCalls.value == 0)
        #expect(presentation.notificationCount == 1)
        #expect(presentation.errorCount == 1)
    }

    private func makeHandler(
        setup: EnvironmentSetup,
        presentation: PresentationRecorder
    ) -> MenuBarActionHandler {
        MenuBarActionHandler(
            setup: setup,
            postNotification: { title, body in
                presentation.recordNotification(title: title, body: body)
            },
            presentError: { title, message in
                presentation.recordError(title: title, message: message)
            }
        )
    }

    private func makeSetup(root: URL, manager: MockLaunchAgentManager) -> EnvironmentSetup {
        MacAppStartupMaintenanceTests.makeSetup(
            tmp: root,
            currentVersion: MacAppVersionIdentity(canonicalVersion: "fixture", buildNumber: "1"),
            runtimeOwnershipHealthy: true,
            launchAgentManager: manager
        )
    }

    private func registeredRuntime(pid: Int? = nil) -> LaunchAgentRuntimeInfo {
        LaunchAgentRuntimeInfo(
            pid: pid,
            uptime: pid == nil ? nil : "1s",
            parentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            parentBundleVersion: "1",
            executablePath: "/tmp/Tron Agent.app/Contents/MacOS/tron",
            bundleProgram: "Contents/MacOS/tron",
            processCommand: pid == nil ? nil : "/tmp/Tron Agent.app/Contents/MacOS/tron",
            gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue,
            gatewayChannelMarker: TronGatewayProfile.stable.channel,
            launchCount: 1,
            lastExitCode: pid == nil ? 0 : nil,
            processStartIdentity: pid == nil ? nil : "fixture-start",
            gatewayExitPolicy: "stop-on-success"
        )
    }
}

private final class PresentationRecorder: @unchecked Sendable {
    private struct State {
        var notifications: [(String, String)] = []
        var errors: [(String, String)] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var notificationCount: Int { lock.withLock { $0.notifications.count } }
    var errorCount: Int { lock.withLock { $0.errors.count } }

    func recordNotification(title: String, body: String) {
        lock.withLock { $0.notifications.append((title, body)) }
    }

    func recordError(title: String, message: String) {
        lock.withLock { $0.errors.append((title, message)) }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { lock.withLock { $0 } }

    func increment() {
        lock.withLock { $0 += 1 }
    }
}
