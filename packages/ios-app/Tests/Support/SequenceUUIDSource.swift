import Foundation
import Synchronization
@testable import TronMobile

final class SequenceUUIDSource: Sendable {
    private struct State {
        var values: [UUID]
        var consumedCount = 0
    }

    private let state: Mutex<State>

    init(_ values: [UUID]) {
        self.state = Mutex(State(values: values))
    }

    var consumedCount: Int {
        state.withLock { state in state.consumedCount }
    }

    var source: UUIDSource {
        UUIDSource { [self] in
            self.state.withLock { state in
                precondition(!state.values.isEmpty, "SequenceUUIDSource exhausted")
                state.consumedCount += 1
                return state.values.removeFirst()
            }
        }
    }
}
