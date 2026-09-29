import Foundation

/// Read publications must match the exact owner identity and latest request;
/// accepted mutations use a different owner and are not admitted by this gate.
package enum IntegrationPresentationAdmission {
    package static func admits(
        presentationActive: Bool,
        currentIdentity: KnowledgePresentationIdentity,
        requestedIdentity: KnowledgePresentationIdentity,
        currentRequest: Int,
        requestedRequest: Int
    ) -> Bool {
        presentationActive && currentIdentity == requestedIdentity && currentRequest == requestedRequest
    }
}

package struct IntegrationDefinition: Codable, Hashable, Sendable, Identifiable {
    let schemaVersion: Int
    package let id: String
    package let implementation: String
    package let displayName: String
    package let setupMethods: [String]
    package let capabilities: [IntegrationCapabilityDefinition]
}

package struct IntegrationCapabilityDefinition: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package let displayName: String
    let effects: [String]
    let supported: Bool
}

package struct IntegrationPolicy: Codable, Hashable, Sendable {
    package var enabled: Bool
    package var allowWrites: Bool
    package var paidAccessApproved: Bool
    package var paidBudgetCents: Int
    package var recurringApproved: Bool

    package init(enabled: Bool, allowWrites: Bool, paidAccessApproved: Bool, paidBudgetCents: Int, recurringApproved: Bool) {
        self.enabled = enabled
        self.allowWrites = allowWrites
        self.paidAccessApproved = paidAccessApproved
        self.paidBudgetCents = paidBudgetCents
        self.recurringApproved = recurringApproved
    }
}

package struct IntegrationInstance: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package let definitionId: String
    package let implementation: String
    package let providerAccountId: String
    package let scope: String?
    package let credentialConfigured: Bool
    package let credentialAvailability: String?
    package let providerIdentity: String?
    let providerDisplayName: String?
    package var policy: IntegrationPolicy
    package let health: String
    let createdAt: String
    let updatedAt: String
    package let setupRevision: Int
    package let lastError: String?

    /// Provider metadata is a verified display projection; the canonical ID
    /// remains the technical identity and is the honest fallback.
    package var displayTitle: String {
        if let providerDisplayName, !providerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return providerDisplayName
        }
        return implementation == "mcp" ? providerAccountId : "Account \(providerAccountId)"
    }
}

/// One spelling of Gateway connection health for every sheet that shows it.
package enum IntegrationHealthPresentation {
    package static func label(_ health: String) -> String {
        switch health {
        case "ready": "Ready"
        case "disabled": "Disabled"
        case "auth-error": "Authentication error"
        case "disconnected": "Disconnected"
        case "setup-required": "Setup required"
        default: "Unavailable"
        }
    }
}

package struct IntegrationCapabilityStatus: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package let availability: String
    package let effects: [String]
    package let definitionId: String
    package let connectionId: String?
    package let provenance: IntegrationCapabilityProvenance
    package let detail: String?
    var instanceCapabilityID: String { "\(connectionId ?? definitionId):\(id)" }
}

package struct IntegrationCapabilityProvenance: Codable, Hashable, Sendable {
    package let owner: String
    let definitionId: String
    let connectionId: String?
}

package struct IntegrationSetupOperation: Codable, Hashable, Sendable, Identifiable {
    let operationId: String
    let instanceId: String
    let definitionId: String
    let method: String
    let status: String
    let createdAt: String
    let updatedAt: String
    package var id: String { operationId }
}

package struct IntegrationSnapshot: Codable, Hashable, Sendable {
    package let definitions: [IntegrationDefinition]
    package let instances: [IntegrationInstance]
    package let setupOperations: [IntegrationSetupOperation]
    package let capabilities: [IntegrationCapabilityStatus]
    package let stateRevision: Int
}

package struct IntegrationSetupStarted: Codable, Hashable, Sendable {
    package let operationId: String
    package let instanceId: String
    package let definitionId: String?
    package let method: String?
    package let status: String
}

package struct IntegrationSetupCompleted: Codable, Hashable, Sendable {
    package let id: String
    package let definitionId: String
    let implementation: String
    let providerAccountId: String
    let scope: String?
    package let policy: IntegrationPolicy
    package let health: String
    let createdAt: String
    let updatedAt: String
    package let setupRevision: Int
    let lastError: String?
}

package struct IntegrationSetupConfiguration: Codable, Hashable, Sendable {
    let transport: String
    let endpoint: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let env: [String: String]?

    package init(transport: String, endpoint: String?, command: String?, args: [String]?, cwd: String?, env: [String: String]?) {
        self.transport = transport
        self.endpoint = endpoint
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
    }
}
