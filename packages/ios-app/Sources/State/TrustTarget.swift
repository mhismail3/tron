struct TrustTarget: Hashable, Sendable {
    let cwd: String

    init?(cwd: String) {
        guard !cwd.isEmpty else { return nil }
        self.cwd = cwd
    }
}

struct TrustLoadOwner: Equatable, Sendable {
    private(set) var target: TrustTarget?
    private(set) var isReady = false

    mutating func begin(target: TrustTarget) {
        self.target = target
        isReady = false
    }

    @discardableResult
    mutating func admit(target: TrustTarget) -> Bool {
        guard self.target == target else { return false }
        isReady = true
        return true
    }

    func isReady(for target: TrustTarget) -> Bool {
        self.target == target && isReady
    }
}

struct TrustLoadID: Hashable {
    let target: TrustTarget?
    let invalidationGeneration: Int
}
