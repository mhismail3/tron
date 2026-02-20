import XCTest
@testable import TronMobile

private enum TestError: LocalizedError {
    case simulated

    var errorDescription: String? { "simulated" }
}

@MainActor
final class AppInitializerTests: XCTestCase {

    func test_initialState_isLoading() {
        let initializer = AppInitializer()
        XCTAssertEqual(initializer.state, .loading)
        XCTAssertFalse(initializer.isReady)
    }

    func test_initialize_success_setsReady() async {
        let initializer = AppInitializer()

        await initializer.initialize { }

        XCTAssertEqual(initializer.state, .ready)
        XCTAssertTrue(initializer.isReady)
    }

    func test_initialize_failure_setsError() async {
        let initializer = AppInitializer()

        await initializer.initialize { throw TestError.simulated }

        XCTAssertEqual(initializer.state, .failed("simulated"))
        XCTAssertFalse(initializer.isReady)
    }

    func test_retry_afterFailure_canSucceed() async {
        let initializer = AppInitializer()

        await initializer.initialize { throw TestError.simulated }
        XCTAssertEqual(initializer.state, .failed("simulated"))

        await initializer.initialize { }
        XCTAssertEqual(initializer.state, .ready)
        XCTAssertTrue(initializer.isReady)
    }

    func test_initialize_skipsIfAlreadyReady() async {
        let initializer = AppInitializer()
        var callCount = 0

        await initializer.initialize { callCount += 1 }
        XCTAssertTrue(initializer.isReady)
        XCTAssertEqual(callCount, 1)

        // Second call should be a no-op
        await initializer.initialize { callCount += 1 }
        XCTAssertTrue(initializer.isReady)
        XCTAssertEqual(callCount, 1)
    }
}
