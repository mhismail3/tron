import Foundation
import Synchronization
@testable import TronMobile

final class SequenceUUIDSource: Sendable {
    private let values: Mutex<[UUID]>

    init(_ values: [UUID]) {
        self.values = Mutex(values)
    }

    var source: UUIDSource {
        UUIDSource { [self] in
            self.values.withLock { values in
                precondition(!values.isEmpty, "SequenceUUIDSource exhausted")
                return values.removeFirst()
            }
        }
    }
}
