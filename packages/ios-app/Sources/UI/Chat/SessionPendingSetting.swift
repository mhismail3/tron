import Foundation
import TronMobileCore

/// Deferred Thinking edits keep the same session/model/runtime and supported
/// choices. Progress revisions and acknowledgement of our pending value do not
/// create a new editor; the caller also compares the current displayed choice.
struct SessionThinkingEditScope: Hashable {
    let sessionID: String
    let runtimeGeneration: String
    let model: ModelRef?
    let levels: [String]

    init(_ snapshot: SessionContextPresentation) {
        sessionID = snapshot.sessionID
        runtimeGeneration = snapshot.runtimeGeneration
        model = snapshot.model
        levels = snapshot.availableThinkingLevels
    }

    func admits(_ level: String, in current: SessionContextPresentation) -> Bool {
        self == Self(current) && current.configurationLockedReason == nil && levels.contains(level)
    }
}

struct SessionPendingModelSelection: Equatable {
    let id = UUID()
    let value: ModelRef
    let sessionID: String
    let runtimeGeneration: String
    private var confirmedRevision: Int?

    init(_ value: ModelRef, snapshot: SessionContextPresentation) {
        self.value = value
        sessionID = snapshot.sessionID
        runtimeGeneration = snapshot.runtimeGeneration
    }

    func admitted(in snapshot: SessionContextPresentation) -> Self? {
        guard sessionID == snapshot.sessionID,
              runtimeGeneration == snapshot.runtimeGeneration else { return nil }
        return self
    }

    func confirming(_ requestID: UUID, revision: Int) -> Self {
        guard id == requestID else { return self }
        var copy = self
        copy.confirmedRevision = revision
        return copy
    }

    func rejecting(_ requestID: UUID) -> Self? {
        id == requestID ? nil : self
    }

    func reconciled(authoritative: ModelRef?, runtimeGeneration: String?, revision: Int? = nil) -> Self? {
        guard runtimeGeneration == self.runtimeGeneration else { return nil }
        guard let confirmedRevision else { return self }
        // A later client may have superseded the successful command. Its exact
        // receipt revision, not perpetual value equality, retires our intent.
        return value == authoritative || (revision.map { $0 >= confirmedRevision } ?? false) ? nil : self
    }
}

/// A single in-flight UI choice, never a canonical setting. Keep reset-to-nil
/// distinct from no pending choice, and fence both display and late failures
/// to the exact request and model/runtime that admitted it.
struct SessionPendingSetting<Value: Equatable>: Equatable {
    let id = UUID()
    let value: Value
    private let model: ModelRef?
    private let sessionID: String
    private let runtimeGeneration: String
    private var confirmedRevision: Int?

    init(_ value: Value, snapshot: SessionContextPresentation) {
        self.value = value
        model = snapshot.model
        sessionID = snapshot.sessionID
        runtimeGeneration = snapshot.runtimeGeneration
    }

    func admitted(in snapshot: SessionContextPresentation) -> Self? {
        sessionID == snapshot.sessionID && model == snapshot.model
            && runtimeGeneration == snapshot.runtimeGeneration ? self : nil
    }

    func confirming(_ requestID: UUID, revision: Int) -> Self {
        guard id == requestID else { return self }
        var result = self
        result.confirmedRevision = revision
        return result
    }

    func rejecting(_ requestID: UUID) -> Self? {
        id == requestID ? nil : self
    }

    func reconciled(authoritative: Value, snapshot: SessionContextPresentation?, revision: Int? = nil) -> Self? {
        guard let snapshot, let pending = admitted(in: snapshot) else { return nil }
        guard let confirmedRevision else { return pending }
        // Receipt and projection may arrive in either order. Wait for our value
        // or authority at/after the applied revision, including supersession.
        return value == authoritative || (revision.map { $0 >= confirmedRevision } ?? false) ? nil : pending
    }
}
