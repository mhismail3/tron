import Foundation
import Testing
@testable import TronMobile

@Suite("Runner failure-path fixture")
struct RunnerFailureFixtureTests {
    @Test("opt-in product failure returns through Xcode normally")
    func optInFailure() {
        guard ProcessInfo.processInfo.environment["TRON_IOS_INTENTIONAL_TEST_FAILURE"] == "1" else {
            return
        }
        Issue.record("Intentional canonical-runner failure fixture")
    }

    @Test("opt-in blocked test is terminated by the process owner")
    func optInHang() {
        guard ProcessInfo.processInfo.environment["TRON_IOS_INTENTIONAL_TEST_HANG"] == "1" else {
            return
        }
        Thread.sleep(forTimeInterval: 60)
    }
}
