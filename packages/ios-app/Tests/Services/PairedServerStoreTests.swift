import Foundation
import Testing
@testable import TronMobile

@Suite("PairedServerStore")
@MainActor
struct PairedServerStoreTests {
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let suite = "PairedServerStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func server(
        id: String = "server-1",
        label: String = "Studio",
        host: String = "100.64.0.1",
        port: Int = 9847
    ) -> PairedServer {
        PairedServer(id: id, label: label, host: host, port: port)
    }

    @Test("starts empty with no hidden localhost pairing")
    func startsEmpty() {
        let store = PairedServerStore(defaults: defaults())

        #expect(store.servers.isEmpty)
        #expect(store.activeServer == nil)
        #expect(store.activeServerId == nil)
    }

    @Test("replace persists local servers and active id")
    func replacePersists() {
        let defaults = defaults()
        let first = server(id: "a")
        let second = server(id: "b", host: "100.64.0.2")

        let store = PairedServerStore(defaults: defaults)
        store.replace([first, second], activeId: second.id)

        let restored = PairedServerStore(defaults: defaults)
        #expect(restored.servers == [first, second])
        #expect(restored.activeServerId == second.id)
        #expect(restored.activeServer == second)
    }

    @Test("active id normalizes to first real server when stale")
    func staleActiveIdNormalizes() {
        let defaults = defaults()
        let first = server(id: "a")
        let data = try! JSONEncoder().encode([first])
        defaults.set(data, forKey: PairedServerStore.serversKey)
        defaults.set("missing", forKey: PairedServerStore.activeIdKey)

        let store = PairedServerStore(defaults: defaults)

        #expect(store.activeServerId == "a")
        #expect(store.activeServer == first)
    }

    @Test("selecting a server only changes local active id")
    func selectIsLocalOnly() {
        let defaults = defaults()
        let first = server(id: "a")
        let second = server(id: "b", host: "100.64.0.2")
        let store = PairedServerStore(defaults: defaults)
        store.replace([first, second], activeId: first.id)

        store.select(second)

        #expect(store.activeServer == second)
        #expect(defaults.string(forKey: PairedServerStore.activeIdKey) == second.id)
    }

    @Test("forgetting inactive server keeps active server")
    func forgetInactive() {
        let first = server(id: "a")
        let second = server(id: "b", host: "100.64.0.2")
        let store = PairedServerStore(defaults: defaults())
        store.replace([first, second], activeId: first.id)

        let plan = store.remove(second)

        #expect(plan.removedWasActive == false)
        #expect(plan.nextActiveServer == nil)
        #expect(plan.shouldReturnToOnboarding == false)
        #expect(store.servers == [first])
        #expect(store.activeServer == first)
    }

    @Test("forgetting active server selects next local server without contacting removed server")
    func forgetActiveSelectsNext() {
        let first = server(id: "a")
        let second = server(id: "b", host: "100.64.0.2")
        let store = PairedServerStore(defaults: defaults())
        store.replace([first, second], activeId: first.id)

        let plan = store.remove(first)

        #expect(plan.removedWasActive == true)
        #expect(plan.nextActiveServer == second)
        #expect(plan.shouldReturnToOnboarding == false)
        #expect(store.servers == [second])
        #expect(store.activeServer == second)
    }

    @Test("forgetting final server clears active id")
    func forgetFinalClearsActive() {
        let only = server(id: "only")
        let store = PairedServerStore(defaults: defaults())
        store.replace([only], activeId: only.id)

        let plan = store.remove(only)

        #expect(plan.removedWasActive == true)
        #expect(plan.nextActiveServer == nil)
        #expect(plan.shouldReturnToOnboarding == true)
        #expect(store.servers.isEmpty)
        #expect(store.activeServerId == nil)
        #expect(store.activeServer == nil)
    }

    @Test("pairing same host and port refreshes existing id without duplicate")
    func pairingSameEndpointReusesServer() {
        let existing = server(id: "stable", label: "Studio", host: "100.64.0.9", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: existing.host,
            port: existing.port,
            token: "new-token",
            label: "Ignored New Label"
        )

        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [existing],
            idGenerator: { "new-id-should-not-appear" }
        )

        #expect(plan.activeServer == existing)
        #expect(plan.updatedServers == [existing])
        #expect(plan.token == "new-token")
    }
}
