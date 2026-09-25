import Foundation
import Testing
@testable import TronMac

@Suite("LiveLaunchAgentManager")
struct LiveLaunchAgentManagerTests {
    private static let helper = "/fixture/Tron.app/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
    private static let command = "/fixture/Tron.app/Contents/Resources/Gateway/runtime/node-arm64 /fixture/Tron.app/Contents/Resources/Gateway/app/dist/index.js --host tailscale --port 9847"
    private static var healthy: LaunchAgentRuntimeInfo {
        LaunchAgentRuntimeInfo(
            pid: 42, parentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            parentBundleVersion: "2", executablePath: helper, processCommand: command,
            gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue,
            gatewayChannelMarker: TronGatewayProfile.stable.channel
        )
    }

    private enum Scenario: CaseIterable {
        case fresh, unregistered, missingJob, unknownRegistration, approval, current
        case takeover, takeoverUnregistered, takeoverUnknown
        case oldBuild, unknownBuild, constraints, supervision, channel, oldHelper, missingHelper
        case companion, companionMissing, companionStale, missingCommand, stoppedStale
    }

    @Test("registration decisions use runtime/application inputs, not injected policy flags", arguments: Scenario.allCases)
    private func decisionMatrix(_ scenario: Scenario) {
        var status: ExistingInstallDetector.ServiceRegistrationStatus = .enabled
        var runtime: LaunchAgentRuntimeInfo? = Self.healthy
        var variant: MacRuntimeVariant = .installedRelease
        var canManage = true
        var helperExists = true
        var version: String? = "2"
        let repair = LaunchAgentRegistrationPlan.change(steps: [.bootout, .unregister, .register])
        let expected: LaunchAgentRegistrationPlan
        switch scenario {
        case .fresh, .unregistered:
            status = scenario == .fresh ? .notFound : .notRegistered
            runtime = nil; expected = .change(steps: [.register])
        case .missingJob:
            runtime = nil; expected = .change(steps: [.unregister, .register])
        case .unknownRegistration:
            status = .unknown("synthetic"); runtime = nil; expected = .change(steps: [.unregister, .register])
        case .approval:
            status = .requiresApproval
            expected = .refuse(message: "Approve Tron Agent in Login Items to finish installation.")
        case .current:
            expected = .keep
        case .takeover, .takeoverUnknown, .takeoverUnregistered:
            runtime?.parentBundleIdentifier = MacRuntimeVariant.debugBundleIdentifier
            if scenario == .takeoverUnknown { status = .unknown("synthetic") }
            if scenario == .takeoverUnregistered { status = .notRegistered }
            expected = scenario == .takeoverUnregistered ? .change(steps: [.bootout, .register]) : repair
        case .oldBuild:
            runtime?.parentBundleVersion = "1"; expected = repair
        case .unknownBuild:
            runtime?.parentBundleVersion = "1"; version = nil; expected = .keep
        case .constraints:
            runtime?.needsLaunchConstraintRefresh = true; expected = repair
        case .supervision:
            runtime?.gatewaySupervisionMarker = nil; expected = repair
        case .channel:
            runtime?.gatewayChannelMarker = "dev"; expected = repair
        case .oldHelper:
            runtime?.executablePath = "/fixture/old/helper"; expected = repair
        case .missingHelper:
            helperExists = false; expected = repair
        case .companion:
            canManage = false; variant = .xcodeDebug; expected = .keep
        case .companionMissing, .companionStale:
            canManage = false; variant = .xcodeDebug
            if scenario == .companionMissing { runtime = nil } else { runtime?.gatewaySupervisionMarker = nil }
            expected = .refuse(message: "This Xcode Debug wrapper is a read-only companion. Use /Applications/Tron.app to manage Stable.")
        case .missingCommand:
            runtime?.processCommand = nil
            expected = .refuse(message: "Could not verify the running Gateway command. No registration changes were made.")
        case .stoppedStale:
            runtime?.pid = nil; runtime?.processCommand = nil; expected = repair
        }
        let plan = LiveLaunchAgentManager.registrationPlan(
            status: status, currentVariant: variant, runtimeInfo: runtime,
            canManageLaunchAgent: canManage, expectedHelperPath: Self.helper,
            currentParentBundleVersion: version, fileExists: { $0 == Self.helper && helperExists }
        )
        #expect(plan == expected)
    }

