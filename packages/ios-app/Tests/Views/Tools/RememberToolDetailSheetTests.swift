import Testing
import Foundation
@testable import TronMobile

// MARK: - RememberDetailParser Action Category Tests

@Suite("RememberDetailParser.ActionCategory")
struct RememberActionCategoryTests {

    @Test("recall maps to memorySearch")
    func testRecall() {
        #expect(RememberDetailParser.actionCategory(from: "recall") == .memorySearch)
    }

    @Test("search maps to memorySearch")
    func testSearch() {
        #expect(RememberDetailParser.actionCategory(from: "search") == .memorySearch)
    }

    @Test("memory maps to memorySearch")
    func testMemory() {
        #expect(RememberDetailParser.actionCategory(from: "memory") == .memorySearch)
    }

    @Test("sessions maps to sessionList")
    func testSessions() {
        #expect(RememberDetailParser.actionCategory(from: "sessions") == .sessionList)
    }

    @Test("session maps to sessionDetail")
    func testSession() {
        #expect(RememberDetailParser.actionCategory(from: "session") == .sessionDetail)
    }

    @Test("events maps to eventQuery")
    func testEvents() {
        #expect(RememberDetailParser.actionCategory(from: "events") == .eventQuery)
    }

    @Test("messages maps to eventQuery")
    func testMessages() {
        #expect(RememberDetailParser.actionCategory(from: "messages") == .eventQuery)
    }

    @Test("tools maps to eventQuery")
    func testTools() {
        #expect(RememberDetailParser.actionCategory(from: "tools") == .eventQuery)
    }

    @Test("logs maps to eventQuery")
    func testLogs() {
        #expect(RememberDetailParser.actionCategory(from: "logs") == .eventQuery)
    }

    @Test("stats maps to dbStats")
    func testStats() {
        #expect(RememberDetailParser.actionCategory(from: "stats") == .dbStats)
    }

    @Test("schema maps to dbSchema")
    func testSchema() {
        #expect(RememberDetailParser.actionCategory(from: "schema") == .dbSchema)
    }

    @Test("read_blob maps to blobRead")
    func testReadBlob() {
        #expect(RememberDetailParser.actionCategory(from: "read_blob") == .blobRead)
    }

    @Test("unknown action defaults to memorySearch")
    func testUnknown() {
        #expect(RememberDetailParser.actionCategory(from: "nonexistent") == .memorySearch)
    }
}

// MARK: - Action Display Name Tests

@Suite("RememberDetailParser.ActionDisplayName")
struct RememberActionDisplayNameTests {

    @Test("recall displays as Semantic Recall")
    func testRecall() {
        #expect(RememberDetailParser.actionDisplayName("recall") == "Semantic Recall")
    }

    @Test("search displays as Keyword Search")
    func testSearch() {
        #expect(RememberDetailParser.actionDisplayName("search") == "Keyword Search")
    }

    @Test("stats displays as Database Stats")
    func testStats() {
        #expect(RememberDetailParser.actionDisplayName("stats") == "Database Stats")
    }

    @Test("unknown action capitalizes")
    func testUnknown() {
        #expect(RememberDetailParser.actionDisplayName("custom") == "Custom")
    }
}

// MARK: - Action Icon Tests

@Suite("RememberDetailParser.ActionIcon")
struct RememberActionIconTests {

    @Test("recall uses sparkles icon")
    func testRecall() {
        #expect(RememberDetailParser.actionIcon("recall") == "sparkles")
    }

    @Test("sessions uses rectangle.stack icon")
    func testSessions() {
        #expect(RememberDetailParser.actionIcon("sessions") == "rectangle.stack")
    }

    @Test("stats uses chart.bar icon")
    func testStats() {
        #expect(RememberDetailParser.actionIcon("stats") == "chart.bar")
    }

    @Test("unknown uses brain.fill icon")
    func testUnknown() {
        #expect(RememberDetailParser.actionIcon("unknown") == "brain.fill")
    }
}

// MARK: - Memory Entry Parsing Tests

@Suite("RememberDetailParser.parseMemoryEntries")
struct RememberMemoryEntryParsingTests {

    @Test("Parses entries with relevance scores")
    func testWithRelevance() {
        let result = "1. Use async/await for sequential operations. (relevance: 94%)\n\n2. Structured concurrency ensures child tasks complete. (relevance: 87%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 2)
        #expect(entries[0].index == 1)
        #expect(entries[0].content.contains("async/await"))
        #expect(entries[0].relevance == 94)
        #expect(entries[1].index == 2)
        #expect(entries[1].relevance == 87)
    }

