import Foundation
import Testing

@testable import TronMobile

@Suite("Hosted test state lifecycle")
@MainActor
struct IsolatedTestStateLifecycleTests {
    @Test("lifecycle records are strict versioned event and suite envelopes")
    func lifecycleRecordParsingIsStrict() throws {
        let suite = "com.tron.tests.parser.01234567-89AB-CDEF-0123-456789ABCDEF"
        let record = HostedTestSuiteLifecycleRecord(event: .registered, suite: suite)

        #expect(HostedTestSuiteLifecycleRecord.parse(line: record.line) == record)
        for invalid in [
            "TRON_TEST_SUITE_LIFECYCLE_V2 {\"event\":\"registered\",\"suite\":\"\(suite)\"}",
            "TRON_TEST_SUITE_LIFECYCLE_V1 {\"event\":\"unknown\",\"suite\":\"\(suite)\"}",
            "TRON_TEST_SUITE_LIFECYCLE_V1 {\"event\":\"registered\"}",
            "TRON_TEST_SUITE_LIFECYCLE_V1 {\"event\":\"registered\",\"suite\":\"\(suite)\",\"extra\":true}",
            "TRON_TEST_SUITE_LIFECYCLE_V1 {\"event\":\"registered\",\"suite\":\"unowned\"}",
            "TRON_TEST_SUITE_LIFECYCLE_V1 {\"event\":\"registered\",\"suite\":\"com.tron.hosted-unit-tests.parser.01234567-89AB-CDEF-0123-456789ABCDEF\"}",
            "TRON_TEST_SUITE_LIFECYCLE_V1 not-json",
        ] {
            #expect(HostedTestSuiteLifecycleRecord.parse(line: invalid) == nil)
        }
    }

