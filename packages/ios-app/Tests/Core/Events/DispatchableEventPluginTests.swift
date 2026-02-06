import XCTest
@testable import TronMobile

/// Tests for the DispatchableEventPlugin infrastructure.
/// Verifies that self-dispatching plugins correctly route through the box.
@MainActor
final class DispatchableEventPluginTests: XCTestCase {

    // MARK: - Test that DispatchablePluginBoxImpl dispatches correctly

    func testDispatchablePluginBoxDispatchesResult() {
        // Given: A dispatchable plugin box (TextDeltaPlugin is not yet dispatchable,
        // so we test with the box infrastructure directly)
        let mockContext = MockEventDispatchContext()

        // Create a DispatchablePluginBoxImpl for our test plugin
        let box = DispatchablePluginBoxImpl<TestDispatchablePlugin>()

        // When: Dispatching a result
        let result = TestDispatchablePlugin.Result(value: "test-value")
        let handled = box.dispatch(result: result, context: mockContext)

        // Then: Should return true (supports dispatch) and call the handler
        XCTAssertTrue(handled)
        XCTAssertEqual(mockContext.logDebugMessage, "TestDispatchable: test-value")
    }

    func testStandardPluginBoxDoesNotDispatch() {
        // Given: A standard (non-dispatchable) plugin box
        let mockContext = MockEventDispatchContext()
        let box = EventPluginBoxImpl<TestStandardPlugin>()

        // When: Trying to dispatch
        let result = TestStandardPlugin.Result(value: "test")
        let handled = box.dispatch(result: result, context: mockContext)

        // Then: Should return false (does not support dispatch)
        XCTAssertFalse(handled)
    }

    func testDispatchablePluginRegistersAsDispatchable() {
        // Given: A registry with a dispatchable plugin
        let registry = EventRegistry.shared
        let originalCount = registry.pluginCount

        registry.register(TestDispatchablePlugin.self)

        // When: Looking up the box
        let box = registry.pluginBox(for: TestDispatchablePlugin.eventType)

        // Then: Box should exist and support dispatch
        XCTAssertNotNil(box)

        let mockContext = MockEventDispatchContext()
        let result = TestDispatchablePlugin.Result(value: "registry-test")
        let handled = box!.dispatch(result: result, context: mockContext)
        XCTAssertTrue(handled)
        XCTAssertEqual(mockContext.logDebugMessage, "TestDispatchable: registry-test")

        // Cleanup
        registry.clearForTesting()
        registry.registerAll()
    }

    // MARK: - Domain Protocol Conformance

    func testMockContextConformsToAllDomainProtocols() {
        let context = MockEventDispatchContext()

        // Verify it can be used as each domain protocol
        let _: any StreamingEventHandler = context
        let _: any ToolEventHandler = context
        let _: any TurnLifecycleEventHandler = context
        let _: any ContextEventHandler = context
        let _: any BrowserEventHandler = context
        let _: any SubagentEventHandler = context
        let _: any UICanvasEventHandler = context
        let _: any TodoEventHandler = context
        let _: any EventDispatchLogger = context

        // And as the composed target
        let _: any EventDispatchTarget = context
    }
}

// MARK: - Test Helpers

/// A standard (non-dispatchable) plugin for testing.
private enum TestStandardPlugin: EventPlugin {
    static let eventType = "__test.standard"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    struct Result: EventResult {
        let value: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(value: "transformed")
    }
}

/// A dispatchable plugin for testing self-dispatch.
enum TestDispatchablePlugin: DispatchableEventPlugin {
    static let eventType = "__test.dispatchable"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    struct Result: EventResult {
        let value: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(value: "transformed")
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.logDebug("TestDispatchable: \(r.value)")
    }
}

// MARK: - Extended Mock

extension MockEventDispatchContext {
    /// Track the last logDebug message for dispatch verification
    var logDebugMessage: String? {
        logDebugCalledWith
    }
}
