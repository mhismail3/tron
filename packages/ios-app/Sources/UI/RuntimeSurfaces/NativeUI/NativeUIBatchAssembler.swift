import Foundation

struct NativeUIBatchAssembler: Sendable {
    enum Result: Equatable, Sendable {
        case ignored
        case staged
        case committed(NativeUISurfaceTree)
        case deleted
        case reconstructionRequired(String)
    }

    private struct StagedBatch: Sendable {
        let count: Int
        let envelope: StreamEnvelope
        let startedAt: ContinuousClock.Instant
        var nextIndex: Int
        var tree: NativeUISurfaceTree
    }

    private struct StreamEnvelope: Equatable, Sendable {
        let definitionId: String
        let definitionRevision: UInt64
        let catalogId: String
        let catalogRevision: UInt64
        let lifecycle: String

        init(snapshot: NativeUISurfaceSnapshotDTO) {
            definitionId = snapshot.definitionId
            definitionRevision = snapshot.definitionRevision
            catalogId = snapshot.catalogId
            catalogRevision = snapshot.catalogRevision
            lifecycle = snapshot.lifecycle
        }

        init?(record: NativeUISurfaceStreamRecordDTO) {
            guard let definitionId = record.definitionId,
                  let definitionRevision = record.definitionRevision,
                  let catalogId = record.catalogId,
                  let catalogRevision = record.catalogRevision,
                  let lifecycle = record.lifecycle
            else { return nil }
            self.definitionId = definitionId
            self.definitionRevision = definitionRevision
            self.catalogId = catalogId
            self.catalogRevision = catalogRevision
            self.lifecycle = lifecycle
        }
    }

    let surfaceId: String
    private(set) var visibleTree: NativeUISurfaceTree?
    private var staged: [String: StagedBatch] = [:]
    private var lastCursor: EngineStreamCursor?
    private var lastSurfaceSequence: UInt64?
    private var snapshotSequenceBarrier: UInt64 = 0
    private var visibleEnvelope: StreamEnvelope?
    private let clock = ContinuousClock()

    init(surfaceId: String) {
        self.surfaceId = surfaceId
    }

    mutating func install(snapshot: NativeUISurfaceSnapshotDTO) throws -> NativeUISurfaceTree {
        guard snapshot.surfaceId == surfaceId,
              !snapshot.definitionId.isEmpty,
              snapshot.catalogId == NativeUICatalog.id,
              snapshot.catalogRevision == NativeUICatalog.revision,
              ["persistent", "transient"].contains(snapshot.lifecycle)
        else { throw NativeUIRuntimeError.batchRejected("snapshot envelope is incompatible") }
        let bytes = try JSONEncoder().encode(snapshot).count
        let tree = try NativeUIValidator.buildValidatedTree(
            messages: snapshot.messages,
            encodedByteCount: bytes
        )
        visibleTree = tree
        visibleEnvelope = StreamEnvelope(snapshot: snapshot)
        snapshotSequenceBarrier = snapshot.surfaceSequence
        lastSurfaceSequence = snapshot.surfaceSequence
        staged.removeAll()
        return tree
    }

    mutating func ingest(
        _ record: NativeUISurfaceStreamRecordDTO,
        cursor: EngineStreamCursor
    ) -> Result {
        if let lastCursor {
            if cursor <= lastCursor { return .ignored }
            if cursor.rawValue != lastCursor.rawValue + 1 {
                self.lastCursor = cursor
                staged.removeAll()
                return .reconstructionRequired("cursor_gap")
            }
        }
        lastCursor = cursor
        guard record.surfaceId == surfaceId else { return .ignored }
        guard record.sequence > 0 else {
            staged.removeAll()
            return .reconstructionRequired("invalid_surface_sequence")
        }
        if record.sequence <= snapshotSequenceBarrier { return .ignored }
        guard let envelope = StreamEnvelope(record: record),
              envelope.catalogId == NativeUICatalog.id,
              envelope.catalogRevision == NativeUICatalog.revision,
              ["persistent", "transient"].contains(envelope.lifecycle),
              visibleEnvelope.map({
                  $0.definitionId == envelope.definitionId
                      && $0.lifecycle == envelope.lifecycle
              }) ?? true
        else {
            staged.removeAll()
            return .reconstructionRequired("incompatible_stream_envelope")
        }
        if let lastSurfaceSequence {
            let (expected, overflow) = lastSurfaceSequence.addingReportingOverflow(1)
            guard !overflow, record.sequence == expected else {
                staged.removeAll()
                return .reconstructionRequired("surface_sequence_gap")
            }
        }
        lastSurfaceSequence = record.sequence
        guard record.batchCount > 0,
              record.batchCount <= NativeUICatalog.maxMessagesPerBatch,
              record.batchIndex >= 0,
              record.batchIndex < record.batchCount
        else {
            staged.removeValue(forKey: record.batchId)
            return .reconstructionRequired("invalid_batch_envelope")
        }
        if staged[record.batchId] == nil {
            guard record.batchIndex == 0, staged.count < NativeUICatalog.maxStagedBatches else {
                staged.removeAll()
                return .reconstructionRequired("batch_capacity_or_order")
            }
            staged[record.batchId] = StagedBatch(
                count: record.batchCount,
                envelope: envelope,
                startedAt: clock.now,
                nextIndex: 0,
                tree: visibleTree ?? NativeUISurfaceTree()
            )
        }
        guard var batch = staged[record.batchId],
              batch.count == record.batchCount,
              batch.envelope == envelope,
              batch.nextIndex == record.batchIndex
        else {
            staged.removeValue(forKey: record.batchId)
            return .reconstructionRequired("out_of_order_batch")
        }
        do {
            try batch.tree.apply(record.message)
        } catch {
            staged.removeValue(forKey: record.batchId)
            return .reconstructionRequired("invalid_batch_message")
        }
        batch.nextIndex += 1
        staged[record.batchId] = batch

        let shouldCommit = record.isFinal && batch.nextIndex == batch.count
        if record.isFinal != (record.batchIndex + 1 == record.batchCount) {
            staged.removeValue(forKey: record.batchId)
            return .reconstructionRequired("invalid_commit_marker")
        }
        guard shouldCommit else { return .staged }
        staged.removeValue(forKey: record.batchId)
        let diagnostics = NativeUIValidator.validate(batch.tree)
        guard diagnostics.isEmpty else {
            return .reconstructionRequired("candidate_validation_failed")
        }
        if batch.tree.isDeleted {
            visibleTree = nil
            visibleEnvelope = envelope
            return .deleted
        }
        visibleTree = batch.tree
        visibleEnvelope = envelope
        return .committed(batch.tree)
    }

    mutating func expirePendingBatches(olderThan duration: Duration = .seconds(10)) -> Bool {
        let now = clock.now
        let expired = staged.filter { now - $0.value.startedAt >= duration }.map(\.key)
        for id in expired { staged.removeValue(forKey: id) }
        return !expired.isEmpty
    }

    mutating func resetStreamState() {
        staged.removeAll()
        lastCursor = nil
        lastSurfaceSequence = nil
    }
}