    @Test("lifecycle envelope accepts only registered cleaned empty plist artifacts")
    func lifecycleEnvelopeSyntheticMatrix() {
        let suite = "com.tron.tests.envelope.01234567-89AB-CDEF-0123-456789ABCDEF"
        let other = "com.tron.tests.envelope.ABCDEF01-2345-6789-ABCD-EF0123456789"
        let registered = HostedTestSuiteLifecycleRecord(event: .registered, suite: suite).line
        let cleaned = HostedTestSuiteLifecycleRecord(event: .cleaned, suite: suite).line
        let empty = SyntheticPreferenceEnvelope(suite: suite, location: .currentPreferences, node: .emptyPlist)

        #expect(SyntheticLifecycleEnvelopeGate.accepts(lines: [registered, cleaned], artifacts: []))
        #expect(SyntheticLifecycleEnvelopeGate.accepts(lines: [registered, cleaned], artifacts: [empty]))

        let failures: [([String], [SyntheticPreferenceEnvelope])] = [
            ([registered], []),
            ([cleaned], []),
            ([registered, registered, cleaned], []),
            ([registered, cleaned, cleaned], []),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: other, location: .currentPreferences, node: .emptyPlist),
            ]),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: suite, location: .currentPreferences, node: .nonemptyPlist),
            ]),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: suite, location: .currentPreferences, node: .malformed),
            ]),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: suite, location: .currentPreferences, node: .symlink),
            ]),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: suite, location: .currentPreferences, node: .directory),
            ]),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: suite, location: .wrongContainer, node: .emptyPlist),
            ]),
            ([registered, cleaned], [
                SyntheticPreferenceEnvelope(suite: "com.tron.tests.invalid", location: .currentPreferences, node: .emptyPlist),
            ]),
            ([registered, cleaned], [empty, empty]),
            ([registered, "TRON_TEST_SUITE_LIFECYCLE_V2 {}"], []),
        ]
        for failure in failures {
            #expect(!SyntheticLifecycleEnvelopeGate.accepts(lines: failure.0, artifacts: failure.1))
        }
    }

    @Test("registered fixture scopes clean once after ordinary and repeated cleanup")
    func fixtureLifecycleIsUniqueAndBalanced() throws {
        let capture = LifecycleCapture(forwardToStandard: true)
        let cleanupRegistry = HostedTestCleanupRegistry()

        IsolatedTestState.withDefaults(
            label: "ordinary-cleanup",
            lifecycleEmitter: capture.emitter,
            cleanupRegistry: cleanupRegistry
        ) { defaults in
            defaults.set("value", forKey: "sentinel")
        }

        let repeated = IsolatedTestState(
            label: "repeated-cleanup",
            lifecycleEmitter: capture.emitter,
            cleanupRegistry: cleanupRegistry
        )
        repeated.defaults.set("value", forKey: "sentinel")
        repeated.cleanupDefaultsSynchronously()
        repeated.cleanupDefaultsSynchronously()

        assertBalanced(capture.records)
        #expect(capture.records.count == 4)
    }

    @Test("process fallback cleans each registered fixture exactly once")
    func processFallbackLifecycleIsUniqueAndBalanced() {
        let capture = LifecycleCapture(forwardToStandard: true)
        let cleanupRegistry = HostedTestCleanupRegistry()
        let state = IsolatedTestState(
            label: "process-fallback",
            lifecycleEmitter: capture.emitter,
            cleanupRegistry: cleanupRegistry
        )
        let suiteName = state.suiteName
        let rootURL = state.rootURL
        state.defaults.set("value", forKey: "sentinel")

        cleanupRegistry.cleanupAll()
        state.cleanupDefaultsSynchronously()

        #expect(!FileManager.default.fileExists(atPath: rootURL.path))
        #expect(IsolatedTestState.persistentDomain(named: suiteName)?.isEmpty != false)
        assertBalanced(capture.records)
        #expect(capture.records.count == 2)
    }

    @Test("visual artifacts default under the registered root and are removed")
    func artifactFallbackIsOwnedAndCleaned() async throws {
        let capture = LifecycleCapture(forwardToStandard: true)
        let cleanupRegistry = HostedTestCleanupRegistry()
        var ownedRoot: URL?
        var suiteName: String?
        try await IsolatedTestState.withState(
            label: "artifact-fallback",
            lifecycleEmitter: capture.emitter,
            cleanupRegistry: cleanupRegistry
        ) { state in
            ownedRoot = state.rootURL
            suiteName = state.suiteName
            let artifact = try state.artifactURL(
                named: "render.txt",
                environment: [:]
            )
            #expect(
                artifact.deletingLastPathComponent()
                    == state.rootURL.appendingPathComponent("Artifacts", isDirectory: true)
            )
            try Data("fixture".utf8).write(to: artifact)
            #expect(FileManager.default.fileExists(atPath: artifact.path))
        }

        let root = try #require(ownedRoot)
        let suite = try #require(suiteName)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(IsolatedTestState.persistentDomain(named: suite)?.isEmpty != false)
        assertBalanced(capture.records)
    }

    @Test("absolute visual artifact override is honored exactly")
    func absoluteArtifactOverrideIsHonored() async throws {
        try await IsolatedTestState.withState(label: "artifact-override") { state in
            let override = state.rootURL
                .appendingPathComponent("DeclaredArtifacts", isDirectory: true)
            let artifact = try state.artifactURL(
                named: "render.png",
                environment: ["TRON_VISUAL_ARTIFACT_DIR": override.path]
            )

            #expect(artifact == override.appendingPathComponent("render.png"))
        }
    }

    @Test("empty and relative visual artifact overrides fail closed")
    func invalidArtifactOverridesFailClosed() async {
        await IsolatedTestState.withState(label: "artifact-invalid") { state in
            for value in ["", "relative/path"] {
                #expect(throws: IsolatedTestStateError.self) {
                    try state.artifactURL(
                        named: "render.png",
                        environment: ["TRON_VISUAL_ARTIFACT_DIR": value]
                    )
                }
            }
        }
    }

    @Test("async state scope cleans after a thrown body")
    func asyncScopeCleansAfterThrow() async throws {
        struct ProbeError: Error {}
        let capture = LifecycleCapture(forwardToStandard: true)
        let cleanupRegistry = HostedTestCleanupRegistry()
        var ownedRoot: URL?
        var suiteName: String?

        await #expect(throws: ProbeError.self) {
            try await IsolatedTestState.withState(
                label: "throw-cleanup",
                lifecycleEmitter: capture.emitter,
                cleanupRegistry: cleanupRegistry
            ) { state in
                ownedRoot = state.rootURL
                suiteName = state.suiteName
                state.defaults.set("fixture", forKey: "sentinel")
                throw ProbeError()
            }
        }

        let root = try #require(ownedRoot)
        let suite = try #require(suiteName)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(IsolatedTestState.persistentDomain(named: suite)?.isEmpty != false)
        assertBalanced(capture.records)
    }

    @Test("fixture cleanup drains multiple containers and balances token identities once")
    func fixtureCleanupIsSharedAndDatabaseLast() async throws {
        let keychainCapture = FixtureKeychainLifecycleCapture()
        let cleanupRegistry = HostedTestCleanupRegistry()
        let state = IsolatedTestState(
            label: "ordered-container-cleanup",
            keychainLifecycleEmitter: keychainCapture.emitter,
            cleanupRegistry: cleanupRegistry
        )
        let root = state.rootURL
        let suite = state.suiteName
        let first = state.makeContainer()
        let second = state.makeContainer()
        try first.pairedServerTokenStore.setToken("first-secret", forServerId: "first")
        try second.pairedServerTokenStore.setToken("second-secret", forServerId: "second")

        async let cleanupA: Void = state.cleanup()
        async let cleanupB: Void = state.cleanup()
        _ = await (cleanupA, cleanupB)
        await state.cleanup()

        let records = keychainCapture.records
        let registered = records.filter { $0.event == .registered }
        let cleaned = records.filter { $0.event == .cleaned }
        #expect(Set(registered.map { ($0.service + "|" + $0.account) })
            == Set(cleaned.map { ($0.service + "|" + $0.account) }))
        #expect(registered.count == 2)
        #expect(cleaned.count == 2)
        #expect(!keychainCapture.lines.joined().contains("first-secret"))
        #expect(!keychainCapture.lines.joined().contains("second-secret"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(IsolatedTestState.persistentDomain(named: suite)?.isEmpty != false)
    }

    private func assertBalanced(_ records: [HostedTestSuiteLifecycleRecord]) {
        let registered = records.filter { $0.event == .registered }.map(\.suite)
        let cleaned = records.filter { $0.event == .cleaned }.map(\.suite)

        #expect(registered.count == Set(registered).count)
        #expect(cleaned.count == Set(cleaned).count)
        #expect(Set(registered) == Set(cleaned))
    }
}

