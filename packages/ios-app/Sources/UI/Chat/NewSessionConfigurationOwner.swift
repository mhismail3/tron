import TronMobileCore
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

struct NewSessionConfigurationReadID: Hashable {
    let configuration: NewSessionConfigurationLoadID
    let transport: KnowledgePresentationIdentity
}

enum NewSessionTrustPolicy {
    static func sharedProjectRoot(_ inspection: JSONValue?) -> String? {
        guard let value = inspection?.objectValue, let root = value["projectDir"]?.stringValue,
              root != value["cwd"]?.stringValue else { return nil }
        return root
    }

    static func requiresDecision(_ inspection: JSONValue?) -> Bool {
        guard let value = inspection?.objectValue else { return false }
        return value["requiresDecision"]?.boolValue == true
            && value["effectiveDecision"] == .null
    }

    static func decisionBeforeCreation(_ inspection: JSONValue?) -> Bool? {
        requiresDecision(inspection) ? false : nil
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

    func permitsCreation(profileID: String?, workspace: String) -> Bool {
        !workspace.isEmpty
            && profileID != nil
            && self.profileID == profileID
            && self.workspace == workspace
            && isReady
    }

    func isLoading(profileID: String?, workspace: String) -> Bool {
        !workspace.isEmpty
            && (self.profileID != profileID || self.workspace != workspace || !isReady)
    }
}

struct NewSessionCreationOwner: Equatable {
    private(set) var isCreating = false
    private(set) var isRetired = false
    private(set) var pendingRoute: AppModel.SessionNavigationRoute?
    private(set) var pendingScope: NewSessionModelScope?

    mutating func begin(configurationReady: Bool) -> Bool {
        guard configurationReady, !isCreating, !isRetired, pendingRoute == nil else { return false }
        isCreating = true
        return true
    }

    mutating func finish() {
        isCreating = false
    }

    mutating func retain(route: AppModel.SessionNavigationRoute, scope: NewSessionModelScope) -> Bool {
        guard isCreating, !isRetired, pendingRoute == nil else { return false }
        pendingRoute = route
        pendingScope = scope
        return true
    }

    mutating func takeRoute(in scope: NewSessionModelScope, navigationAdmitted: Bool) -> AppModel.SessionNavigationRoute? {
        guard !isRetired, pendingScope == scope, navigationAdmitted, let route = pendingRoute else { return nil }
        pendingRoute = nil
        pendingScope = nil
        return route
    }

    mutating func discardResultOutside(_ scope: NewSessionModelScope) -> Bool {
        guard pendingRoute != nil, pendingScope != scope else { return false }
        pendingRoute = nil
        pendingScope = nil
        return true
    }

    mutating func retire() {
        isRetired = true
        pendingRoute = nil
        pendingScope = nil
    }

    func modelOverride(selected: ModelRef?, configured: ModelRef?) -> ModelRef? {
        selected == configured ? nil : selected
    }
}

struct NewSessionModelScope: Hashable, Sendable {
    let profileID: String?
    let workspace: String
    let lifecycleGeneration: Int
}

struct NewSessionModelChoice: Equatable, Sendable {
    private(set) var model: ModelRef?
    private(set) var scope: NewSessionModelScope?

    mutating func choose(_ model: ModelRef?, scope: NewSessionModelScope) {
        self.model = model
        self.scope = scope
    }

    mutating func retain(in scope: NewSessionModelScope) -> ModelRef? {
        guard self.scope == scope else {
            model = nil
            self.scope = nil
            return nil
        }
        return model
    }

    func effective(configured: ModelRef?, preferred: ModelRef?) -> ModelRef? {
        model ?? configured ?? preferred
    }
}
