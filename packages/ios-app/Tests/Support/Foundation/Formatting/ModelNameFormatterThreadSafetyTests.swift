import Testing
import Foundation

@testable import TronMobile

@Suite("ModelNameFormatter Thread Safety Tests")
struct ModelNameFormatterThreadSafetyTests {

    private func makeModel(id: String, name: String, provider: String, tier: String = "sonnet") -> ModelInfo {
        // I8: required metadata fields have no defaults.
        ModelInfo(
            id: id,
            name: name,
            provider: provider,
            contextWindow: 200_000,
            supportsThinking: false,
            supportsImages: false,
            supportsDocuments: false,
            tier: tier,
            isRetiredGeneration: false
        )
    }

    @Test("concurrent reads during write do not crash")
    func concurrentReadWrite() async {
        // Pre-populate
        let model = makeModel(id: "claude-sonnet-4-6", name: "Sonnet 4.6", provider: "anthropic", tier: "sonnet")
        ModelNameFormatter.updateFromServer([model])

        await withTaskGroup(of: Void.self) { group in
            // Concurrent reads
            for _ in 0..<100 {
                group.addTask {
                    _ = ModelNameFormatter.format("claude-sonnet-4-6", style: .short)
                }
            }

            // Concurrent writes interleaved
            for i in 0..<10 {
                group.addTask {
                    let models = [
                        ModelInfo(
                            id: "claude-sonnet-4-6",
                            name: "Sonnet 4.6 v\(i)",
                            provider: "anthropic",
                            contextWindow: 200_000,
                            supportsThinking: false,
                            supportsImages: false,
                            supportsDocuments: false,
                            tier: "sonnet",
                            isRetiredGeneration: false
                        )
                    ]
                    ModelNameFormatter.updateFromServer(models)
                }
            }

            // More reads
            for _ in 0..<100 {
                group.addTask {
                    _ = "claude-sonnet-4-6".shortModelName
                }
            }

            await group.waitForAll()
        }

        // Verify formatter still works correctly after stress
        ModelNameFormatter.updateFromServer([model])
        let result = ModelNameFormatter.format("claude-sonnet-4-6", style: .short)
        #expect(result == "Sonnet 4.6")
    }

    @Test("concurrent format calls without server cache do not crash")
    func concurrentHeuristicFormatting() async {
        ModelNameFormatter.updateFromServer([])

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    ModelNameFormatter.format("claude-opus-4-5-20250514", style: .short)
                }
            }

            var results: [String] = []
            for await str in group {
                results.append(str)
            }

            #expect(results.count == 200)
            // All should be identical (heuristic is deterministic)
            for str in results {
                #expect(str == "Opus 4.5")
            }
        }
    }

    @Test("formatModelDisplayName is thread-safe")
    func concurrentFormatModelDisplayName() async {
        let model = makeModel(id: "claude-opus-4-6", name: "Opus 4.6", provider: "anthropic", tier: "opus")
        ModelNameFormatter.updateFromServer([model])

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    formatModelDisplayName("claude-opus-4-6")
                }
            }

            for await result in group {
                #expect(result == "Opus 4.6")
            }
        }
    }
}
