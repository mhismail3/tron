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
        #expect(await fake.events == ["unregister", "register"])
        #expect(await fake.requestIDs.isEmpty)
    }

    @Test("failed refresh stops at unregister rather than registering over uncertain state")
    func refreshFailure() async {
        let fake = FakeNativeHost()
        await fake.approve(); await fake.failUnregister()
        let owner = NativeHostCoordinator(operations: fake.operations)
        await #expect(throws: NativeHostError.self) { try await owner.refresh() }
        #expect(await owner.serviceState() == .enabled)
        #expect(await fake.events == ["unregister"])
    }

    @Test("unregister errors are preserved and cannot turn enabled into absent")
    func unregisterFailure() async {
        let fake = FakeNativeHost()
        await fake.approve()
        await fake.failUnregister()
        let owner = NativeHostCoordinator(operations: fake.operations)
        await #expect(throws: NativeHostError.self) { try await owner.unregister() }
        #expect(await owner.serviceState() == .enabled)
        #expect(await fake.events == ["unregister"])
    }
}

private actor FakeNativeHost {
    let reply = NativeHostReply<PermissionStatus>()
    private(set) var events: [String] = []
    private(set) var requestIDs: [UUID] = []
    private var status = NativeHostServiceState.needsRegistration
    private var unregisterFails = false
    private var enableFails = false
    nonisolated var operations: NativeHostOperations {
        .init(state: { await self.state() }, enable: { try await self.enable() },
              unregister: { try await self.unregister() }, probe: { await self.probe() },
              request: { await self.request($0, id: $1) })
    }
    func state() -> NativeHostServiceState { status }
    func approve() { status = .enabled }
    func failUnregister() { unregisterFails = true }
    func failEnable() { enableFails = true }
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
        return [.accessibility: .granted, .inputMonitoring: .granted, .screenRecording: .granted]
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
