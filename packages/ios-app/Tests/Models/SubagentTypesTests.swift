import XCTest
@testable import TronMobile

/// Tests for `SubagentSpawnType` strict decoding.
///
/// Context: the prior implementation had a silent fallback
/// `default: self = .toolAgent` on `init(from:)` that coerced unknown or
/// missing raw values into `.toolAgent`. That was "back-compat" code for a
/// world in which the server might not emit `spawnType` — which is no
/// longer true. Every subagent event from the Rust server carries a
/// non-empty `spawnType` produced by `SpawnType::as_str`, so iOS decoding
/// is strict: unknown and nil produce `nil`, callers decide what to do.
///
/// These tests guard the three invariants:
///   1. Known raw values decode to the matching case.
///   2. Unknown raw values return `nil`.
///   3. `nil` raw values return `nil`.
///
/// Regression: `no_default_toolAgent_classification` locks in that a
/// synthetic garbage string does NOT coerce to `.toolAgent`, so a re-add
/// of the silent fallback would fail the suite.
final class SubagentTypesTests: XCTestCase {

    // MARK: - Known variants

    func test_init_from_toolAgent_decodes() {
        XCTAssertEqual(SubagentSpawnType(from: "toolAgent"), .toolAgent)
    }

    func test_init_from_subsession_decodes() {
        XCTAssertEqual(SubagentSpawnType(from: "subsession"), .subsession)
    }

    func test_init_from_hook_decodes() {
        XCTAssertEqual(SubagentSpawnType(from: "hook"), .hook)
    }

    // MARK: - Unknown / nil

    func test_init_from_unknown_returns_nil() {
        XCTAssertNil(SubagentSpawnType(from: "bogus"))
    }

    func test_init_from_empty_string_returns_nil() {
        XCTAssertNil(SubagentSpawnType(from: ""))
    }

    func test_init_from_nil_returns_nil() {
        XCTAssertNil(SubagentSpawnType(from: nil))
    }

    // MARK: - Case sensitivity

    func test_init_is_case_sensitive() {
        // The Rust side encodes the exact camelCase variant. Pascal / snake /
        // kebab / upper forms MUST fail to decode to guard against drift.
        XCTAssertNil(SubagentSpawnType(from: "ToolAgent"))
        XCTAssertNil(SubagentSpawnType(from: "TOOLAGENT"))
        XCTAssertNil(SubagentSpawnType(from: "tool_agent"))
        XCTAssertNil(SubagentSpawnType(from: "tool-agent"))
    }

    // MARK: - Regression: no silent fallback

    func test_no_default_toolAgent_classification() {
        // If anyone re-introduces `default: self = .toolAgent`, this suite
        // explodes: the prior behavior would turn every unknown string into
        // .toolAgent, which the assertion here denies.
        let unknownInputs: [String?] = [
            nil,
            "",
            "bogus",
            "task", "agent", "sub", "hooks", "ToolAgent",
        ]
        for input in unknownInputs {
            XCTAssertNil(
                SubagentSpawnType(from: input),
                "Unknown input \(input ?? "<nil>") must NOT decode to .toolAgent"
            )
        }
    }

    // MARK: - Rust-side contract mirror

    /// Mirrors `SpawnType::as_str` on the Rust side
    /// (`packages/agent/src/runtime/orchestrator/subagent_manager.rs`). If a
    /// new variant is added to the Rust enum without updating iOS, the
    /// compilation of this test will not catch it — but the wire-level
    /// decode will return `nil` on the new variant and the emit sites will
    /// log an error. This test locks in the CURRENT three-variant contract.
    func test_wire_contract_matches_rust_spawn_type_as_str() {
        let knownEncodings = ["toolAgent", "subsession", "hook"]
        let expectedCases: [SubagentSpawnType] = [.toolAgent, .subsession, .hook]
        XCTAssertEqual(knownEncodings.count, expectedCases.count)
        for (raw, expected) in zip(knownEncodings, expectedCases) {
            XCTAssertEqual(SubagentSpawnType(from: raw), expected)
        }
    }
}
