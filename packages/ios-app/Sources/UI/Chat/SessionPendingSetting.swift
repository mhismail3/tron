import Foundation

struct SessionPendingModelSelection: Equatable {
    let id = UUID()
    let value: ModelRef
    let sessionID: String
    let runtimeGeneration: String
    private var confirmed = false

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

    func confirming(_ requestID: UUID) -> Self {
        guard id == requestID else { return self }
        var copy = self
        copy.confirmed = true
        return copy
    }

    func rejecting(_ requestID: UUID) -> Self? {
        id == requestID ? nil : self
    }

    func reconciled(authoritative: ModelRef?, runtimeGeneration: String?) -> Self? {
        guard runtimeGeneration == self.runtimeGeneration else { return nil }
        return confirmed && value == authoritative ? nil : self
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
    private var confirmed = false

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

    func confirming(_ requestID: UUID) -> Self {
        guard id == requestID else { return self }
        var result = self
        result.confirmed = true
        return result
    }

    func rejecting(_ requestID: UUID) -> Self? {
        id == requestID ? nil : self
    }

    func reconciled(authoritative: Value, snapshot: SessionContextPresentation?) -> Self? {
        guard let snapshot, let pending = admitted(in: snapshot) else { return nil }
        // A rapid A → B → A selection can match the old snapshot before its
        // command runs. Only the exact command's completion can retire it.
        return confirmed && value == authoritative ? nil : pending
    }
}
