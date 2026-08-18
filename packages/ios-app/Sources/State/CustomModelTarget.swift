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
