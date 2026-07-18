import Foundation

@Observable
@MainActor
final class NativeUISurfaceController {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case fallback(String)
        case failed(String)
        case deleted
    }

    private(set) var status: Status = .idle
    private(set) var snapshot: NativeUISurfaceSnapshotDTO?
    private(set) var tree: NativeUISurfaceTree?
    private(set) var diagnostics: [NativeUIDiagnosticDTO] = []
    private(set) var activeActionIds: Set<String> = []
    private(set) var actionErrors: [String: String] = [:]

    let request: NativeUISurfaceRequest
    let bridge: NativeUIClientBridge

    @ObservationIgnored private let repository: any NativeUIRepository
    @ObservationIgnored private var assembler: NativeUIBatchAssembler
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var isReconstructing = false
    @ObservationIgnored private var streamMutationGeneration: UInt64 = 0
    @ObservationIgnored private let cache: NativeUISnapshotCache

    init(
        repository: any NativeUIRepository,
        request: NativeUISurfaceRequest,
        cacheNamespace: String,
        bridge: NativeUIClientBridge = NativeUIClientBridge()
    ) {
        self.repository = repository
        self.request = request
        self.bridge = bridge
        assembler = NativeUIBatchAssembler(surfaceId: request.surfaceId ?? request.definitionId)
        cache = NativeUISnapshotCache(namespace: cacheNamespace)
    }

    deinit {
        streamTask?.cancel()
        expiryTask?.cancel()
    }

    func start() async {
        guard status == .idle else { return }
        status = .loading
        installLocalFallback()
        startStreamConsumer()
        do {
            let clientId = request.clientId ?? NativeUIClientIdentity.persistent()
            try await repository.prepareClient(NativeUIClientBridge.catalog(clientId: clientId))
            var serverRequest = request
            serverRequest.clientId = clientId
            let generation = streamMutationGeneration
            let serverSnapshot = try await repository.getSurface(serverRequest)
            if generation == streamMutationGeneration {
                try install(serverSnapshot, status: .ready, persist: true)
            } else {
                await reconstruct(reason: "initial_snapshot_raced_live_update")
            }
        } catch {
            if tree != nil {
                status = .fallback(error.localizedDescription)
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func reconstruct(reason: String) async {
        guard !isReconstructing else { return }
        isReconstructing = true
        defer { isReconstructing = false }
        do {
            var serverRequest = request
            serverRequest.clientId = request.clientId ?? NativeUIClientIdentity.persistent()
            for _ in 0 ..< 3 {
                let generation = streamMutationGeneration
                let rebuilt = try await repository.reconstructSurface(serverRequest)
                guard generation == streamMutationGeneration else { continue }
                assembler.resetStreamState()
                try install(rebuilt, status: .ready, persist: true)
                return
            }
            throw NativeUIRuntimeError.batchRejected(
                "live updates repeatedly crossed the reconstruction snapshot"
            )
        } catch {
            status = tree == nil
                ? .failed("\(reason): \(error.localizedDescription)")
                : .fallback("\(reason): \(error.localizedDescription)")
        }
    }

    func resolved(_ value: NativeUIJSONValue?) -> NativeUIJSONValue? {
        tree?.resolved(value)
    }

    func updateBoundValue(for component: NativeUIComponentDTO, to value: NativeUIJSONValue) {
        guard let binding = component.properties["value"]?.objectValue,
              let path = binding["path"]?.stringValue,
              var tree
        else { return }
        do {
            try tree.setData(value, at: path)
            self.tree = tree
        } catch {
            actionErrors[component.id] = error.localizedDescription
        }
    }

    func performAction(
        for component: NativeUIComponentDTO,
        event: [String: NativeUIJSONValue] = [:]
    ) async {
        guard let action = component.properties["action"] else { return }
        activeActionIds.insert(component.id)
        actionErrors[component.id] = nil
        defer { activeActionIds.remove(component.id) }
        do {
            _ = try await execute(action, event: event, priorResult: nil)
        } catch {
            actionErrors[component.id] = error.localizedDescription
            if actionContainsServerCapability(action) {
                await reconstruct(reason: "action_rejected")
            }
        }
    }

    func dismiss() async {
        guard snapshot?.lifecycle == "transient" else {
            await bridge.dismiss?()
            return
        }
        cache.remove(surfaceId: assembler.surfaceId)
        do {
            try await repository.dismiss(surfaceId: assembler.surfaceId, sessionId: snapshot?.sessionId)
        } catch {
            // Local tombstone wins until the next explicit server projection.
            cache.recordDismissal(surfaceId: assembler.surfaceId)
        }
        await bridge.dismiss?()
    }

    private func execute(
        _ action: NativeUIJSONValue,
        event: [String: NativeUIJSONValue],
        priorResult: NativeUIJSONValue?
    ) async throws -> NativeUIJSONValue {
        guard case .object(let object) = action else {
            throw NativeUIRuntimeError.invalidMessage("action is not an object")
        }
        let result: NativeUIJSONValue
        if let function = object["clientFunction"]?.objectValue,
           let name = function["name"]?.stringValue,
           let arguments = function["arguments"]?.objectValue {
            let resolved = resolveObject(arguments, event: event, result: priorResult)
            result = try await bridge.execute(name: name, arguments: resolved)
        } else if let binding = object["serverCapability"]?.objectValue,
                  let functionId = binding["functionId"]?.stringValue,
                  let template = binding["argumentTemplate"]?.objectValue {
            let arguments = resolveObject(template, event: event, result: priorResult)
            result = try await repository.dispatchAction(
                definitionId: snapshot?.definitionId ?? request.definitionId,
                surfaceId: assembler.surfaceId,
                functionId: functionId,
                arguments: arguments,
                idempotencyKey: "ios:native-ui:\(UUID().uuidString)",
                sessionId: snapshot?.sessionId
            )
        } else if object["event"] != nil {
            result = .object(event)
        } else {
            throw NativeUIRuntimeError.invalidMessage("action has no executable variant")
        }
        if let next = object["resultAction"] {
            return try await execute(next, event: event, priorResult: result)
        }
        return result
    }

    private func resolveObject(
        _ object: [String: NativeUIJSONValue],
        event: [String: NativeUIJSONValue],
        result: NativeUIJSONValue?
    ) -> [String: NativeUIJSONValue] {
        object.mapValues { resolveTemplate($0, event: event, result: result) }
    }

    private func resolveTemplate(
        _ value: NativeUIJSONValue,
        event: [String: NativeUIJSONValue],
        result: NativeUIJSONValue?
    ) -> NativeUIJSONValue {
        if case .object(let object) = value, object.count == 1 {
            if let path = object["path"]?.stringValue { return tree?.value(at: path) ?? .null }
            if let key = object["$event"]?.stringValue { return event[key] ?? .null }
            if let key = object["$result"]?.stringValue {
                return result?.objectValue?[key] ?? .null
            }
        }
        switch value {
        case .object(let object):
            return .object(resolveObject(object, event: event, result: result))
        case .array(let array):
            return .array(array.map { resolveTemplate($0, event: event, result: result) })
        default: return value
        }
    }

    private func actionContainsServerCapability(_ action: NativeUIJSONValue) -> Bool {
        guard case .object(let object) = action else { return false }
        return object["serverCapability"] != nil
            || object["resultAction"].map(actionContainsServerCapability) == true
    }

    private func install(
        _ snapshot: NativeUISurfaceSnapshotDTO,
        status: Status,
        persist: Bool
    ) throws {
        let tree = try assembler.install(snapshot: snapshot)
        self.snapshot = snapshot
        self.tree = tree
        diagnostics = snapshot.diagnostics
        self.status = status
        if persist { cache.save(snapshot) }
    }

    private func installLocalFallback() {
        if !cache.isDismissed(surfaceId: assembler.surfaceId),
           let cached = cache.load(surfaceId: assembler.surfaceId),
           (try? install(cached, status: .fallback("cached"), persist: false)) != nil {
            return
        }
        guard let definition = try? NativeUIBundledDefinitions.load(request.definitionId) else { return }
        let fallback = NativeUISurfaceSnapshotDTO(
            surfaceId: assembler.surfaceId,
            definitionId: definition.definitionId,
            definitionRevision: 0,
            surfaceSequence: 0,
            catalogId: definition.catalogId,
            catalogRevision: definition.catalogRevision,
            lifecycle: definition.lifecycle,
            source: "bundled",
            presentation: definition.presentation,
            messages: definition.messages,
            diagnostics: [],
            sessionId: request.sessionId,
            eventId: request.eventId
        )
        try? install(fallback, status: .fallback("bundled"), persist: false)
    }

    private func startStreamConsumer() {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self, repository] in
            for await delivery in repository.surfaceEvents {
                guard !Task.isCancelled, let self else { return }
                switch delivery {
                case .record(let record, let cursor):
                    switch assembler.ingest(record, cursor: cursor) {
                    case .committed(let tree):
                        streamMutationGeneration &+= 1
                        self.tree = tree
                        self.status = .ready
                        cacheCommittedTree(tree, record: record)
                        await reconstruct(reason: "stream_commit_snapshot")
                    case .deleted:
                        streamMutationGeneration &+= 1
                        self.tree = nil
                        self.snapshot = nil
                        cache.remove(surfaceId: assembler.surfaceId)
                        self.status = .deleted
                    case .reconstructionRequired(let reason):
                        await reconstruct(reason: reason)
                    case .ignored, .staged: break
                    }
                case .recoveryRequired(let reason):
                    await reconstruct(reason: reason)
                }
            }
        }
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if assembler.expirePendingBatches() {
                    await reconstruct(reason: "missing_batch_commit")
                }
            }
        }
    }

    private func cacheCommittedTree(
        _ tree: NativeUISurfaceTree,
        record: NativeUISurfaceStreamRecordDTO
    ) {
        guard let current = snapshot,
              let definitionId = record.definitionId,
              let definitionRevision = record.definitionRevision,
              let catalogId = record.catalogId,
              let catalogRevision = record.catalogRevision,
              let lifecycle = record.lifecycle,
              let messages = try? tree.canonicalMessages()
        else { return }
        let committed = NativeUISurfaceSnapshotDTO(
            surfaceId: assembler.surfaceId,
            definitionId: definitionId,
            definitionRevision: definitionRevision,
            surfaceSequence: record.sequence,
            catalogId: catalogId,
            catalogRevision: catalogRevision,
            lifecycle: lifecycle,
            source: "stream",
            presentation: current.presentation,
            messages: messages,
            diagnostics: [],
            sessionId: current.sessionId,
            eventId: current.eventId
        )
        snapshot = committed
        cache.save(committed)
    }
}

