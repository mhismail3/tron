import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Transactional gateway profile persistence")
struct GatewayProfileStoreTests {
    @Test("token replacement failure preserves prior metadata and credential")
    func tokenFailurePreservesPriorState() throws {
        let old = profile(label: "Old")
        let replacement = profile(label: "New")
        let metadata = RecordingProfileMetadata(document: .init(profiles: [old], selectedProfileID: old.id))
        let tokens = RecordingTokenStore(values: [old.id: "old-token"])
        tokens.failNextSave = true
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)

        #expect(throws: ProfileStorageProbeError.self) {
            try store.save(replacement, token: "new-token")
        }
        #expect(metadata.document == GatewayProfileDocument(profiles: [old], selectedProfileID: old.id))
        #expect(tokens.values[old.id] == "old-token")
        #expect(store.profiles == [old])
    }

    @Test("metadata failure rolls an updated credential back exactly")
    func metadataFailureRollsBackToken() throws {
        let old = profile(label: "Old")
        let replacement = profile(label: "New")
        let metadata = RecordingProfileMetadata(document: .init(profiles: [old], selectedProfileID: old.id))
        metadata.failSaveCalls = [1]
        let tokens = RecordingTokenStore(values: [old.id: "old-token"])
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)

        #expect(throws: ProfileStorageProbeError.self) {
            try store.save(replacement, token: "new-token")
        }
        #expect(metadata.document == GatewayProfileDocument(profiles: [old], selectedProfileID: old.id))
        #expect(tokens.values[old.id] == "old-token")
    }

    @Test("metadata failure removes a newly-created credential")
    func metadataFailureRemovesNewToken() throws {
        let new = profile(id: "new", label: "New")
        let metadata = RecordingProfileMetadata(document: .init(profiles: [], selectedProfileID: nil))
        metadata.failSaveCalls = [1]
        let tokens = RecordingTokenStore()
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)

        #expect(throws: ProfileStorageProbeError.self) {
            try store.save(new, token: "new-token")
        }
        #expect(tokens.values[new.id] == nil)
        #expect(store.profiles.isEmpty)
    }

    @Test("invalid persisted endpoints self-clean and cannot be saved")
    func invalidEndpointAdmission() {
        let invalid = GatewayProfile(
            id: "invalid", label: "Invalid", host: "bad/path", port: 70_000,
            machineId: "invalid", deviceId: nil
        )
        let metadata = RecordingProfileMetadata(document: .init(
            profiles: [invalid],
            selectedProfileID: invalid.id
        ))
        let tokens = RecordingTokenStore()
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)

        #expect(store.profiles.isEmpty)
        #expect(metadata.document == GatewayProfileDocument(profiles: [], selectedProfileID: nil))
        #expect(throws: GatewayProfileStoreError.self) {
            try store.save(invalid, token: "token")
        }
        #expect(tokens.values.isEmpty)
    }

    @Test("successful replacement commits one selected document and token")
    func successfulReplacement() throws {
        let first = profile(id: "first", label: "First")
        let second = profile(id: "second", label: "Second")
        let metadata = RecordingProfileMetadata(document: .init(profiles: [first], selectedProfileID: first.id))
        let tokens = RecordingTokenStore(values: [first.id: "first-token"])
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)

        try store.save(second, token: "second-token")
        #expect(store.profiles == [first, second])
        #expect(store.selected == second)
        #expect(store.token(for: second) == "second-token")
        #expect(metadata.saveCount == 1)
    }

    @Test("selection persistence failure preserves the prior selected profile")
    func selectionFailurePreservesPriorProfile() throws {
        let first = profile(id: "first", label: "First")
        let second = profile(id: "second", label: "Second")
        let original = GatewayProfileDocument(profiles: [first, second], selectedProfileID: first.id)
        let metadata = RecordingProfileMetadata(document: original)
        metadata.failSaveCalls = [1]
        let store = GatewayProfileStore(metadata: metadata, tokens: RecordingTokenStore())

        #expect(throws: ProfileStorageProbeError.self) { try store.select(second) }
        #expect(metadata.document == original)
        #expect(store.selected == first)
    }

    @Test("failed selection persistence blocks replacement cache and connection admission")
    func failedSelectionBlocksLifecycleAdmission() async {
        let first = profile(id: "first", label: "First")
        let second = profile(id: "second", label: "Second")
        let original = GatewayProfileDocument(profiles: [first, second], selectedProfileID: first.id)
        let metadata = RecordingProfileMetadata(document: original)
        metadata.failSaveCalls = [1]
        let store = GatewayProfileStore(
            metadata: metadata,
            tokens: RecordingTokenStore(values: [first.id: "first-token", second.id: "second-token"])
        )
        let socket = ScriptedGatewaySocket()
        let socketFactory = ScriptedGatewaySocketFactory(socket: socket)
        let coordinator = GatewayLifecycleCoordinator(
            client: GatewayClient(socketFactory: socketFactory.factory),
            profiles: store,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { profile in
                profile.id == second.id ? "second-token" : "first-token"
            }
        )
        let delegate = ProfileSelectionLifecycleProbe()
        coordinator.delegate = delegate

        await coordinator.switchGateway(second)

        #expect(store.selected == first)
        #expect(delegate.loadedProfileIDs.isEmpty)
        #expect(delegate.surfaceCount == 1)
        #expect(socketFactory.requests.isEmpty)
        if case .offline = coordinator.connectionState {} else {
            Issue.record("failed selection persistence did not leave an offline lifecycle")
        }
        await coordinator.teardown()
    }

    @Test("credential deletion failure restores removed profile metadata")
    func removalRollback() throws {
        let first = profile(id: "first", label: "First")
        let second = profile(id: "second", label: "Second")
        let original = GatewayProfileDocument(profiles: [first, second], selectedProfileID: first.id)
        let metadata = RecordingProfileMetadata(document: original)
        let tokens = RecordingTokenStore(values: [first.id: "token", second.id: "other"])
        tokens.failNextDelete = true
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)

        #expect(throws: ProfileStorageProbeError.self) { try store.remove(first) }
        #expect(metadata.document == original)
        #expect(tokens.values[first.id] == "token")
        #expect(store.selected == first)
    }

    @Test("initial removal failure and rollback failure remain observable")
    func removalFailuresAreObservable() {
        let first = profile(id: "first", label: "First")
        let original = GatewayProfileDocument(profiles: [first], selectedProfileID: first.id)

        let initialMetadata = RecordingProfileMetadata(document: original)
        initialMetadata.failSaveCalls = [1]
        let initialTokens = RecordingTokenStore(values: [first.id: "token"])
        let initialStore = GatewayProfileStore(metadata: initialMetadata, tokens: initialTokens)
        #expect(throws: ProfileStorageProbeError.self) { try initialStore.remove(first) }
        #expect(initialMetadata.document == original)
        #expect(initialTokens.values[first.id] == "token")

        let rollbackMetadata = RecordingProfileMetadata(document: original)
        rollbackMetadata.failSaveCalls = [2]
        let rollbackTokens = RecordingTokenStore(values: [first.id: "token"])
        rollbackTokens.failNextDelete = true
        let rollbackStore = GatewayProfileStore(metadata: rollbackMetadata, tokens: rollbackTokens)
        #expect(throws: GatewayProfileStoreError.self) { try rollbackStore.remove(first) }
        #expect(rollbackTokens.values[first.id] == "token")
    }

    @Test("failed lifecycle removal retains profile-scoped cache")
    func lifecycleRemovalFailureRetainsLocalState() async throws {
        let first = profile(id: "first", label: "First")
        let metadata = RecordingProfileMetadata(document: .init(profiles: [first], selectedProfileID: first.id))
        metadata.failSaveCalls = [1]
        let tokens = RecordingTokenStore(values: [first.id: "token"])
        let store = GatewayProfileStore(metadata: metadata, tokens: tokens)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        let summary = SessionSummary(
            id: "session", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .idle
        )
        await cache.save(profileID: first.id, sessions: [summary], snapshots: [])
        let model = AppModel(profiles: store, cache: cache)

        await model.forgetCurrentGateway()
        #expect(store.selected == first)
        #expect((await cache.load(profileID: first.id)).sessions.map(\.id) == ["session"])
        if case .offline = model.connectionState {} else {
            Issue.record("failed profile persistence did not leave an offline recoverable lifecycle")
        }
        await model.teardown()
    }

    @Test("corrupt documents self-clean and valid legacy metadata migrates on write")
    func corruptDocumentMigration() throws {
        let suite = "GatewayProfileStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("corrupt".utf8), forKey: "gatewayProfiles.v2")
        let legacy = profile(label: "Legacy")
        defaults.set(try JSONEncoder.gateway.encode([legacy]), forKey: "gatewayProfiles.v1")
        defaults.set(legacy.id, forKey: "selectedGateway.v1")
        let metadata = UserDefaultsGatewayProfileMetadataStore(defaults: defaults)

        #expect(try metadata.load() == GatewayProfileDocument(profiles: [legacy], selectedProfileID: legacy.id))
        try metadata.save(.init(profiles: [legacy], selectedProfileID: legacy.id))
        #expect(defaults.data(forKey: "gatewayProfiles.v2") != nil)
        #expect(defaults.data(forKey: "gatewayProfiles.v1") == nil)
        #expect(defaults.string(forKey: "selectedGateway.v1") == nil)
    }

    private func profile(id: String = "machine", label: String) -> GatewayProfile {
        GatewayProfile(
            id: id,
            label: label,
            host: "gateway.test",
            port: 9_847,
            machineId: id,
            deviceId: "device-\(id)"
        )
    }
}

