import Testing
import Foundation
@testable import TronMobile

@Suite("RememberDetailParser")
struct RememberDetailParserTests {

    // MARK: - Action Category

    @Test("actionCategory returns memorySearch for recall and search")
    func actionCategoryMemory() {
        #expect(RememberDetailParser.actionCategory(from: "recall") == .memorySearch)
        #expect(RememberDetailParser.actionCategory(from: "search") == .memorySearch)
        #expect(RememberDetailParser.actionCategory(from: "memory") == .memorySearch)
    }

    @Test("actionCategory returns sessionList for sessions")
    func actionCategorySessionList() {
        #expect(RememberDetailParser.actionCategory(from: "sessions") == .sessionList)
    }

    @Test("actionCategory returns sessionDetail for session")
    func actionCategorySessionDetail() {
        #expect(RememberDetailParser.actionCategory(from: "session") == .sessionDetail)
    }

    @Test("actionCategory returns eventQuery for events, messages, tools, logs")
    func actionCategoryEvents() {
        #expect(RememberDetailParser.actionCategory(from: "events") == .eventQuery)
        #expect(RememberDetailParser.actionCategory(from: "messages") == .eventQuery)
        #expect(RememberDetailParser.actionCategory(from: "tools") == .eventQuery)
        #expect(RememberDetailParser.actionCategory(from: "logs") == .eventQuery)
    }

    @Test("actionCategory returns dbStats for stats")
    func actionCategoryStats() {
        #expect(RememberDetailParser.actionCategory(from: "stats") == .dbStats)
    }

    @Test("actionCategory returns dbSchema for schema")
    func actionCategorySchema() {
        #expect(RememberDetailParser.actionCategory(from: "schema") == .dbSchema)
    }

    @Test("actionCategory returns memorySearch for unknown action")
    func actionCategoryUnknown() {
        #expect(RememberDetailParser.actionCategory(from: "unknown_action") == .memorySearch)
    }

    // MARK: - Error Detection

    @Test("isError detects error strings")
    func isErrorDetection() {
        #expect(RememberDetailParser.isError("Error: something went wrong"))
        #expect(RememberDetailParser.isError("Invalid action: foo"))
        #expect(RememberDetailParser.isError("Missing required parameter"))
        #expect(RememberDetailParser.isError("Failed to connect"))
        #expect(RememberDetailParser.isError("{\"error\": \"bad request\"}"))
    }

    @Test("isError returns false for valid results")
    func isErrorFalseForValid() {
        #expect(!RememberDetailParser.isError("1. Memory entry content"))
        #expect(!RememberDetailParser.isError("- session_abc | My Session | 2024-01-01"))
        #expect(!RememberDetailParser.isError("No results found."))
    }

    @Test("isNoResults detects empty result strings")
    func isNoResults() {
        #expect(RememberDetailParser.isNoResults("No results found."))
        #expect(RememberDetailParser.isNoResults("No results found"))
        #expect(RememberDetailParser.isNoResults("  No results found.  "))
    }

    @Test("isNoResults returns false for actual results")
    func isNoResultsFalse() {
        #expect(!RememberDetailParser.isNoResults("1. Some memory entry"))
        #expect(!RememberDetailParser.isNoResults(""))
    }

    // MARK: - Memory Entry Parsing

    @Test("parseMemoryEntries returns correct entry count")
    func parseMemoryEntriesCount() {
        let result = """
        1. First memory entry (relevance: 95%)

        2. Second memory entry (relevance: 80%)

        3. Third memory entry
        """
        let entries = RememberDetailParser.parseMemoryEntries(from: result)
        #expect(entries.count == 3)
    }

    @Test("parseMemoryEntries extracts relevance correctly")
    func parseMemoryEntriesRelevance() {
        let result = "1. Some content (relevance: 92%)"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)
        #expect(entries.count == 1)
        #expect(entries[0].relevance == 92)
        #expect(entries[0].index == 1)
    }

    @Test("parseMemoryEntries handles entry without relevance")
    func parseMemoryEntriesNoRelevance() {
        let result = "1. Content without relevance score"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)
        #expect(entries.count == 1)
        #expect(entries[0].relevance == nil)
    }

    @Test("parseMemoryEntries handles empty string")
    func parseMemoryEntriesEmpty() {
        let entries = RememberDetailParser.parseMemoryEntries(from: "")
        #expect(entries.isEmpty)
    }

    @Test("parseMemoryEntries handles malformed input gracefully")
    func parseMemoryEntriesMalformed() {
        let result = "This is not a numbered list\nJust random text"
        let entries = RememberDetailParser.parseMemoryEntries(from: result)
        #expect(entries.isEmpty)
    }

    // MARK: - Session Parsing

    @Test("parseSessions parses valid session list")
    func parseSessionsValid() {
        let result = """
        - session_abc | My Project | 2024-01-15
        - session_def | Another Session | 2024-01-16
        """
        let sessions = RememberDetailParser.parseSessions(from: result)
        #expect(sessions.count == 2)
        #expect(sessions[0].sessionId == "session_abc")
        #expect(sessions[0].title == "My Project")
        #expect(sessions[1].sessionId == "session_def")
    }

    @Test("parseSessions handles missing fields")
    func parseSessionsMissingFields() {
        let result = "- session_abc"
        let sessions = RememberDetailParser.parseSessions(from: result)
        #expect(sessions.count == 1)
        #expect(sessions[0].sessionId == "session_abc")
        #expect(sessions[0].title == "")
    }

    @Test("parseSessions returns empty for non-list input")
    func parseSessionsEmpty() {
        let sessions = RememberDetailParser.parseSessions(from: "No sessions found")
        #expect(sessions.isEmpty)
    }

    // MARK: - Error Classification

    @Test("classifyError returns Invalid Action for invalid action")
    func classifyErrorInvalidAction() {
        let result = RememberDetailParser.classifyError("Invalid action: foobar")
        #expect(result.code == "INVALID_ACTION")
    }

    @Test("classifyError returns Missing Parameter for missing session_id")
    func classifyErrorMissingParam() {
        let result = RememberDetailParser.classifyError("Missing required session_id parameter")
        #expect(result.code == "MISSING_PARAM")
    }

    @Test("classifyError returns Not Found for not found errors")
    func classifyErrorNotFound() {
        let result = RememberDetailParser.classifyError("Session not found")
        #expect(result.title == "Not Found")
    }

    @Test("classifyError returns generic for unknown errors")
    func classifyErrorGeneric() {
        let result = RememberDetailParser.classifyError("Something completely unexpected")
        #expect(result.title == "Query Failed")
    }

    // MARK: - Stats Parsing

    @Test("parseStats parses valid JSON")
    func parseStatsValid() {
        let json = """
        {"sessions": 42, "events": 1500, "totalTokens": 250000}
        """
        let stats = RememberDetailParser.parseStats(from: json)
        #expect(stats.count == 3)
        #expect(stats[0].label == "Sessions")
        #expect(stats[0].value == "42")
    }

    @Test("parseStats returns empty for invalid JSON")
    func parseStatsInvalidJSON() {
        let stats = RememberDetailParser.parseStats(from: "not json")
        #expect(stats.isEmpty)
    }
}
