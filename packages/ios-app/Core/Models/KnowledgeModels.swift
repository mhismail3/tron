import Foundation

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

package struct KnowledgeDestinationIdentity: Equatable, Sendable {
    package let profileID: String?
    package let lifecycleGeneration: Int

    package init(profileID: String?, lifecycleGeneration: Int) {
        self.profileID = profileID
        self.lifecycleGeneration = lifecycleGeneration
    }
}
