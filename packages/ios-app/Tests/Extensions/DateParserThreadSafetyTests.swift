import Testing
import Foundation

@testable import TronMobile

@Suite("DateParser Thread Safety Tests")
struct DateParserThreadSafetyTests {

    // MARK: - Concurrent Parsing

    @Test("concurrent parse calls produce correct results without crashes")
    func concurrentParsing() async {
        let isoString = "2026-01-15T10:30:00.123Z"

        await withTaskGroup(of: Date?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    DateParser.parse(isoString)
                }
            }

            var results: [Date] = []
            for await date in group {
                if let date { results.append(date) }
            }

            #expect(results.count == 100, "All 100 concurrent parses should succeed")

            // All results should be identical
            if let first = results.first {
                for date in results {
                    #expect(abs(date.timeIntervalSince(first)) < 0.001,
                            "All concurrent parses should produce the same date")
                }
            }
        }
    }

    @Test("concurrent format calls produce correct results without crashes")
    func concurrentFormatting() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    DateParser.formatTime(date)
                }
            }

            var results: [String] = []
            for await str in group {
                results.append(str)
            }

            #expect(results.count == 100)

            // All results should be identical
            if let first = results.first {
                for str in results {
                    #expect(str == first,
                            "All concurrent formats should produce identical output")
                }
            }
        }
    }

    @Test("concurrent relative formatting does not crash")
    func concurrentRelativeFormatting() async {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    DateParser.relativeAbbreviated(fiveMinutesAgo)
                }
            }

            var results: [String] = []
            for await str in group {
                results.append(str)
            }

            #expect(results.count == 100)
            // All should be non-empty
            for str in results {
                #expect(!str.isEmpty)
            }
        }
    }

    @Test("concurrent mixed operations do not crash")
    func concurrentMixedOperations() async {
        let isoString = "2026-06-15T14:30:00.000Z"
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        await withTaskGroup(of: Void.self) { group in
            // Parsing
            for _ in 0..<50 {
                group.addTask { _ = DateParser.parse(isoString) }
            }
            // ISO output
            for _ in 0..<50 {
                group.addTask { _ = DateParser.toISO8601(date) }
            }
            // Relative formatting
            for _ in 0..<50 {
                group.addTask { _ = DateParser.relativeAbbreviated(date) }
            }
            // Display formatting
            for _ in 0..<50 {
                group.addTask { _ = DateParser.formatDateTime(date) }
            }
            // formatRelativeOrAbsolute
            for _ in 0..<50 {
                group.addTask { _ = DateParser.formatRelativeOrAbsolute(isoString) }
            }

            await group.waitForAll()
        }
        // If we get here without crashing, thread safety is working
    }

    // MARK: - Output Correctness After Concurrency

    @Test("formatting output is correct after concurrent stress")
    func correctnessAfterStress() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        // Run concurrent stress
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = DateParser.formatTime(date) }
                group.addTask { _ = DateParser.formatDate(date) }
                group.addTask { _ = DateParser.relativeAbbreviated(date) }
            }
            await group.waitForAll()
        }

        // Verify formatters still produce correct output after stress
        let timeResult = DateParser.formatTime(date)
        let dateResult = DateParser.formatDate(date)
        let isoResult = DateParser.toISO8601(date)

        #expect(!timeResult.isEmpty)
        #expect(!dateResult.isEmpty)
        #expect(DateParser.parse(isoResult) != nil, "ISO roundtrip should still work after stress")
    }
}
