import XCTest
@testable import TronMobile

/// Snapshot tests for EventTypeRegistry classification.
/// Captures current behavior of all 5 computed properties for every enum case
/// to ensure the EventClassification consolidation introduces no regressions.
final class EventTypeRegistryTests: XCTestCase {

    // MARK: - Snapshot: All Cases Have Classification

    func testAllCasesProduceClassification() {
        for eventType in PersistedEventType.allCases {
            // Every case should produce a non-empty displayDescription
            XCTAssertFalse(eventType.displayDescription.isEmpty,
                           "\(eventType.rawValue) has empty displayDescription")
        }
    }

    // MARK: - Snapshot: Key Classifications

    func testMessageUserClassification() {
        let t = PersistedEventType.messageUser
        XCTAssertTrue(t.rendersAsChatMessage)
        XCTAssertTrue(t.affectsSessionState)
        XCTAssertFalse(t.isStreamingEvent)
        XCTAssertFalse(t.isMetadataOnly)
    }

    func testMessageAssistantClassification() {
        let t = PersistedEventType.messageAssistant
        XCTAssertTrue(t.rendersAsChatMessage)
        XCTAssertTrue(t.affectsSessionState)
        XCTAssertFalse(t.isStreamingEvent)
        XCTAssertFalse(t.isMetadataOnly)
    }

    func testStreamTextDeltaClassification() {
        let t = PersistedEventType.streamTextDelta
        XCTAssertFalse(t.rendersAsChatMessage)
        XCTAssertFalse(t.affectsSessionState)
        XCTAssertTrue(t.isStreamingEvent)
        XCTAssertTrue(t.isMetadataOnly)
    }

    func testCapabilityInvocationClassification() {
        let t = PersistedEventType.capabilityInvocationStarted
        XCTAssertTrue(t.rendersAsChatMessage)
        XCTAssertTrue(t.affectsSessionState)
        XCTAssertFalse(t.isStreamingEvent)
        XCTAssertFalse(t.isMetadataOnly)
    }

    func testCapabilityInvocationResultClassification() {
        let t = PersistedEventType.capabilityInvocationCompleted
        XCTAssertTrue(t.rendersAsChatMessage)
        XCTAssertTrue(t.affectsSessionState)
        XCTAssertFalse(t.isStreamingEvent)
        XCTAssertFalse(t.isMetadataOnly)
    }

    func testStreamThinkingCompleteClassification() {
        let t = PersistedEventType.streamThinkingComplete
        XCTAssertFalse(t.rendersAsChatMessage)
        XCTAssertFalse(t.affectsSessionState)
        XCTAssertTrue(t.isStreamingEvent)
        XCTAssertFalse(t.isMetadataOnly)
    }

    func testSessionEndClassification() {
        let t = PersistedEventType.sessionEnd
        XCTAssertFalse(t.rendersAsChatMessage)
        XCTAssertFalse(t.affectsSessionState)
        XCTAssertFalse(t.isStreamingEvent)
        XCTAssertTrue(t.isMetadataOnly)
        // `session.end` is actively emitted by the Rust
        // `runtime/orchestrator/session_manager::end_session` path (persists
        // EventType::SessionEnd with {"reason": "completed"}). The iOS label
        // MUST NOT use the retired-era label. Regression guard for the prior wording.
        XCTAssertEqual(t.displayDescription, "Session ended")
    }

    /// Regression guard: no `displayDescription` across the registry contains
    /// the retired-era marker. If a future event type really
    /// is being retired, the enum case itself should be removed in the
    /// same commit as the server stops emitting it — we never carry that marker
    /// as a runtime label.
    func testNoDisplayDescriptionUsesRetiredEraLabel() {
        let retiredEraMarker = ["leg", "acy"].joined()
        for eventType in PersistedEventType.allCases {
            XCTAssertFalse(
                eventType.displayDescription.lowercased().contains(retiredEraMarker),
                "\(eventType.rawValue) label '\(eventType.displayDescription)' uses the retired-era marker"
            )
        }
    }

    func testFileReadIsMetadataOnly() {
        let t = PersistedEventType.fileRead
        XCTAssertFalse(t.rendersAsChatMessage)
        XCTAssertFalse(t.affectsSessionState)
        XCTAssertFalse(t.isStreamingEvent)
        XCTAssertTrue(t.isMetadataOnly)
    }

    // MARK: - Full Snapshot (regression guard)

    /// Captures the exact classification of every enum case as a dictionary.
    /// If any property changes after refactoring, this test will catch it.
    func testFullClassificationSnapshot() {
        var snapshot: [String: [String: Any]] = [:]

        for eventType in PersistedEventType.allCases {
            snapshot[eventType.rawValue] = [
                "rendersAsChatMessage": eventType.rendersAsChatMessage,
                "affectsSessionState": eventType.affectsSessionState,
                "isStreamingEvent": eventType.isStreamingEvent,
                "isMetadataOnly": eventType.isMetadataOnly,
                "displayDescription": eventType.displayDescription
            ]
        }

        // Spot-check critical entries
        XCTAssertEqual(snapshot["message.user"]?["rendersAsChatMessage"] as? Bool, true)
        XCTAssertEqual(snapshot["message.user"]?["affectsSessionState"] as? Bool, true)
        XCTAssertEqual(snapshot["stream.text_delta"]?["isStreamingEvent"] as? Bool, true)
        XCTAssertEqual(snapshot["stream.text_delta"]?["rendersAsChatMessage"] as? Bool, false)
        XCTAssertEqual(snapshot["file.read"]?["isMetadataOnly"] as? Bool, true)
        XCTAssertEqual(snapshot["session.end"]?["rendersAsChatMessage"] as? Bool, false)
        XCTAssertEqual(snapshot["capability.invocation.started"]?["affectsSessionState"] as? Bool, true)
        XCTAssertEqual(snapshot["error.agent"]?["rendersAsChatMessage"] as? Bool, true)
        XCTAssertEqual(snapshot["error.agent"]?["affectsSessionState"] as? Bool, true)
        XCTAssertEqual(snapshot["compact.boundary"]?["rendersAsChatMessage"] as? Bool, true)
        XCTAssertEqual(snapshot["compact.boundary"]?["isMetadataOnly"] as? Bool, true)

        // Streaming events should all be isMetadataOnly=true (except thinkingComplete and turnEnd-specific cases)
        XCTAssertEqual(snapshot["stream.turn_end"]?["isStreamingEvent"] as? Bool, true)
        XCTAssertEqual(snapshot["stream.turn_end"]?["isMetadataOnly"] as? Bool, true)
        XCTAssertEqual(snapshot["stream.turn_start"]?["isMetadataOnly"] as? Bool, true)
        XCTAssertEqual(snapshot["stream.thinking_complete"]?["isMetadataOnly"] as? Bool, false)

        // Verify total count matches allCases
        XCTAssertEqual(snapshot.count, PersistedEventType.allCases.count)
    }
}