private final class FixtureKeychainLifecycleCapture: @unchecked Sendable {
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

private final class LifecycleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let forwardToStandard: Bool

    init(forwardToStandard: Bool) {
        self.forwardToStandard = forwardToStandard
    }

    lazy var emitter = HostedTestSuiteLifecycleEmitter { [self] line in
        guard let record = HostedTestSuiteLifecycleRecord.parse(line: line) else { return }
        lock.lock()
        lines.append(line)
        lock.unlock()
        if forwardToStandard {
            HostedTestSuiteLifecycleEmitter.standard.emit(record.event, suite: record.suite)
        }
    }

    var records: [HostedTestSuiteLifecycleRecord] {
        lock.lock()
        let snapshot = lines.compactMap { HostedTestSuiteLifecycleRecord.parse(line: $0) }
        lock.unlock()
        return snapshot
    }
}

private struct SyntheticPreferenceEnvelope {
    enum Location { case currentPreferences, wrongContainer }
    enum Node { case emptyPlist, nonemptyPlist, malformed, symlink, directory }

    let suite: String
    let location: Location
    let node: Node
}

private enum SyntheticLifecycleEnvelopeGate {
    static func accepts(
        lines: [String],
        artifacts: [SyntheticPreferenceEnvelope]
    ) -> Bool {
        var registered = Set<String>()
        var cleaned = Set<String>()
        for line in lines {
            guard let record = HostedTestSuiteLifecycleRecord.parse(line: line) else { return false }
            switch record.event {
            case .registered:
                guard registered.insert(record.suite).inserted else { return false }
            case .cleaned:
                guard cleaned.insert(record.suite).inserted else { return false }
            }
        }
        guard registered == cleaned else { return false }

        var accepted = Set<String>()
        for artifact in artifacts {
            guard artifact.location == .currentPreferences,
                  artifact.node == .emptyPlist,
                  HostedTestSuiteLifecycleRecord.isSupportedSuiteName(artifact.suite),
                  registered.contains(artifact.suite),
                  accepted.insert(artifact.suite).inserted
            else { return false }
        }
        return accepted.isSubset(of: registered) && accepted.count <= registered.count
    }
}