    @Test("Parses entries without relevance")
    func testWithoutRelevance() {
        let result = "1. First entry content\n\n2. Second entry content"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 2)
        #expect(entries[0].index == 1)
        #expect(entries[0].content == "First entry content")
        #expect(entries[0].relevance == nil)
        #expect(entries[1].index == 2)
        #expect(entries[1].content == "Second entry content")
        #expect(entries[1].relevance == nil)
    }

    @Test("Handles single entry")
    func testSingleEntry() {
        let result = "1. Only one result here. (relevance: 50%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(entries[0].index == 1)
        #expect(entries[0].relevance == 50)
    }

    @Test("Returns empty for unparseable content")
    func testUnparseable() {
        let result = "Some raw text without numbered entries"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)
        #expect(entries.isEmpty)
    }

    @Test("Returns empty for empty string")
    func testEmpty() {
        let entries = RememberDetailParser.parseMemoryEntries(from: "")
        #expect(entries.isEmpty)
    }

    @Test("Strips relevance from content string")
    func testStripsRelevance() {
        let result = "1. Some memory content here (relevance: 75%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(!entries[0].content.contains("relevance"))
        #expect(!entries[0].content.contains("%"))
    }

    @Test("Truncates very long content")
    func testTruncation() {
        let longContent = String(repeating: "a", count: 600)
        let result = "1. \(longContent)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(entries[0].content.count <= 503) // 500 + "..."
        #expect(entries[0].content.hasSuffix("..."))
    }

    @Test("Strips <mark> tags from content")
    func testStripsMarkTags() {
        let result = "1. <mark>Research</mark> the latest <mark>news</mark> on <mark>gold</mark> <mark>prices</mark> (relevance: 88%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(entries[0].content == "Research the latest news on gold prices")
        #expect(!entries[0].content.contains("<mark>"))
        #expect(!entries[0].content.contains("</mark>"))
        #expect(entries[0].relevance == 88)
    }

    @Test("Extracts thinking text from JSON array entries")
    func testExtractsThinkingFromJSON() {
        let json = "[{\"signature\":\"EqwECkYICxgCKk...\",\"thinking\":\"The user wants to know about Swift concurrency\",\"type\":\"thinking\"}]"
        let result = "1. \(json) (relevance: 92%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(entries[0].content == "The user wants to know about Swift concurrency")
        #expect(!entries[0].content.contains("signature"))
        #expect(!entries[0].content.contains("EqwECk"))
        #expect(entries[0].relevance == 92)
    }

    @Test("Extracts thinking and strips mark tags from JSON entries")
    func testExtractsThinkingAndStripsMark() {
        let json = "[{\"signature\":\"abc\",\"thinking\":\"Let me <mark>research</mark> the <mark>gold</mark> market\",\"type\":\"thinking\"}]"
        let result = "1. \(json) (relevance: 85%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(entries[0].content == "Let me research the gold market")
        #expect(entries[0].relevance == 85)
    }

    @Test("Strips line number prefixes from content")
    func testStripsLineNumbers() {
        let result = "1. 31->import SwiftUI\n32->import Foundation (relevance: 18%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(!entries[0].content.contains("31->"))
        #expect(!entries[0].content.contains("32->"))
        #expect(entries[0].content.contains("import SwiftUI"))
    }

    @Test("Falls back to raw content when JSON is invalid")
    func testInvalidJSONFallback() {
        let result = "1. [{broken json (relevance: 50%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)

        #expect(entries.count == 1)
        #expect(entries[0].content == "[{broken json")
    }
}

// MARK: - Session Parsing Tests

@Suite("RememberDetailParser.parseSessions")
struct RememberSessionParsingTests {

    @Test("Parses session lines with all fields")
    func testFullSessionLine() {
        let result = "- sess_abc123 | TypeScript Refactor | 2026-02-15T10:30:00Z\n- sess_def456 | Bug Fix | 2026-02-14T14:22:00Z"
        let sessions = RememberDetailParser.parseSessions(from: result)

        #expect(sessions.count == 2)
        #expect(sessions[0].sessionId == "sess_abc123")
        #expect(sessions[0].title == "TypeScript Refactor")
        #expect(sessions[0].date == "2026-02-15T10:30:00Z")
        #expect(sessions[1].sessionId == "sess_def456")
        #expect(sessions[1].title == "Bug Fix")
    }

    @Test("Handles session with only ID")
    func testIdOnly() {
        let result = "- sess_abc123"
        let sessions = RememberDetailParser.parseSessions(from: result)

        #expect(sessions.count == 1)
        #expect(sessions[0].sessionId == "sess_abc123")
        #expect(sessions[0].title == "")
        #expect(sessions[0].date == "")
    }

