import Foundation

// Shared presentation and accepted-result identities. These remain active in
// settings, uploads, connection setup and Profile; they contain no corpus data.
package struct KnowledgePresentationIdentity: Hashable, Sendable {
    package let profileID: String?
    package let lifecycleGeneration: Int?
    package let connectionID: Int?

    package var destinationIdentity: KnowledgeDestinationIdentity? {
        guard let lifecycleGeneration else { return nil }
        return KnowledgeDestinationIdentity(profileID: profileID, lifecycleGeneration: lifecycleGeneration)
    }

    package init(profileID: String?, lifecycleGeneration: Int?, connectionID: Int?) {
        self.profileID = profileID
        self.lifecycleGeneration = lifecycleGeneration
        self.connectionID = connectionID
    }
}

/// Form and accepted-result lifetime, distinct from a disposable read's socket.
package struct KnowledgeDestinationIdentity: Equatable, Sendable {
    package let profileID: String?
    package let lifecycleGeneration: Int

    package init(profileID: String?, lifecycleGeneration: Int) {
        self.profileID = profileID
        self.lifecycleGeneration = lifecycleGeneration
    }
}
