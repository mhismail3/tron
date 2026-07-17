import XCTest
@testable import TronMobile

@MainActor
final class StreamRecoveryRequiredPluginTests: XCTestCase {
    func testStrictGlobalPayloadParsesAndDispatches() throws {
        let registry = EventRegistry()
        registry.registerAll()
        let payload = Data(
            #"{"type":"stream.recovery_required","data":{"reason":"source_lag","droppedEventCount":7}}"#.utf8
        )

        let event = try XCTUnwrap(
            registry.parse(type: StreamRecoveryRequiredPlugin.eventType, data: payload)
        )
        let result = try XCTUnwrap(event.getResult() as? StreamRecoveryRequiredPlugin.Result)
        let context = MockEventDispatchContext()

        XCTAssertNil(event.sessionId)
        XCTAssertTrue(event.matchesSession("any-mounted-session"))
        XCTAssertEqual(result.reason, "source_lag")
        XCTAssertEqual(result.droppedEventCount, 7)

        registry.dispatch(
            type: event.eventType,
            transform: { result },
            context: context
        )
        XCTAssertEqual(context.handleStreamRecoveryRequiredCalledWith?.reason, "source_lag")
        XCTAssertEqual(context.handleStreamRecoveryRequiredCalledWith?.droppedEventCount, 7)
    }

    func testMissingContinuityFieldsFailClosed() {
        let registry = EventRegistry()
        registry.registerAll()
        let missingCount = Data(
            #"{"type":"stream.recovery_required","data":{"reason":"source_lag"}}"#.utf8
        )

        XCTAssertNil(
            registry.parse(type: StreamRecoveryRequiredPlugin.eventType, data: missingCount)
        )
    }
}
