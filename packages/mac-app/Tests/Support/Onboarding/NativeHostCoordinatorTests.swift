import Foundation
import ServiceManagement
import Testing
@testable import TronMac

@Suite("Native helper setup phases", .serialized)
struct NativeHostCoordinatorTests {
    @Test("explicit enable attempts registration for a valid bundle reported notFound")
    func firstRegistrationPolicy() throws {
        #expect(try NativeHostRegistrationPolicy.shouldRegister(.notFound))
        #expect(try NativeHostRegistrationPolicy.shouldRegister(.notRegistered))
        #expect(try !NativeHostRegistrationPolicy.shouldRegister(.enabled))
        #expect(try !NativeHostRegistrationPolicy.shouldRegister(.requiresApproval))
    }

    @Test("retirement status policy never treats notFound as a joined helper")
    func retirementStatusPolicy() async throws {
        let fake = FakeNativeHost()
        try await NativeHostRetirementPolicy.drain(status: .notRegistered, join: fake.operations.drain)
        #expect(await fake.events.isEmpty)
        await #expect(throws: NativeHostError.self) {
            try await NativeHostRetirementPolicy.drain(status: .notFound, join: fake.operations.drain)
        }
        #expect(await fake.events.isEmpty)
        try await NativeHostRetirementPolicy.drain(status: .enabled, join: fake.operations.drain)
        try await NativeHostRetirementPolicy.drain(status: .requiresApproval, join: fake.operations.drain)
        #expect(await fake.events == ["drain", "drain"])
        await fake.failDrain()
        await #expect(throws: NativeHostError.self) {
            try await NativeHostRetirementPolicy.drain(status: .enabled, join: fake.operations.drain)
        }
    }

    @Test("notFound retirement prevents refresh registration and native join attempts")
    func ambiguousStatusCannotMutateService() async {
        let fake = FakeNativeHost(), original = fake.operations
        let operations = NativeHostOperations(state: original.state, enable: original.enable,
            unregister: original.unregister, drain: {
                try await NativeHostRetirementPolicy.drain(status: .notFound, join: original.drain)
            }, probe: original.probe, request: original.request)
        let owner = NativeHostCoordinator(operations: operations)
        await #expect(throws: NativeHostError.self) { _ = try await owner.refresh() }
        await #expect(throws: NativeHostError.self) { try await owner.unregister() }
        #expect(await fake.events.isEmpty)
    }

    @Test("enable errors reach the caller instead of becoming silent unavailable status")
    func enableFailureIsVisible() async {
        let fake = FakeNativeHost()
        await fake.failEnable()
        let owner = NativeHostCoordinator(operations: fake.operations)
        await #expect(throws: NativeHostError.self) { try await owner.enable() }
        #expect(await fake.events == ["register"])
    }

    @Test("probing and premature consent never register or request native permission")
    func noImplicitActivation() async {
        let fake = FakeNativeHost()
        let owner = NativeHostCoordinator(operations: fake.operations)
        #expect(await owner.probe() == NativeHostCoordinator.unavailable)
        #expect(await owner.request(.accessibility) == .probeUnavailable)
        #expect(await fake.events.isEmpty)
    }

    @Test("background approval is explicit and does not consume a consent request")
    func approvalThenConsent() async throws {
        let fake = FakeNativeHost()
        let owner = NativeHostCoordinator(operations: fake.operations)
        #expect(try await owner.enable() == .needsApproval)
        #expect(await owner.request(.accessibility) == .probeUnavailable)
        #expect(await fake.events == ["register"])
        await fake.approve()
        #expect(await owner.serviceState() == .enabled)
        #expect(await fake.events == ["register"], "Approval alone must not launch TCC prompts")
        let request = Task { await owner.request(.accessibility) }
        #expect(await fake.waitForRequest())
        fake.reply.resolve(.granted)
        #expect(await request.value == .granted)
        #expect(await fake.events == ["register", "request"])
    }

    @Test("cancelled waiters retain accepted consent and other permissions cannot overlap")
    func acceptedConsentIsRetained() async {
        let fake = FakeNativeHost()
        await fake.approve()
        let owner = NativeHostCoordinator(operations: fake.operations)
        let first = Task { await owner.request(.accessibility) }
        #expect(await fake.waitForRequest())
        first.cancel()
        #expect(await owner.request(.screenRecording) == .probeUnavailable)
        fake.reply.resolve(.granted)
        #expect(await first.value == .granted)
        #expect(await fake.requestIDs.count == 1)
    }

    @Test("explicit refresh removes the stale service before registering and never asks TCC")
    func explicitRefresh() async throws {
        let fake = FakeNativeHost()
        await fake.approve()
        let owner = NativeHostCoordinator(operations: fake.operations)
        #expect(try await owner.refresh() == .needsApproval)
        #expect(await fake.events == ["drain", "unregister", "register"])
        #expect(await fake.requestIDs.isEmpty)
    }

    @Test("failed refresh stops at unregister rather than registering over uncertain state")
    func refreshFailure() async {
        let fake = FakeNativeHost()
        await fake.approve(); await fake.failUnregister()
        let owner = NativeHostCoordinator(operations: fake.operations)
        await #expect(throws: NativeHostError.self) { try await owner.refresh() }
        #expect(await owner.serviceState() == .enabled)
        #expect(await fake.events == ["drain", "unregister"])
    }

    @Test("unregister errors are preserved and cannot turn enabled into absent")
    func unregisterFailure() async {
        let fake = FakeNativeHost()
        await fake.approve()
        await fake.failUnregister()
        let owner = NativeHostCoordinator(operations: fake.operations)
        await #expect(throws: NativeHostError.self) { try await owner.unregister() }
        #expect(await owner.serviceState() == .enabled)
        #expect(await fake.events == ["drain", "unregister"])
    }

    @Test("cancelled refresh waits for actual capture drain before unregister")
    func refreshJoinsCapture() async throws {
        let fake = FakeNativeHost()
        await fake.approve(); await fake.pauseDrain()
        let owner = NativeHostCoordinator(operations: fake.operations)
        let work = Task { try await owner.refresh() }
        _ = await fake.drainEntered.value()
        work.cancel()
        #expect(await fake.events == ["drain"])
        fake.drainRelease.resolve(true)
        _ = try await work.value
        #expect(await fake.events == ["drain", "unregister", "register"])
    }

    @Test("failed capture drain forbids refresh and unregister")
    func captureDrainFailure() async {
        for refresh in [false, true] {
            let fake = FakeNativeHost()
            await fake.approve(); await fake.failDrain()
            let owner = NativeHostCoordinator(operations: fake.operations)
            await #expect(throws: NativeHostError.self) {
                if refresh { _ = try await owner.refresh() }
                else { try await owner.unregister() }
            }
            #expect(await fake.events == ["drain"])
        }
    }

    @Test("Quit temporarily unregisters and reopening restores prior enabled intent without consent")
    func quitAndRestore() async throws {
        let fake = FakeNativeHost(), preferences = FakeNativePreferences()
        await fake.approve()
        let owner = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        try await owner.suspendForQuit()
        #expect(preferences.value == true)
        #expect(await fake.events == ["drain", "unregister"])
        let reopened = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        #expect(try await reopened.restoreIfDesired() == .needsApproval)
        #expect(try await reopened.restoreIfDesired() == .needsApproval)
        #expect(await fake.events == ["drain", "unregister", "register"])
        #expect(await fake.requestIDs.isEmpty)
    }

    @Test("Quit preserves a pending helper approval when intent is not yet recorded")
    func quitAndRestorePreservesPendingApproval() async throws {
        let fake = FakeNativeHost(), preferences = FakeNativePreferences()
        await fake.needsApproval()
        let owner = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        try await owner.suspendForQuit()
        #expect(preferences.value == true)
        let reopened = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        #expect(try await reopened.restoreIfDesired() == .needsApproval)
        #expect(await fake.events == ["drain", "unregister", "register"])
    }

    @Test("An explicitly disabled helper is not restored on launch")
    func disabledIntentStaysDisabled() async throws {
        let fake = FakeNativeHost(), preferences = FakeNativePreferences(true)
        await fake.approve()
        let owner = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        try await owner.unregister()
        #expect(preferences.value == false)
        #expect(try await owner.restoreIfDesired() == .needsRegistration)
        #expect(await fake.events == ["drain", "unregister"])
    }

    @Test("Failed temporary unregister cannot lose restore intent")
    func failedQuitPreservesIntent() async {
        let fake = FakeNativeHost(), preferences = FakeNativePreferences()
        await fake.approve(); await fake.failUnregister()
        let owner = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        await #expect(throws: NativeHostError.self) { try await owner.suspendForQuit() }
        #expect(preferences.value == true)
        #expect(await owner.serviceState() == .enabled)
    }

    @Test("Launch never enables an optional helper without prior intent")
    func noFirstLaunchActivation() async throws {
        let fake = FakeNativeHost(), preferences = FakeNativePreferences()
        let owner = NativeHostCoordinator(operations: fake.operations, preferences: preferences.operations)
        #expect(try await owner.restoreIfDesired() == .needsRegistration)
        #expect(await fake.events.isEmpty)
        #expect(preferences.value == nil)
    }
}