@MainActor
private final class ProfileSelectionLifecycleProbe: GatewayLifecycleProjectionDelegate {
    private(set) var loadedProfileIDs: [String] = []
    private(set) var surfaceCount = 0

    func lifecycleLoadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        loadedProfileIDs.append(profileID)
    }

    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) { surfaceCount += 1 }
}

private enum ProfileStorageProbeError: Error { case failed }

private final class RecordingProfileMetadata: GatewayProfileMetadataStoring {
    var document: GatewayProfileDocument?
    var failSaveCalls: Set<Int> = []
    private(set) var saveCount = 0

    init(document: GatewayProfileDocument?) { self.document = document }

    func load() throws -> GatewayProfileDocument? { document }

    func save(_ document: GatewayProfileDocument) throws {
        saveCount += 1
        if failSaveCalls.contains(saveCount) {
            throw ProfileStorageProbeError.failed
        }
        self.document = document
    }
}

private final class RecordingTokenStore: GatewayTokenStoring {
    var values: [String: String]
    var failNextSave = false
    var failNextDelete = false

    init(values: [String: String] = [:]) { self.values = values }

    func save(_ token: String, profileID: String) throws {
        if failNextSave {
            failNextSave = false
            throw ProfileStorageProbeError.failed
        }
        values[profileID] = token
    }

    func read(profileID: String) throws -> String? { values[profileID] }

    func delete(profileID: String) throws {
        if failNextDelete {
            failNextDelete = false
            throw ProfileStorageProbeError.failed
        }
        values[profileID] = nil
    }
}