/// Bounded per-server last-known-good cache plus local dismissal tombstones.
struct NativeUISnapshotCache {
    let namespace: String
    let defaults: UserDefaults

    init(namespace: String, defaults: UserDefaults = .standard) {
        self.namespace = namespace
        self.defaults = defaults
    }

    func save(_ snapshot: NativeUISurfaceSnapshotDTO) {
        guard let data = try? JSONEncoder().encode(snapshot),
              data.count <= NativeUICatalog.maxPayloadBytes * 2
        else { return }
        defaults.set(data, forKey: snapshotKey(snapshot.surfaceId))
        defaults.removeObject(forKey: dismissalKey(snapshot.surfaceId))
        if snapshot.lifecycle == "transient" {
            var surfaceIds = defaults.stringArray(forKey: transientIndexKey) ?? []
            surfaceIds.removeAll { $0 == snapshot.surfaceId }
            surfaceIds.append(snapshot.surfaceId)
            defaults.set(Array(surfaceIds.suffix(16)), forKey: transientIndexKey)
        }
    }

    func load(surfaceId: String) -> NativeUISurfaceSnapshotDTO? {
        guard let data = defaults.data(forKey: snapshotKey(surfaceId)) else { return nil }
        return try? JSONDecoder().decode(NativeUISurfaceSnapshotDTO.self, from: data)
    }

