struct NewSessionConfigurationLoadID: Hashable {
    let workspace: String
    let trustInvalidationGeneration: Int
}

struct NewSessionConfigurationOwner: Equatable, Sendable {
    private(set) var workspace: String?
    private(set) var isReady = false

    mutating func begin(workspace: String) {
        self.workspace = workspace
        isReady = false
    }

    @discardableResult
    mutating func admit(workspace: String, settingsReady: Bool, trustReady: Bool) -> Bool {
        guard self.workspace == workspace else { return false }
        isReady = settingsReady && trustReady
        return isReady
    }

    func permitsCreation(workspace: String, requiresTrust: Bool) -> Bool {
        !workspace.isEmpty && self.workspace == workspace && isReady && !requiresTrust
    }
}