    @Test("Handles session with ID and title only")
    func testIdAndTitle() {
        let result = "- sess_abc | My Session"
        let sessions = RememberDetailParser.parseSessions(from: result)

        #expect(sessions.count == 1)
        #expect(sessions[0].sessionId == "sess_abc")
        #expect(sessions[0].title == "My Session")
        #expect(sessions[0].date == "")
    }

    @Test("Skips non-session lines")
    func testSkipsNonSessionLines() {
        let result = "Some header text\n- sess_abc | Title | Date\nSome footer text"
        let sessions = RememberDetailParser.parseSessions(from: result)

        #expect(sessions.count == 1)
    }

    @Test("Returns empty for no sessions")
    func testEmpty() {
        let sessions = RememberDetailParser.parseSessions(from: "No sessions found")
        #expect(sessions.isEmpty)
    }
}

// MARK: - JSON Entry Parsing Tests

@Suite("RememberDetailParser.parseJSONEntries")
struct RememberJSONEntryParsingTests {

    @Test("Splits entries by --- separator")
    func testSplitBySeparator() {
        let result = "{\"id\": \"evt_1\", \"type\": \"tool.result\"}\n---\n{\"id\": \"evt_2\", \"type\": \"message\"}"
        let entries = RememberDetailParser.parseJSONEntries(from: result)

        #expect(entries.count == 2)
        #expect(entries[0].contains("evt_1"))
        #expect(entries[1].contains("evt_2"))
    }

    @Test("Handles single entry without separator")
    func testSingleEntry() {
        let result = "{\"id\": \"evt_1\", \"type\": \"tool.result\"}"
        let entries = RememberDetailParser.parseJSONEntries(from: result)

        #expect(entries.count == 1)
    }

    @Test("Filters empty entries")
    func testFiltersEmpty() {
        let result = "{\"id\": \"1\"}\n---\n\n---\n{\"id\": \"2\"}"
        let entries = RememberDetailParser.parseJSONEntries(from: result)

        #expect(entries.count == 2)
    }

    @Test("Trims whitespace from entries")
    func testTrimsWhitespace() {
        let result = "  {\"id\": \"1\"}  \n---\n  {\"id\": \"2\"}  "
        let entries = RememberDetailParser.parseJSONEntries(from: result)

        #expect(entries.count == 2)
        #expect(entries[0] == "{\"id\": \"1\"}")
        #expect(entries[1] == "{\"id\": \"2\"}")
    }

    @Test("Returns empty for empty string")
    func testEmpty() {
        let entries = RememberDetailParser.parseJSONEntries(from: "")
        #expect(entries.isEmpty)
    }
}

// MARK: - Stats Parsing Tests

@Suite("RememberDetailParser.parseStats")
struct RememberStatsParsingTests {

    @Test("Parses full stats JSON")
    func testFullStats() {
        let result = "{\"sessions\": 127, \"events\": 4235, \"totalTokens\": 892150, \"totalCost\": \"$2.35\"}"
        let stats = RememberDetailParser.parseStats(from: result)

        #expect(stats.count == 4)

        let keys = stats.map { $0.key }
        #expect(keys.contains("sessions"))
        #expect(keys.contains("events"))
        #expect(keys.contains("tokens"))
        #expect(keys.contains("cost"))

        let sessionsEntry = stats.first { $0.key == "sessions" }
        #expect(sessionsEntry?.value == "127")
        #expect(sessionsEntry?.label == "Sessions")
    }

    @Test("Formats large token counts")
    func testLargeTokenCount() {
        let result = "{\"totalTokens\": 1500000}"
        let stats = RememberDetailParser.parseStats(from: result)

        let tokenEntry = stats.first { $0.key == "tokens" }
        #expect(tokenEntry?.value == "1.5M")
    }

    @Test("Formats medium token counts with K suffix")
    func testMediumTokenCount() {
        let result = "{\"totalTokens\": 5200}"
        let stats = RememberDetailParser.parseStats(from: result)

        let tokenEntry = stats.first { $0.key == "tokens" }
        #expect(tokenEntry?.value == "5.2K")
    }

    @Test("Returns empty for invalid JSON")
    func testInvalidJSON() {
        let stats = RememberDetailParser.parseStats(from: "not json")
        #expect(stats.isEmpty)
    }

    @Test("Returns empty for empty string")
    func testEmpty() {
        let stats = RememberDetailParser.parseStats(from: "")
        #expect(stats.isEmpty)
    }

