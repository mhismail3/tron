import Foundation

package struct UUIDSource: Sendable {
    package let next: @Sendable () -> UUID

    package init(next: @escaping @Sendable () -> UUID) {
        self.next = next
    }

    package static let random = UUIDSource(next: UUID.init)
}
