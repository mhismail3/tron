import XCTest

/// Hang bound for UIKit/SwiftUI callbacks a hosted-view test needs before it
/// can assert: appearance, presentation-transition and animation completion,
/// and `TimelineView` ticks. It is not a speed budget, so no oracle may depend
/// on how quickly these callbacks arrive. Hosted CI runners stall the main
/// thread for several seconds (about 8 s observed in #402), which tight 2–3 s
/// waits reported as failures. It matches the 20 s `withTestWatchdog` bound
/// used for comparable hosted work.
let hostedEventHangBound: TimeInterval = 20

struct HostedEventHang: Error, CustomStringConvertible {
    let events: [String]
    let result: XCTWaiter.Result

    var description: String {
        "Hosted UI event(s) \(events) did not arrive within the \(Int(hostedEventHangBound)) s hang bound (\(result)); the view never appeared, settled or ticked."
    }
}

/// Awaits hosted lifecycle callbacks, failing only when one hangs.
@MainActor
func awaitHostedEvents(_ expectations: [XCTestExpectation]) async throws {
    let result = await XCTWaiter.fulfillment(of: expectations, timeout: hostedEventHangBound)
    guard result == .completed else {
        throw HostedEventHang(events: expectations.map(\.expectationDescription), result: result)
    }
}

/// Awaits a hosted main-actor state (a SwiftUI publication, mounted routing,
/// or a settled animation) under the same hang bound.
@MainActor
func awaitHostedCondition(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
    let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        MainActor.assumeIsolated { condition() }
    }, object: nil)
    reached.expectationDescription = description
    try await awaitHostedEvents([reached])
}