    @Test("runtime ownership requires exact parent, supervision, channel and helper identity")
    func runtimeOwnershipProjectionIsExact() {
        let runtime = Self.healthy
        #expect(LiveLaunchAgentManager.runtimeOwnsProfile(
            runtimeInfo: runtime, profile: .stable,
            expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
        #expect(!LiveLaunchAgentManager.runtimeOwnsProfile(
            runtimeInfo: runtime, profile: .stable,
            expectedParentBundleIdentifier: MacRuntimeVariant.debugBundleIdentifier,
            expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
        #expect(!LiveLaunchAgentManager.runtimeOwnsProfile(
            runtimeInfo: runtime, profile: .stable,
            expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            expectedHelperPath: Self.helper, expectedSupervisionMarker: "0", fileExists: { _ in true }
        ))
    }

    @Test("relative BundleProgram alone cannot replace exact running command identity")
    func runtimeProvenanceUsesLaunchctlAndProcessIdentity() {
        #expect(LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: LaunchAgentRuntimeInfo(pid: 42), expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
        var runtime = Self.healthy
        runtime.executablePath = nil
        runtime.bundleProgram = "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
        #expect(!LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: runtime, expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
        runtime.gatewayChannelMarker = "dev"
        #expect(LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: runtime, expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
        runtime.gatewayChannelMarker = "stable"
        runtime.bundleProgram = "Contents/Library/LoginItems/Other.app/Contents/MacOS/tron"
        #expect(LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: runtime, expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
        runtime.bundleProgram = "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
        runtime.processCommand = "/fixture/Other.app/Contents/Resources/Gateway/runtime/node-arm64 /fixture/Other.app/Contents/Resources/Gateway/app/dist/index.js --port 9847"
        #expect(LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: runtime, expectedHelperPath: Self.helper, fileExists: { _ in true }
        ))
    }

    @Test("external direct server blocks registration only without an owned service")
    func externalDirectServerBlocksRegistration() {
        #expect(LiveLaunchAgentManager.shouldRefuseExternalServer(status: .notRegistered, runningParentBundleIdentifier: nil, portBound: true))
        #expect(!LiveLaunchAgentManager.shouldRefuseExternalServer(status: .notFound, runningParentBundleIdentifier: nil, portBound: false))
        #expect(!LiveLaunchAgentManager.shouldRefuseExternalServer(status: .notRegistered, runningParentBundleIdentifier: "com.tron.mac", portBound: true))
    }

    @Test("unregistration remains idempotent when ServiceManagement is already clear")
    func unregistrationPreflightHandlesAlreadyClearState() {
        #expect(LiveLaunchAgentManager.preUnregistrationOutcome(for: .notRegistered) == .ok)
        if case .binaryMissing(let path) = LiveLaunchAgentManager.preUnregistrationOutcome(for: .notFound) {
            #expect(path.hasSuffix("/Contents/Library/LaunchAgents/com.tron.server.plist"))
        } else { Issue.record("Expected missing LaunchAgent plist to block unregister") }
        #expect(LiveLaunchAgentManager.preUnregistrationOutcome(for: .enabled) == nil)
        #expect(LiveLaunchAgentManager.preUnregistrationOutcome(for: .requiresApproval) == nil)
    }

    @Test("capture failure is not a not-loaded runtime observation")
    func failedRuntimeCaptureCannotAuthorizeRegistration() throws {
        #expect(throws: LiveLaunchAgentManager.ObservationFailure.self) {
            try LiveLaunchAgentManager.runtimeOutputAvailable(ProcessResult(exitCode: -1, stdout: "pid = 42", stderr: "timed out"))
        }
        #expect(try LiveLaunchAgentManager.runtimeOutputAvailable(ProcessResult(exitCode: 0, stdout: "state = waiting", stderr: "")))
    }

    @Test("failed port observation is not a free port", arguments: [
        ProcessResult(exitCode: -1, stdout: "", stderr: "cancelled"),
        ProcessResult(exitCode: 1, stdout: "", stderr: "permission denied"),
        ProcessResult(exitCode: 2, stdout: "", stderr: ""),
        ProcessResult(exitCode: 1, stdout: "partial output", stderr: "")
    ])
    func failedPortObservation(result: ProcessResult) {
        #expect(throws: LiveLaunchAgentManager.ObservationFailure.self) { try LiveLaunchAgentManager.portBound(result) }
    }

    @Test("normal listener presence and no-match results remain distinct")
    func normalPortObservation() throws {
        #expect(try LiveLaunchAgentManager.portBound(ProcessResult(exitCode: 0, stdout: "listener", stderr: "")))
        #expect(try !LiveLaunchAgentManager.portBound(ProcessResult(exitCode: 1, stdout: "", stderr: "")))
    }

    @Test("live executor awaits each accepted step exactly once, including after cancellation", arguments: [false, true])
    func executionOrder(cancelled: Bool) async {
        let recorder = LaunchAgentStepRecorder()
        let pending = Task {
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            return await LiveLaunchAgentManager.execute([.bootout, .unregister, .register]) { step in
                await recorder.append(step)
                return nil
            }
        }
        #expect(await pending.value == nil)
        #expect(await recorder.steps == [.bootout, .unregister, .register])
        let empty = await LiveLaunchAgentManager.execute([]) { _ in
            Issue.record("Empty sequence dispatched a step"); return nil
        }
        #expect(empty == nil)
    }

    @Test("live executor returns the first failure without later steps or replay", arguments: [
        LaunchAgentRegistrationPlan.Step.bootout, .unregister, .register
    ])
    func executionStopsAtFailure(failedStep: LaunchAgentRegistrationPlan.Step) async {
        let recorder = LaunchAgentStepRecorder()
        let failure = LaunchAgentOutcome.unknown(message: "synthetic accepted outcome")
        let result = await LiveLaunchAgentManager.execute([.bootout, .unregister, .register]) { step in
            await recorder.append(step)
            return step == failedStep ? failure : nil
        }
        #expect(result == failure)
        let expected: [LaunchAgentRegistrationPlan.Step]
        switch failedStep {
        case .bootout: expected = [.bootout]
        case .unregister: expected = [.bootout, .unregister]
        case .register: expected = [.bootout, .unregister, .register]
        }
        #expect(await recorder.steps == expected)
    }
}

