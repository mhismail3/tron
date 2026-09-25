import Foundation

/// Read publications must match the exact owner identity and latest request;
/// accepted mutations use a different owner and are not admitted by this gate.
enum IntegrationPresentationAdmission {
    static func admits(
        presentationActive: Bool,
        currentIdentity: KnowledgePresentationIdentity,
        requestedIdentity: KnowledgePresentationIdentity,
        currentRequest: Int,
        requestedRequest: Int
    ) -> Bool {
        presentationActive && currentIdentity == requestedIdentity && currentRequest == requestedRequest
    }
}

struct IntegrationDefinition: Codable, Hashable, Sendable, Identifiable {
    let schemaVersion: Int
    let id: String
    let implementation: String
    let displayName: String
    let setupMethods: [String]
    let capabilities: [IntegrationCapabilityDefinition]
}

struct IntegrationCapabilityDefinition: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let effects: [String]
    let supported: Bool
}

struct IntegrationPolicy: Codable, Hashable, Sendable {
    var enabled: Bool
    var allowWrites: Bool
    var paidAccessApproved: Bool
    var paidBudgetCents: Int
    var recurringApproved: Bool
}

struct IntegrationInstance: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let definitionId: String
    let implementation: String
    let providerAccountId: String
    let scope: String?
    let credentialConfigured: Bool
    let credentialAvailability: String?
    let providerIdentity: String?
    let providerDisplayName: String?
    var policy: IntegrationPolicy
    let health: String
    let createdAt: String
    let updatedAt: String
    let setupRevision: Int
    let lastError: String?

    /// Provider metadata is a verified display projection; the canonical ID
    /// remains the technical identity and is the honest fallback.
    var displayTitle: String {
        if let providerDisplayName, !providerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return providerDisplayName
        }
        return implementation == "mcp" ? providerAccountId : "Account \(providerAccountId)"
    }
}

struct IntegrationCapabilityStatus: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let availability: String
    let effects: [String]
    let definitionId: String
    let connectionId: String?
    let provenance: IntegrationCapabilityProvenance
    let detail: String?
    var instanceCapabilityID: String { "\(connectionId ?? definitionId):\(id)" }
}

struct IntegrationCapabilityProvenance: Codable, Hashable, Sendable {
    let owner: String
    let definitionId: String
    let connectionId: String?
}

struct IntegrationSetupOperation: Codable, Hashable, Sendable, Identifiable {
    let operationId: String
    let instanceId: String
    let definitionId: String
    let method: String
    let status: String
    let createdAt: String
    let updatedAt: String
    var id: String { operationId }
}

struct IntegrationSnapshot: Codable, Hashable, Sendable {
    let definitions: [IntegrationDefinition]
    let instances: [IntegrationInstance]
    let setupOperations: [IntegrationSetupOperation]
    let capabilities: [IntegrationCapabilityStatus]
    let stateRevision: Int
}

struct IntegrationSetupStarted: Codable, Hashable, Sendable {
    let operationId: String
    let instanceId: String
    let definitionId: String?
    let method: String?
    let status: String
}

struct IntegrationSetupCompleted: Codable, Hashable, Sendable {
    let id: String
    let definitionId: String
    let implementation: String
    let providerAccountId: String
    let scope: String?
    let policy: IntegrationPolicy
    let health: String
    let createdAt: String
    let updatedAt: String
    let setupRevision: Int
    let lastError: String?
}

struct IntegrationSetupConfiguration: Codable, Hashable, Sendable {
    let transport: String
    let endpoint: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let env: [String: String]?
}
