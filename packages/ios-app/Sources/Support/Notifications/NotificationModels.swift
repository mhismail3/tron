import Foundation

struct NotificationServerReadiness: Codable, Equatable, Identifiable, Sendable {
    let serverId: String
    var ready: Bool
    var deviceReady: Bool?
    var transportMode: NotificationTransportMode?
    var transportConfigured: Bool?
    var transportProblem: String?
    var authorizationStatus: NotificationAuthorizationState
    var registeredAt: String?
    var problem: String?

    var id: String { serverId }
}

struct NotificationInboxItem: Codable, Equatable, Identifiable, Sendable {
    let serverId: String
    var delivery: NotificationDeliveryDTO

    var id: String { "\(serverId):\(delivery.deliveryId)" }
}

struct NotificationMutation: Codable, Equatable, Identifiable, Sendable {
    let mutationId: String
    let serverId: String
    let deliveryId: String
    let acknowledgement: NotificationAcknowledgement
    let occurredAt: String

    var id: String { mutationId }
}

struct NotificationServerWork: Equatable, Sendable {
    var registration = false
    var synchronization = false

    mutating func formUnion(_ other: NotificationServerWork) {
        registration = registration || other.registration
        synchronization = synchronization || other.synchronization
    }
}
