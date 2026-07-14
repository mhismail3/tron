import Foundation
import Testing

@testable import TronMobile

@Suite("PairedServerTokenStore")
struct PairedServerTokenStoreTests {
    private func makeServerId(_ tag: String = #function) -> String {
        "test-\(tag.replacingOccurrences(of: "()", with: ""))-\(UUID().uuidString)"
    }

    private func makeBackend(
        capture: KeychainLifecycleCapture = KeychainLifecycleCapture()
    ) -> (HostedTestPairedServerTokenBackend, KeychainLifecycleCapture) {
        (
            HostedTestPairedServerTokenBackend(emitter: capture.emitter),
            capture
        )
    }

    @Test("setToken then token(forServerId:) returns the stored value")
    func roundTrip() throws {
        let (backend, _) = makeBackend()
        defer { backend.cleanup() }
        let store = backend.makeStore()
        let id = makeServerId()

        try store.setToken("test-bearer-token", forServerId: id)

        #expect(store.token(forServerId: id) == "test-bearer-token")
    }

    @Test("tokens are isolated per server id")
    func isolatedPerServer() throws {
        let (backend, _) = makeBackend()
        defer { backend.cleanup() }
        let store = backend.makeStore()
        let idA = makeServerId("isolatedA")
        let idB = makeServerId("isolatedB")

        try store.setToken("token-A", forServerId: idA)
        try store.setToken("token-B", forServerId: idB)

        #expect(store.token(forServerId: idA) == "token-A")
        #expect(store.token(forServerId: idB) == "token-B")
    }

    @Test("setToken overwrites the previous token")
    func overwrite() throws {
        let (backend, _) = makeBackend()
        defer { backend.cleanup() }
        let store = backend.makeStore()
        let id = makeServerId()

        try store.setToken("first", forServerId: id)
        try store.setToken("second", forServerId: id)

        #expect(store.token(forServerId: id) == "second")
    }

    @Test("fresh wrappers share the injected backend")
    func overwriteSurvivesStoreRecreation() throws {
        let (backend, _) = makeBackend()
        defer { backend.cleanup() }
        let id = makeServerId()

        try backend.makeStore().setToken("old-token", forServerId: id)
        try backend.makeStore().setToken("rotated-token", forServerId: id)

        #expect(backend.makeStore().token(forServerId: id) == "rotated-token")
    }

    @Test("remove(serverId:) deletes the stored token")
    func removal() throws {
        let (backend, _) = makeBackend()
        defer { backend.cleanup() }
        let store = backend.makeStore()
        let id = makeServerId()

        try store.setToken("doomed", forServerId: id)
        try store.remove(serverId: id)

        #expect(store.token(forServerId: id) == nil)
    }

    @Test("server without a stored token is treated as unpaired")
    func serverWithoutTokenIsUnpaired() {
        let (backend, _) = makeBackend()
        defer { backend.cleanup() }

        #expect(backend.makeStore().token(forServerId: makeServerId()) == nil)
    }

    @Test("registration and cleanup identities are unique, balanced, and secret-free")
    func lifecycleIsBalancedAndSecretFree() throws {
        let capture = KeychainLifecycleCapture()
        let (backend, _) = makeBackend(capture: capture)
        let store = backend.makeStore()
        let accountA = makeServerId("ledger-a")
        let accountB = makeServerId("ledger-b")
        let secret = "must-never-enter-ledger"

        try store.setToken(secret, forServerId: accountA)
        _ = store.token(forServerId: accountB)
        backend.cleanup()
        backend.cleanup()

        let records = capture.records
        let registered = records.filter { $0.event == .registered }
        let cleaned = records.filter { $0.event == .cleaned }
        #expect(Set(registered.map(\.account)) == Set([accountA, accountB]))
        #expect(Set(cleaned.map(\.account)) == Set([accountA, accountB]))
        #expect(registered.count == 2)
        #expect(cleaned.count == 2)
        #expect(backend.isEmpty)
        #expect(!capture.lines.joined().contains(secret))
        #expect(records.allSatisfy { $0.service != PairedServerTokenStore.keychainServicePrefix })
    }

    @Test("throw cleanup and process fallback are idempotent")
    func throwAndProcessFallbackCleanup() throws {
        struct ProbeError: Error {}
        let capture = KeychainLifecycleCapture()
        let registry = AppRuntimeCleanupRegistry()
        let (backend, _) = makeBackend(capture: capture)
        let registration = registry.register { backend.cleanup() }

        do {
            try backend.makeStore().setToken("throw-secret", forServerId: makeServerId("throw"))
            throw ProbeError()
        } catch is ProbeError {
            registry.cleanupAll()
            registry.deregister(registration)
            backend.cleanup()
        }

        #expect(backend.isEmpty)
        #expect(capture.records.filter { $0.event == .registered }.count == 1)
        #expect(capture.records.filter { $0.event == .cleaned }.count == 1)
        #expect(!capture.lines.joined().contains("throw-secret"))
    }

    @Test("lifecycle parser rejects malformed and production identities")
    func lifecycleParserIsStrict() {
        let namespace = UUID().uuidString
        let valid = HostedTestKeychainLifecycleRecord(
            event: .registered,
            namespace: namespace,
            service: "com.tron.tests.bearer.\(namespace)",
            account: "server"
        )
        #expect(HostedTestKeychainLifecycleRecord.parse(line: valid.line) == valid)

        for line in [
            valid.line.replacingOccurrences(of: "V1", with: "V2"),
            HostedTestKeychainLifecycleRecord.prefix + "{}",
            HostedTestKeychainLifecycleRecord.prefix + "{\"event\":\"registered\",\"namespace\":\"\(namespace)\",\"service\":\"\(PairedServerTokenStore.keychainServicePrefix)\",\"account\":\"server\"}",
            HostedTestKeychainLifecycleRecord.prefix + "{\"event\":\"registered\",\"namespace\":\"\(namespace)\",\"service\":\"com.tron.tests.bearer.\(namespace)\",\"account\":\"server\",\"token\":\"secret\"}",
        ] {
            #expect(HostedTestKeychainLifecycleRecord.parse(line: line) == nil)
        }
    }
}

private final class KeychainLifecycleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedLines: [String] = []

    lazy var emitter = HostedTestKeychainLifecycleEmitter { [self] line in
        lock.lock()
        capturedLines.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        let result = capturedLines
        lock.unlock()
        return result
    }

    var records: [HostedTestKeychainLifecycleRecord] {
        lines.compactMap(HostedTestKeychainLifecycleRecord.parse)
    }
}