    @Test("Handles partial stats")
    func testPartialStats() {
        let result = "{\"sessions\": 42}"
        let stats = RememberDetailParser.parseStats(from: result)

        #expect(stats.count == 1)
        #expect(stats[0].key == "sessions")
        #expect(stats[0].value == "42")
    }
}

// MARK: - Error Detection Tests

@Suite("RememberDetailParser.ErrorDetection")
struct RememberErrorDetectionTests {

    @Test("Detects 'Error:' prefix")
    func testErrorPrefix() {
        #expect(RememberDetailParser.isError("Error: database unavailable") == true)
    }

    @Test("Detects 'Invalid action' prefix")
    func testInvalidAction() {
        #expect(RememberDetailParser.isError("Invalid action: xyz") == true)
    }

    @Test("Detects 'Missing required' prefix")
    func testMissingRequired() {
        #expect(RememberDetailParser.isError("Missing required parameter: session_id") == true)
    }

    @Test("Detects 'Failed to' prefix")
    func testFailedTo() {
        #expect(RememberDetailParser.isError("Failed to query database") == true)
    }

    @Test("Detects JSON error field")
    func testJSONError() {
        #expect(RememberDetailParser.isError("{\"error\": \"timeout\"}") == true)
    }

    @Test("Returns false for normal results")
    func testNormalResult() {
        #expect(RememberDetailParser.isError("1. Some memory content (relevance: 85%)") == false)
    }
}

// MARK: - No Results Detection Tests

@Suite("RememberDetailParser.NoResultsDetection")
struct RememberNoResultsDetectionTests {

    @Test("Detects 'No results found.' with period")
    func testWithPeriod() {
        #expect(RememberDetailParser.isNoResults("No results found.") == true)
    }

    @Test("Detects 'No results found' without period")
    func testWithoutPeriod() {
        #expect(RememberDetailParser.isNoResults("No results found") == true)
    }

    @Test("Handles whitespace padding")
    func testWhitespace() {
        #expect(RememberDetailParser.isNoResults("  No results found.  ") == true)
    }

    @Test("Returns false for actual results")
    func testActualResults() {
        #expect(RememberDetailParser.isNoResults("1. Found something") == false)
    }
}

// MARK: - Error Classification Tests

@Suite("RememberDetailParser.classifyError")
struct RememberErrorClassificationTests {

    @Test("Classifies invalid action")
    func testInvalidAction() {
        let info = RememberDetailParser.classifyError("Invalid action: xyz")
        #expect(info.title == "Invalid Action")
        #expect(info.code == "INVALID_ACTION")
    }

    @Test("Classifies missing parameter")
    func testMissingParam() {
        let info = RememberDetailParser.classifyError("Missing required parameter: session_id")
        #expect(info.title == "Missing Parameter")
        #expect(info.code == "MISSING_PARAM")
    }

    @Test("Classifies not found")
    func testNotFound() {
        let info = RememberDetailParser.classifyError("Session not found: sess_abc")
        #expect(info.title == "Not Found")
        #expect(info.code == nil)
    }

    @Test("Classifies not available")
    func testNotAvailable() {
        let info = RememberDetailParser.classifyError("Feature not available in this backend")
        #expect(info.title == "Not Available")
        #expect(info.code == nil)
    }

    @Test("Classifies generic error")
    func testGeneric() {
        let info = RememberDetailParser.classifyError("Something unexpected happened")
        #expect(info.title == "Query Failed")
        #expect(info.code == nil)
    }
}

// MARK: - Date Formatting Tests

@Suite("RememberDetailParser.formatDate")
struct RememberDateFormattingTests {

    @Test("Formats ISO 8601 date with fractional seconds")
    func testFractionalSeconds() {
        let formatted = RememberDetailParser.formatDate("2026-02-15T10:30:00.123Z")
        #expect(!formatted.isEmpty)
        #expect(formatted != "2026-02-15T10:30:00.123Z")
        #expect(formatted.contains("2026"))
    }

    @Test("Formats ISO 8601 date without fractional seconds")
    func testWithoutFractionalSeconds() {
        let formatted = RememberDetailParser.formatDate("2026-02-15T10:30:00Z")
        #expect(!formatted.isEmpty)
        #expect(formatted != "2026-02-15T10:30:00Z")
    }

    @Test("Returns raw string for unparseable date")
    func testUnparseable() {
        let input = "not-a-date"
        let formatted = RememberDetailParser.formatDate(input)
        #expect(formatted == input)
    }
}