private extension NativeHostCoordinator {
    init(operations: NativeHostOperations) {
        self.init(operations: operations, preferences: FakeNativePreferences().operations)
    }
}

private final class FakeNativePreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    init(_ value: Bool? = nil) { stored = value }
    var value: Bool? { lock.withLock { stored } }
    var operations: NativeHostPreferences {
        .init(desiredEnabled: { self.value }, setDesiredEnabled: { value in self.lock.withLock { self.stored = value } })
    }
}

private actor FakeNativeHost {
    let reply = NativeHostReply<PermissionStatus>()
    private(set) var events: [String] = []
    private(set) var requestIDs: [UUID] = []
    private var status = NativeHostServiceState.needsRegistration
    private var unregisterFails = false
    private var enableFails = false
    private var drainFails = false
    let drainEntered = NativeHostReply<Bool>()
    let drainRelease = NativeHostReply<Bool>()
    private var holdDrain = false
    nonisolated var operations: NativeHostOperations {
        .init(state: { await self.state() }, enable: { try await self.enable() },
              unregister: { try await self.unregister() }, drain: { try await self.drain() }, probe: { await self.probe() },
              request: { await self.request($0, id: $1) })
    }
    func state() -> NativeHostServiceState { status }
    func needsApproval() { status = .needsApproval }
    func approve() { status = .enabled }
    func failUnregister() { unregisterFails = true }
    func failEnable() { enableFails = true }
    func failDrain() { drainFails = true }
    func pauseDrain() { holdDrain = true }
    func drain() async throws {
        events.append("drain"); drainEntered.resolve(true)
        if holdDrain { _ = await drainRelease.value() }
        if drainFails { throw NativeHostError.retirementFailed }
    }
    func enable() throws {
        events.append("register")
        if enableFails { throw NativeHostError.serviceUnavailable }
        status = .needsApproval
    }
    func unregister() throws {
        events.append("unregister")
        if unregisterFails { throw NativeHostError.serviceUnavailable }
        status = .needsRegistration
    }
    func probe() -> [Permission: PermissionStatus] {
        events.append("probe")
        return [.accessibility: .granted, .screenRecording: .granted]
    }
    func request(_ permission: Permission, id: UUID) async -> PermissionStatus {
        events.append("request"); requestIDs.append(id)
        return await reply.value()
    }
    func waitForRequest() async -> Bool {
        for _ in 0..<200 {
            if !requestIDs.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        reply.resolve(.probeUnavailable)
        return false
    }
}
