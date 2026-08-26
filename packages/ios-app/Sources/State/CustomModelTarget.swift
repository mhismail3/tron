enum CustomModelTarget: Hashable, Sendable {
    case global
}

struct CustomModelDraftOwner: Equatable, Sendable {
    private(set) var revision = 0
    private var installedRevision = 0

    var isDirty: Bool { revision != installedRevision }
    var admitsPublication: Bool { !isDirty }

    mutating func markEdited() {
        revision &+= 1
    }

    /// Advances ownership only for a real user-visible value change. Editors
    /// call this from their Binding setter so Save state changes in the same
    /// transaction as the field, rather than waiting for SwiftUI `onChange`.
    @discardableResult
    mutating func markEdited<Value: Equatable>(from current: Value, to next: Value) -> Bool {
        guard current != next else { return false }
        markEdited()
        return true
    }

    mutating func markInstalled() {
        installedRevision = revision
    }

    func beginSave() -> Int {
        revision
    }

    @discardableResult
    mutating func completeSave(revision submittedRevision: Int) -> Bool {
        guard revision == submittedRevision else { return false }
        installedRevision = submittedRevision
        return true
    }
}

struct CustomModelLoadID: Hashable {
    let target: CustomModelTarget
    let invalidationGeneration: Int
}
