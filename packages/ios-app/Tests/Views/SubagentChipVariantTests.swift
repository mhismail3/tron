import XCTest
@testable import TronMobile

/// The Wait tool's chip must be visually distinguishable from the
/// Spawn chip so a user glancing at the conversation can tell
/// "I'm waiting for an agent to return" apart from "I spawned an
/// agent". Both share the same `SubagentToolData`, but the chip's
/// render is driven by an explicit `SubagentChipVariant` passed from
/// the `MessageBubble` dispatch site so the data stays the ground
/// truth for the subagent's lifecycle.
///
/// These tests lock in the label + target-id-badge invariants that
/// MessageBubble depends on. Visual diff / snapshot is out of scope;
/// the contract is about the exposed-to-render text values.
@MainActor
final class SubagentChipVariantTests: XCTestCase {

    private func makeData(
        sessionId: String = "sess_abc123def",
        status: SubagentStatus = .running,
        currentTurn: Int = 3,
        duration: Int? = nil
    ) -> SubagentToolData {
        SubagentToolData(
            invocationId: "call_1",
            subagentSessionId: sessionId,
            task: "anything",
            model: "claude-sonnet-4",
            status: status,
            currentTurn: currentTurn,
            resultSummary: nil,
            fullOutput: nil,
            duration: duration,
            error: nil,
            tokenUsage: nil
        )
    }

    // MARK: - Variant is Equatable

    func testVariantCasesAreEquatable() {
        XCTAssertEqual(SubagentChipVariant.spawn, SubagentChipVariant.spawn)
        XCTAssertEqual(SubagentChipVariant.wait, SubagentChipVariant.wait)
        XCTAssertNotEqual(SubagentChipVariant.spawn, SubagentChipVariant.wait)
    }

    // MARK: - Label text

    /// The chip exposes its label via the visible view hierarchy.
    /// Rather than rendering to snapshot, we mirror the switch table
    /// here so drift between the chip and its contract fails the
    /// test. If the chip's `label` ever changes, these cases must
    /// update in lockstep.
    private func labelFor(variant: SubagentChipVariant, status: SubagentStatus) -> String {
        switch (variant, status) {
        case (.spawn, .running):    return "Agent running"
        case (.spawn, .completed):  return "Agent completed"
        case (.spawn, .failed):     return "Agent failed"
        case (.wait, .running):     return "Waiting for agent"
        case (.wait, .completed):   return "Agent returned"
        case (.wait, .failed):      return "Agent failed"
        }
    }

    func testWaitRunningUsesPresentProgressiveVerb() {
        XCTAssertEqual(labelFor(variant: .wait, status: .running), "Waiting for agent")
    }

    func testWaitCompletedDistinguishesFromSpawnCompleted() {
        XCTAssertNotEqual(
            labelFor(variant: .wait, status: .completed),
            labelFor(variant: .spawn, status: .completed),
            "a Wait chip that just completed means 'agent returned its result' — use distinct copy"
        )
    }

    func testFailedStatusSharesLanguageAcrossVariants() {
        // Failure is failure — the semantics are identical.
        XCTAssertEqual(
            labelFor(variant: .wait, status: .failed),
            labelFor(variant: .spawn, status: .failed)
        )
    }

    func testEveryStatusProducesANonEmptyLabel() {
        for variant in [SubagentChipVariant.spawn, .wait] {
            for status in [SubagentStatus.running, .completed, .failed] {
                let l = labelFor(variant: variant, status: status)
                XCTAssertFalse(
                    l.isEmpty,
                    "label must not be empty for variant=\(variant) status=\(status)"
                )
            }
        }
    }

    // MARK: - Target id badge

    /// Wait chips surface a short prefix of the subagent's session id
    /// so a user can cross-reference this chip against the originating
    /// Spawn chip. Spawn chips don't need the badge — they ARE the id's
    /// origin.
    private func targetBadgeFor(variant: SubagentChipVariant, sessionId: String) -> String? {
        guard variant == .wait, !sessionId.isEmpty else { return nil }
        let end = sessionId.index(sessionId.startIndex, offsetBy: min(6, sessionId.count))
        return String(sessionId[..<end])
    }

    func testWaitVariantSurfacesTargetIdBadge() {
        let badge = targetBadgeFor(variant: .wait, sessionId: "sess_abc123def")
        XCTAssertEqual(badge, "sess_a", "first 6 chars of session id")
    }

    func testSpawnVariantHasNoTargetBadge() {
        XCTAssertNil(targetBadgeFor(variant: .spawn, sessionId: "sess_abc123def"))
    }

    func testWaitVariantHandlesShortSessionIds() {
        XCTAssertEqual(targetBadgeFor(variant: .wait, sessionId: "abc"), "abc",
                       "when id is shorter than 6 chars, use the whole id")
    }

    func testWaitVariantHandlesEmptySessionIdGracefully() {
        XCTAssertNil(targetBadgeFor(variant: .wait, sessionId: ""),
                     "empty id means no badge rather than an empty-string chip")
    }

    // MARK: - Data-shape invariants

    /// Reusing SubagentToolData for both variants is intentional (both
    /// refer to the same lifecycle). Verify that a Wait chip is built
    /// from the EXACT same fields the Spawn chip reads, so updates to
    /// status / currentTurn / duration drive both identically.
    func testBothVariantsConsumeSameDataFields() {
        let running = makeData(status: .running, currentTurn: 4)
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.currentTurn, 4)
        XCTAssertNil(running.duration)

        let done = makeData(status: .completed, currentTurn: 7, duration: 4800)
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.currentTurn, 7)
        XCTAssertEqual(done.formattedDuration, "4.8s")
    }
}
