import Foundation

/// Hosted measurement fixtures and the visual parity gate run only in the
/// `UIValidation` test plan. A plan's `skippedTests` list is not honored for
/// Swift Testing tests (a full `UnitTests` run executed them), so these suites
/// gate on the plan name xcodebuild injects instead. Scheme and shell
/// environment do not reach the test process, so this variable is the carrier.
enum UIValidationTier {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCODE_TEST_PLAN_NAME"] == "UIValidation"
    }
}
