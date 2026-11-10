import XCTest

extension XCTestCase {
    /// Reads `condition` now and then every 0.1 s until `timeout`, and once more after it, as
    /// `waitForExistence` does; a read started before the deadline may finish after it. A
    /// synthesized action returns only after the app idles, so settled state passes on the first
    /// read. A predicate expectation first reads after about 1 s, and each read takes accessibility
    /// snapshots that cost seconds under load, so it can time out a condition that already held
    /// (#2410); `test-source-policy.sh` keeps it out of UI tests.
    @MainActor
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    /// Key paths read through KVC: `frame` is a boxed CGRect, so geometry belongs in a closure.
    @MainActor
    func waitUntil(_ object: Any?, _ predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { predicate.evaluate(with: object) }
    }

    /// `@nonobjc`: XCTestCase is an Objective-C class, and this overload's selector would
    /// collide with the NSPredicate one.
    @MainActor @nonobjc
    func waitUntil(_ object: Any?, _ format: String, timeout: TimeInterval = 10) -> Bool {
        waitUntil(object, NSPredicate(format: format), timeout: timeout)
    }

    /// A presentation has settled once `element` is hittable and holds its frame across two reads.
    @MainActor
    func waitUntilSettled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        var previous: CGRect?
        return waitUntil(timeout: timeout) {
            let frame = element.isHittable ? element.frame : nil
            defer { previous = frame }
            return frame != nil && frame == previous
        }
    }
}
