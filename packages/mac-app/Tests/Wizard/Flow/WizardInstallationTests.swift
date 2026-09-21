import Foundation
import Observation
import os
import Testing
@testable import TronMac

@Suite("WizardInstallation")
@MainActor
struct WizardInstallationTests {
    private static func isolatedStateURL() -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tron-wizard-install-\(UUID().uuidString)", isDirectory: true)
        return (root.appendingPathComponent("internal/mac/wizard-state.json"), {
            try? FileManager.default.removeItem(at: root)
        })
    }

    @Test("accepted install survives cancelled view waiter and navigation without duplicate admission")
    func acceptedLifetime() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        let state = WizardState(stateURL: stateURL, initialStep: .install)
        let manager = MockLaunchAgentManager()
        manager.loadOutcome = .alreadyLoaded
        var setup = try makeSetup(root: root, manager: manager)
        let gate = WizardGate()
        let watchdog = watch([gate])
        defer { watchdog.cancel() }
        setup.validateBundledHelper = {
            await gate.hold()
            #expect(!Task.isCancelled, "Navigation cancelled the accepted install owner")
            return Task.isCancelled ? "cancelled signature observation" : nil
        }
        let accepted = state.requestInstall(using: setup)
        let duplicate = state.requestInstall(using: setup)
        #expect(state.installIsRunning)
        #expect(await gate.waitForEntry())
        #expect(state.installStages[.validateHelper] == .running)
        #expect(manager.calls.isEmpty)
        let viewWaiter = Task { await accepted.value }
        viewWaiter.cancel()
        state.goBack()
        state.advance()
        #expect(state.step == .install)
        #expect(state.installStages[.validateHelper] == .running)
        await gate.open()
        await viewWaiter.value
        await duplicate.value
        #expect(state.installOutcome == .success)
        #expect(!state.installIsRunning)
        #expect(!state.needsInstallDetection)
        #expect(InstallPipelineStage.allCases.allSatisfy { state.installStages[$0] == .succeeded })
        #expect(manager.calls.map(\.kind) == [.load, .restart])
        #expect(manager.calls.first?.plistPath == setup.launchAgentPlistPath)
        #expect(manager.calls.allSatisfy { $0.label == setup.launchAgentLabel })
        state.goBack(); state.advance()
        #expect(manager.calls.map(\.kind) == [.load, .restart])
    }

    @Test("busy presentation observes both admission and retirement")
    func busyObservation() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        let state = WizardState(stateURL: stateURL, initialStep: .install)
        var setup = try makeSetup(root: root, manager: MockLaunchAgentManager())
        setup.validateBundledHelper = { "synthetic failure" }
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = state.installIsRunning } onChange: {
            changes.withLock { $0 += 1 }
        }
        let accepted = state.requestInstall(using: setup)
        #expect(changes.withLock { $0 } == 1)
        withObservationTracking { _ = state.installIsRunning } onChange: {
            changes.withLock { $0 += 1 }
        }
        await accepted.value
        #expect(changes.withLock { $0 } == 2)
        #expect(!state.installIsRunning)
    }

    @Test("accepted task retains a dismissed wizard only until completion")
    func ownerRetirement() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        var state: WizardState? = WizardState(stateURL: stateURL, initialStep: .install)
        weak var owner = state
        var setup = try makeSetup(root: root, manager: MockLaunchAgentManager())
        let gate = WizardGate()
        let watchdog = watch([gate])
        defer { watchdog.cancel() }
        setup.validateBundledHelper = { await gate.hold(); return "synthetic failure" }
        let accepted = try #require(state).requestInstall(using: setup)
        state = nil
        #expect(await gate.waitForEntry())
        #expect(owner != nil)
        await gate.open()
        await accepted.value
        #expect(owner == nil)
    }

    @Test("first failed stage prevents later work", arguments: ["application", "helper", "payload", "plist", "authority", "registration"])
    func firstFailure(stage: String) async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        let state = WizardState(stateURL: stateURL, initialStep: .install)
        let manager = MockLaunchAgentManager()
        var setup = try makeSetup(root: root, manager: manager)
        setup.pingServer = { _ in Issue.record("Failure reached ping"); return .success(ServerPingInfo(version: "fixture", gatewayChannel: "stable")) }
        let expected: InstallOutcome
        switch stage {
        case "application":
            setup.validateApplicationLocation = { "location failure" }
            setup.validateBundledHelper = { Issue.record("Invalid location reached helper validation"); return nil }
            expected = .invalidApplicationLocation("location failure")
        case "helper":
            setup.validateBundledHelper = { "helper failure" }
            setup.validateGatewayPayload = { Issue.record("Invalid helper reached payload validation"); return nil }
            expected = .helperValidationFailed("helper failure")
        case "payload":
            setup.validateGatewayPayload = { "payload failure" }
            expected = .helperValidationFailed("payload failure")
        case "plist":
            try Data("invalid plist".utf8).write(to: setup.launchAgentPlistPath)
            expected = .helperValidationFailed("The bundled LaunchAgent plist is invalid. Reinstall Tron.app.")
        case "authority":
            setup.canManageLaunchAgent = false
            expected = .serviceRegistrationFailed("This Xcode Debug wrapper is a read-only companion. Use /Applications/Tron.app to install or manage Stable.")
        default:
            manager.loadOutcome = .unknown(message: "unconfirmed")
            expected = .serviceRegistrationFailed("unconfirmed")
        }
        await state.requestInstall(using: setup).value
        #expect(state.installOutcome == expected)
        #expect(!state.installIsRunning)
        #expect(manager.calls.map(\.kind) == (stage == "registration" ? [.load] : []))
    }

    @Test("retry is a new explicit task with fresh progress after failure")
    func explicitRetry() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        let state = WizardState(stateURL: stateURL, initialStep: .install)
        let manager = MockLaunchAgentManager()
        var setup = try makeSetup(root: root, manager: manager)
        setup.validateBundledHelper = { "synthetic failure" }
        await state.requestInstall(using: setup).value
        #expect(state.installOutcome == .helperValidationFailed("synthetic failure"))
        #expect(manager.calls.isEmpty)
        setup.validateBundledHelper = { nil }
        let retry = state.requestInstall(using: setup)
        #expect(state.installOutcome == nil)
        #expect(state.installStages[.validateHelper] == .pending)
        #expect(state.installIsRunning)
        await retry.value
        #expect(state.installOutcome == .success)
        #expect(manager.calls.map(\.kind) == [.load])
        #expect(!state.installIsRunning)
    }

    @Test("entry discovery cannot overwrite a newer in-flight or completed install", arguments: [false, true])
    func staleDiscovery(finishInstallFirst: Bool) async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        let state = WizardState(stateURL: stateURL, initialStep: .install)
        var setup = try makeSetup(root: root, manager: MockLaunchAgentManager())
        let discovery = WizardGate()
        let validation = WizardGate()
        let watchdog = watch([discovery, validation])
        defer { watchdog.cancel() }
        let observation = Task {
            await state.refreshExistingInstall {
                await discovery.hold()
                return .registered(version: "obsolete")
            }
        }
        #expect(await discovery.waitForEntry())
        setup.validateBundledHelper = { await validation.hold(); return "synthetic failure" }
        let accepted = state.requestInstall(using: setup)
        #expect(await validation.waitForEntry())
        if finishInstallFirst {
            await validation.open()
            await accepted.value
        }
        await discovery.open()
        await observation.value
        #expect(state.existingInstallStatus == .none)
        await validation.open()
        await accepted.value
        #expect(state.installOutcome == .helperValidationFailed("synthetic failure"))
    }

    @Test("cancelled discovery cannot publish, but a fresh observation can")
    func cancelledDiscovery() async {
        let (stateURL, cleanup) = Self.isolatedStateURL()
        defer { cleanup() }
        let state = WizardState(stateURL: stateURL)
        let gate = WizardGate()
        let watchdog = watch([gate])
        defer { watchdog.cancel() }
        let observation = Task {
            await state.refreshExistingInstall { await gate.hold(); return .registered(version: "obsolete") }
        }
        #expect(await gate.waitForEntry())
        observation.cancel()
        await gate.open()
        await observation.value
        #expect(state.existingInstallStatus == .none)
        await state.refreshExistingInstall { .registered(version: "current") }
        #expect(state.existingInstallStatus == .registered(version: "current"))
    }

    private func makeSetup(root: URL, manager: MockLaunchAgentManager) throws -> EnvironmentSetup {
        var setup = MacAppStartupMaintenanceTests.makeSetup(
            tmp: root, currentVersion: MacAppVersionIdentity(canonicalVersion: "fixture", buildNumber: "1"),
            launchAgentManager: manager
        )
        try FileManager.default.createDirectory(at: setup.launchAgentPlistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: macAppRoot().appendingPathComponent("Sources/Resources/Library/LaunchAgents/com.tron.server.plist"),
            to: setup.launchAgentPlistPath
        )
        setup.detectExistingInstall = { Issue.record("Install repeated obsolete entry discovery"); return .none }
        return setup
    }

    private func watch(_ gates: [WizardGate]) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            Issue.record("Owned wizard gate watchdog fired")
            for gate in gates { await gate.expire() }
        }
    }
}

private actor WizardGate {
    private var entered = false
    private var released = false
    private var expired = false
    private var readers: [CheckedContinuation<Bool, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        readers.forEach { $0.resume(returning: !expired) }
        readers.removeAll()
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func waitForEntry() async -> Bool {
        if expired { return false }
        if entered { return true }
        return await withCheckedContinuation { readers.append($0) }
    }

    func open() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func expire() {
        expired = true
        readers.forEach { $0.resume(returning: false) }
        readers.removeAll()
        open()
    }
}
