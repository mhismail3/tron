import XCTest
@testable import TronMobile

/// SendBlockReason derivation from InputBarConfig state.
///
/// `InputBarConfig.sendBlockReason` is the single source of truth for
/// "why is the send button disabled?". The UI derives its `canSend`
/// gate and the `.help()` tooltip from it. These tests pin the
/// evaluation order so a future change to one input signal doesn't
/// silently shift which reason the user sees.
@MainActor
final class SendBlockReasonTests: XCTestCase {

    private func config(
        agentPhase: AgentPhase = .idle,
        isCompacting: Bool = false,
        isRetaining: Bool = false,
        isConnected: Bool = true,
        readOnly: Bool = false
    ) -> InputBarConfig {
        InputBarConfig(
            agentPhase: agentPhase,
            isCompacting: isCompacting,
            isRetaining: isRetaining,
            isConnected: isConnected,
            readOnly: readOnly
        )
    }

    // MARK: - Per-reason derivation

    func testIdleAndConnectedProducesNoBlockReason() {
        XCTAssertNil(config().sendBlockReason)
    }

    func testDisconnectedBlocks() {
        XCTAssertEqual(config(isConnected: false).sendBlockReason, .disconnected)
    }

    func testCompactingBlocks() {
        XCTAssertEqual(config(isCompacting: true).sendBlockReason, .compacting)
    }

    func testRetainingBlocks() {
        XCTAssertEqual(config(isRetaining: true).sendBlockReason, .retaining)
    }

    func testReadOnlyBlocks() {
        XCTAssertEqual(config(readOnly: true).sendBlockReason, .readOnly)
    }

    // MARK: - Priority order

    /// Read-only wins over everything else — the session cannot accept
    /// input regardless of server state.
    func testReadOnlyBeatsEverything() {
        let c = config(
            isCompacting: true,
            isRetaining: true,
            isConnected: false,
            readOnly: true
        )
        XCTAssertEqual(c.sendBlockReason, .readOnly)
    }

    /// Disconnected beats compaction/retain — reconnecting is the user's
    /// first lever; server-side state doesn't matter until we can send.
    func testDisconnectedBeatsProcessing() {
        let c = config(
            isCompacting: true,
            isRetaining: true,
            isConnected: false
        )
        XCTAssertEqual(c.sendBlockReason, .disconnected)
    }

    /// Compaction beats retain — compaction has a more prominent pill
    /// in the chat and users expect it as the explanation.
    func testCompactingBeatsRetaining() {
        let c = config(isCompacting: true, isRetaining: true)
        XCTAssertEqual(c.sendBlockReason, .compacting)
    }

    // MARK: - Description text

    func testEveryReasonHasUserFacingDescription() {
        for reason in [SendBlockReason.disconnected, .compacting, .retaining, .readOnly] {
            XCTAssertFalse(
                reason.description.isEmpty,
                "\(reason) must have a non-empty description for the tooltip"
            )
        }
    }

    // MARK: - Interaction with agentPhase

    /// When the agent is processing, send might still be blocked by an
    /// orthogonal reason (compaction triggered during a turn). The
    /// blockReason is independent of agentPhase.
    func testSendBlockReasonIsIndependentOfAgentPhase() {
        // Processing + compaction: compaction blocks even though
        // queueing would otherwise be allowed.
        let c = config(agentPhase: .processing, isCompacting: true)
        XCTAssertEqual(c.sendBlockReason, .compacting)
    }

    func testSendBlockReasonNilDuringProcessingWithoutOtherBlockers() {
        let c = config(agentPhase: .processing)
        XCTAssertNil(c.sendBlockReason,
                     "processing alone doesn't block send — user can queue")
    }
}
