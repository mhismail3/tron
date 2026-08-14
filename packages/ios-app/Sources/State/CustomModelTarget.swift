enum CustomModelTarget: Hashable, Sendable {
    case global
}

struct CustomModelDraftOwner: Equatable, Sendable {
    private(set) var isDirty = false

    mutating func markEdited() {
        isDirty = true
    }

    mutating func markInstalled() {
        isDirty = false
    }

    var admitsPublication: Bool { !isDirty }
}

struct CustomModelLoadID: Hashable {
    let target: CustomModelTarget
    let invalidationGeneration: Int
}
