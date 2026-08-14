import Foundation
@testable import TronMac

final class MockGatewayServiceManager: GatewayServiceManaging, @unchecked Sendable {
    enum Call: Equatable {
        case status
        case register
        case unregister
        case restart
        case loaded
        case runtime
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var _status: GatewayServiceRegistrationStatus = .notRegistered
    private var _registerOutcome: GatewayServiceOutcome = .registered
    private var _unregisterOutcome: GatewayServiceOutcome = .unregistered
    private var _restartOutcome: GatewayServiceOutcome = .registered
    private var _loaded = false
    private var _runtime: GatewayRuntimeInfo?
    var operationDelayNanoseconds: UInt64 = 0

    var calls: [Call] { lock.withLock { recordedCalls } }
    var status: GatewayServiceRegistrationStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var registerOutcome: GatewayServiceOutcome {
        get { lock.withLock { _registerOutcome } }
        set { lock.withLock { _registerOutcome = newValue } }
    }
    var unregisterOutcome: GatewayServiceOutcome {
        get { lock.withLock { _unregisterOutcome } }
        set { lock.withLock { _unregisterOutcome = newValue } }
    }
    var restartOutcome: GatewayServiceOutcome {
        get { lock.withLock { _restartOutcome } }
        set { lock.withLock { _restartOutcome = newValue } }
    }
    var loaded: Bool {
        get { lock.withLock { _loaded } }
        set { lock.withLock { _loaded = newValue } }
    }
    var runtime: GatewayRuntimeInfo? {
        get { lock.withLock { _runtime } }
        set { lock.withLock { _runtime = newValue } }
    }

    func registrationStatus(
        configuration: GatewayServiceConfiguration
    ) async -> GatewayServiceRegistrationStatus {
        record(.status)
        await delay()
        return status
    }

    func register(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome {
        record(.register)
        await delay()
        let outcome = registerOutcome
        if outcome == .registered || outcome == .alreadyRegistered { status = .enabled }
        return outcome
    }

    func unregister(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome {
        record(.unregister)
        await delay()
        let outcome = unregisterOutcome
        if outcome == .unregistered { status = .notRegistered }
        return outcome
    }

    func restart(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome {
        record(.restart)
        await delay()
        return restartOutcome
    }

    func isLoaded(configuration: GatewayServiceConfiguration) async -> Bool {
        record(.loaded)
        return loaded
    }

    func runtimeInfo(configuration: GatewayServiceConfiguration) async -> GatewayRuntimeInfo? {
        record(.runtime)
        return runtime
    }

    private func record(_ call: Call) { lock.withLock { recordedCalls.append(call) } }

    private func delay() async {
        guard operationDelayNanoseconds > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: operationDelayNanoseconds)
        } catch {
            return
        }
    }
}