private actor LaunchAgentStepRecorder {
    var steps: [LaunchAgentRegistrationPlan.Step] = []
    func append(_ step: LaunchAgentRegistrationPlan.Step) { steps.append(step) }
}

@Suite("LaunchAgentLoader")
struct LaunchAgentLoaderTests {
    @Test("fresh registration does not force restart")
    func newlyLoadedDoesNotRestart() async {
        let mock = MockLaunchAgentManager()
        let outcome = await LaunchAgentLoader.ensureLoaded(manager: mock, plistPath: URL(fileURLWithPath: "/fixture/agent.plist"), label: "fixture")
        #expect(outcome == .ok)
        #expect(mock.calls.map(\.kind) == [.load])
    }

    @Test("registration failure prevents restart; restart failure is preserved")
    func failuresAreNotReplayed() async {
        let mock = MockLaunchAgentManager()
        let failure = LaunchAgentOutcome.launchdRefused(message: "synthetic failure")
        mock.loadOutcome = failure
        #expect(await LaunchAgentLoader.ensureLoaded(manager: mock, plistPath: URL(fileURLWithPath: "/fixture/agent.plist"), label: "fixture") == failure)
        #expect(mock.calls.map(\.kind) == [.load])
        let loaded = MockLaunchAgentManager()
        loaded.loadOutcome = .alreadyLoaded
        loaded.restartOutcome = failure
        #expect(await LaunchAgentLoader.ensureLoaded(manager: loaded, plistPath: URL(fileURLWithPath: "/fixture/agent.plist"), label: "fixture") == failure)
        #expect(loaded.calls.map(\.kind) == [.load, .restart])
    }
}
