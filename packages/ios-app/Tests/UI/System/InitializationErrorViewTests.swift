import XCTest
@testable import TronMobile

final class InitializationErrorViewTests: XCTestCase {

    func test_initErrorView_instantiation() {
        let view = InitializationErrorView(message: "DB failed", onRetry: {})
        XCTAssertNotNil(view)
    }
}
