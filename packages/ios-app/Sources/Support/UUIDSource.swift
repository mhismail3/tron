import Foundation

struct UUIDSource: Sendable {
    let next: @Sendable () -> UUID

    static let random = UUIDSource(next: UUID.init)
}
