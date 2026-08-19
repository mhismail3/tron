struct NewSessionConfigurationLoadID: Hashable {
    let profileID: String?
    let workspace: String
    let trustInvalidationGeneration: Int
    let profileRevision: Int

    init(
        profileID: String?,
        workspace: String,
        trustInvalidationGeneration: Int,
        profileRevision: Int = 0
    ) {
        self.profileID = profileID
        self.workspace = workspace
        self.trustInvalidationGeneration = trustInvalidationGeneration
        self.profileRevision = profileRevision
    }
}

struct NewSessionConfigurationOwner: Equatable, Sendable {
    private(set) var profileID: String?
    private(set) var workspace: String?
    private(set) var isReady = false

    mutating func begin(profileID: String?, workspace: String) {
        self.profileID = profileID
        self.workspace = workspace
        isReady = false
    }

    @discardableResult
    mutating func admit(
        profileID: String?,
        workspace: String,
        settingsReady: Bool,
        trustReady: Bool
    ) -> Bool {
        guard self.profileID == profileID, self.workspace == workspace else { return false }
        isReady = settingsReady && trustReady
        return isReady
    }

    func permitsCreation(profileID: String?, workspace: String, requiresTrust: Bool) -> Bool {
        !workspace.isEmpty
            && profileID != nil
            && self.profileID == profileID
            && self.workspace == workspace
            && isReady
            && !requiresTrust
    }

    func isLoading(profileID: String?, workspace: String) -> Bool {
        !workspace.isEmpty
            && (self.profileID != profileID || self.workspace != workspace || !isReady)
    }
}

struct NewSessionCreationOwner: Equatable, Sendable {
    private(set) var isCreating = false

    mutating func begin(configurationReady: Bool) -> Bool {
        guard configurationReady, !isCreating else { return false }
        isCreating = true
        return true
    }

    mutating func finish() {
        isCreating = false
    }

    func modelOverride(selected: ModelRef?, configured: ModelRef?) -> ModelRef? {
        selected == configured ? nil : selected
    }
}
