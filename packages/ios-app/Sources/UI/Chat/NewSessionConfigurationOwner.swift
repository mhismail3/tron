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

enum NewSessionTrustPolicy {
    static func requiresDecision(_ inspection: JSONValue?) -> Bool {
        guard let value = inspection?.objectValue else { return false }
        return value["requiresDecision"]?.boolValue == true
            && value["effectiveDecision"] == .null
    }

    /// An unresolved prompt defaults to blocking project-local resources. The
    /// explicit Trust action replaces this fallback before session creation.
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

/// The configuration scope a model choice belongs to. A choice overrides the
/// default of exactly one profile/workspace pair.
struct NewSessionModelScope: Hashable, Sendable {
    let profileID: String?
    let workspace: String
}

/// Explicit model intent for one configuration scope.
///
/// The sheet re-runs its configuration task whenever a revision input changes —
/// profile revision, trust invalidation, or presentation activity — and those
/// re-runs happen without any user action (a profile switch completing in the
/// background, or a `trust.changed` event). Re-deriving the selection on every
/// run silently replaced a model the user had just picked with the scope default.
/// Keeping the choice here means a revision-only re-run re-derives the default
/// but never discards explicit intent; only leaving the scope it was made in does.
struct NewSessionModelChoice: Equatable, Sendable {
    private(set) var model: ModelRef?
    private(set) var scope: NewSessionModelScope?

    /// Records the user's selection for the scope it was made in.
    mutating func choose(_ model: ModelRef?, scope: NewSessionModelScope) {
        self.model = model
        self.scope = scope
    }

    /// Returns the choice for this scope, dropping it when the sheet has moved to
    /// a different profile or workspace.
    mutating func retain(in scope: NewSessionModelScope) -> ModelRef? {
        guard self.scope == scope else {
            model = nil
            self.scope = nil
            return nil
        }
        return model
    }

    /// Explicit intent, else the scope default, else the provider's preferred
    /// available model.
    func effective(configured: ModelRef?, preferred: ModelRef?) -> ModelRef? {
        model ?? configured ?? preferred
    }
}
