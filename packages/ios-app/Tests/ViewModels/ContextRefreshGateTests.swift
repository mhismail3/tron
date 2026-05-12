import XCTest
@testable import TronMobile

@MainActor
final class ContextRefreshGateTests: XCTestCase {
    func testConcurrentRefreshesShareOneServerRead() async {
        let gate = ContextRefreshGate()
        let counter = RefreshCounter()

        async let first: Void = gate.run {
            counter.increment()
            try? await Task.sleep(for: .milliseconds(40))
        }
        async let second: Void = gate.run {
            counter.increment()
        }
        async let third: Void = gate.run {
            counter.increment()
        }

        _ = await (first, second, third)
        XCTAssertEqual(counter.count, 1)

        await gate.run {
            counter.increment()
        }
        XCTAssertEqual(counter.count, 2)
    }
}

@MainActor
private final class RefreshCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
