import Foundation
@testable import TronMobile

final class RecordingPerformanceSignposts: PerformanceSignposting, @unchecked Sendable {
    enum Event: Equatable {
        case begin(PerformanceOperation)
        case end(PerformanceOperation, PerformanceResult, PerformanceMetrics)

        var operation: PerformanceOperation {
            switch self {
            case .begin(let operation), .end(let operation, _, _): operation
            }
        }
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        lock.withLock { recorded.append(.begin(operation)) }
        return PerformanceInterval(operation: operation)
    }

    func end(
        _ interval: PerformanceInterval,
        result: PerformanceResult,
        metrics: PerformanceMetrics
    ) {
        lock.withLock { recorded.append(.end(interval.operation, result, metrics)) }
    }

    func events() -> [Event] {
        lock.withLock { recorded }
    }

    func reset() {
        lock.withLock { recorded.removeAll() }
    }
}