    func remove(surfaceId: String) {
        defaults.removeObject(forKey: snapshotKey(surfaceId))
        var surfaceIds = defaults.stringArray(forKey: transientIndexKey) ?? []
        surfaceIds.removeAll { $0 == surfaceId }
        defaults.set(surfaceIds, forKey: transientIndexKey)
        recordDismissal(surfaceId: surfaceId)
    }

    func latestActiveTransient(sessionId: String, definitionId: String) -> NativeUISurfaceSnapshotDTO? {
        let surfaceIds = defaults.stringArray(forKey: transientIndexKey) ?? []
        return surfaceIds.reversed().lazy
            .filter { !isDismissed(surfaceId: $0) }
            .compactMap { load(surfaceId: $0) }
            .first {
                $0.lifecycle == "transient"
                    && $0.sessionId == sessionId
                    && $0.definitionId == definitionId
            }
    }

    func recordDismissal(surfaceId: String) {
        defaults.set(true, forKey: dismissalKey(surfaceId))
    }

    func isDismissed(surfaceId: String) -> Bool {
        defaults.bool(forKey: dismissalKey(surfaceId))
    }

    private func snapshotKey(_ surfaceId: String) -> String {
        "nativeUI.snapshot.\(namespace).\(surfaceId)"
    }

    private func dismissalKey(_ surfaceId: String) -> String {
        "nativeUI.dismissed.\(namespace).\(surfaceId)"
    }

    private var transientIndexKey: String {
        "nativeUI.transient-index.\(namespace)"
    }
}

enum NativeUITransientRestoration {
    static func latestCompactionEventId(cacheNamespace: String, sessionId: String) -> String? {
        NativeUISnapshotCache(namespace: cacheNamespace)
            .latestActiveTransient(
                sessionId: sessionId,
                definitionId: "session.compaction_detail"
            )?
            .eventId
    }
}
