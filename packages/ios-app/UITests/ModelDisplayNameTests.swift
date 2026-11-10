@testable import TronMobileCore
import XCTest

/// Chips, Home worker rows and tool details name a model from its bare
/// `ModelRef` ID. Real catalog IDs must read as their catalog names, with a
/// version's dot, without a per-model table.
final class ModelDisplayNameTests: XCTestCase {
    func testModelIDsReadAsVersionedNames() {
        let names = [
            "claude-fable-5-2": "Claude Fable 5.2",
            "claude-opus-4-6": "Claude Opus 4.6",
            "claude-opus-5-5": "Claude Opus 5.5",
            "claude-sonnet-5": "Claude Sonnet 5",
            "claude-3-5-sonnet": "Claude 3.5 Sonnet",
            "claude-haiku-4-5": "Claude Haiku 4.5 (latest)",
            "claude-haiku-4-5-20251001": "Claude Haiku 4.5",
            "gpt-6-1-sol": "GPT 6.1 Sol",
            "gpt-6.1-sol": "GPT 6.1 Sol",
            "gemini-2-5-pro": "Gemini 2.5 Pro",
            "mistral-large-4-0-8": "Mistral Large 4.0.8",
            "llama-3-1-70b": "Llama 3.1 70b",
            "gpt-4o-2024-05-13": "GPT 4o 2024 05 13",
            "qwen3.5-flash-02-23": "Qwen3.5 Flash 02 23",
            "o4-mini": "O4 Mini",
        ]
        for (id, name) in names {
            XCTAssertEqual(ModelRef(provider: "anthropic", id: id).displayName, name, id)
        }
        XCTAssertEqual(ModelRef(provider: "anthropic", id: " ").displayName, "Unknown model")
        XCTAssertEqual(ModelRef(provider: "anthropic", id: "claude-fable-5-2").displayDescription,
                       "Anthropic / Claude Fable 5.2")
    }
}
