import Testing
@testable import TronMac

@Suite("Mock Gateway service manager")
struct MockGatewayServiceManagerTests {
    @Test("records typed calls and configured outcomes")
    func recordsCalls() async {
        let manager = MockGatewayServiceManager()
        manager.status = .enabled
        manager.registerOutcome = .alreadyRegistered
        let configuration = GatewayPaths.configuration(mode: .development)

        #expect(await manager.registrationStatus(configuration: configuration) == .enabled)
        #expect(await manager.register(configuration: configuration) == .alreadyRegistered)
        #expect(manager.calls == [.status, .register])
    }
}
