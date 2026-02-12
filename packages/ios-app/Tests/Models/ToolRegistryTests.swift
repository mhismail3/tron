import Testing
import Foundation
import SwiftUI
@testable import TronMobile

@Suite("ToolRegistry Tests")
struct ToolRegistryTests {

    // MARK: - Icon and Display Name Tests

    @Test("Read tool has correct icon and display name")
    func testReadDescriptor() {
        let d = ToolRegistry.descriptor(for: "read")
        #expect(d.icon == "doc.text")
        #expect(d.displayName == "Read")
    }

    @Test("Write tool has correct icon and display name")
    func testWriteDescriptor() {
        let d = ToolRegistry.descriptor(for: "write")
        #expect(d.icon == "doc.badge.plus")
        #expect(d.displayName == "Write")
    }

    @Test("Edit tool has correct icon and display name")
    func testEditDescriptor() {
        let d = ToolRegistry.descriptor(for: "edit")
        #expect(d.icon == "pencil.line")
        #expect(d.displayName == "Edit")
    }

    @Test("Bash tool has correct icon and display name")
    func testBashDescriptor() {
        let d = ToolRegistry.descriptor(for: "bash")
        #expect(d.icon == "terminal")
        #expect(d.displayName == "Bash")
    }

    @Test("Search tool has correct icon and display name")
    func testSearchDescriptor() {
        let d = ToolRegistry.descriptor(for: "search")
        #expect(d.icon == "magnifyingglass")
        #expect(d.displayName == "Search")
    }

    @Test("Glob tool has correct icon and display name")
    func testGlobDescriptor() {
        let d = ToolRegistry.descriptor(for: "glob")
        #expect(d.icon == "doc.text.magnifyingglass")
        #expect(d.displayName == "Glob")
    }

    @Test("Find tool has correct icon and display name")
    func testFindDescriptor() {
        let d = ToolRegistry.descriptor(for: "find")
        #expect(d.icon == "doc.text.magnifyingglass")
        #expect(d.displayName == "Find")
    }

    @Test("BrowseTheWeb tool has correct icon and display name")
    func testBrowseTheWebDescriptor() {
        let d = ToolRegistry.descriptor(for: "browsetheweb")
        #expect(d.icon == "globe")
        #expect(d.displayName == "Browse")
    }

    @Test("OpenURL tool has correct icon and display name")
    func testOpenURLDescriptor() {
        let d = ToolRegistry.descriptor(for: "openurl")
        #expect(d.icon == "safari")
        #expect(d.displayName == "Open URL")
    }

    @Test("WebFetch tool has correct icon and display name")
    func testWebFetchDescriptor() {
        let d = ToolRegistry.descriptor(for: "webfetch")
        #expect(d.icon == "arrow.down.doc")
        #expect(d.displayName == "Fetch")
    }

    @Test("WebSearch tool has correct icon and display name")
    func testWebSearchDescriptor() {
        let d = ToolRegistry.descriptor(for: "websearch")
        #expect(d.icon == "magnifyingglass.circle")
        #expect(d.displayName == "Search")
    }

    @Test("Task tool has correct icon and display name")
    func testTaskDescriptor() {
        let d = ToolRegistry.descriptor(for: "task")
        #expect(d.icon == "arrow.triangle.branch")
        #expect(d.displayName == "Task")
    }

    @Test("Remember tool has correct icon and display name")
    func testRememberDescriptor() {
        let d = ToolRegistry.descriptor(for: "remember")
        #expect(d.icon == "brain.fill")
        #expect(d.displayName == "Remember")
    }

    @Test("Unknown tool gets default descriptor")
    func testUnknownDescriptor() {
        let d = ToolRegistry.descriptor(for: "unknowntool")
        #expect(d.icon == "gearshape")
        #expect(d.displayName == "Unknowntool")
    }

    @Test("Lookup is case-insensitive")
    func testCaseInsensitive() {
        let d1 = ToolRegistry.descriptor(for: "READ")
        let d2 = ToolRegistry.descriptor(for: "Read")
        let d3 = ToolRegistry.descriptor(for: "read")
        #expect(d1.displayName == d2.displayName)
        #expect(d2.displayName == d3.displayName)
    }

    // MARK: - Summary Extractor Tests

    @Test("Read summary extracts shortened file path")
    func testReadSummary() {
        let d = ToolRegistry.descriptor(for: "read")
        let summary = d.summaryExtractor("{\"file_path\": \"/Users/test/example.swift\"}")
        #expect(summary == "example.swift")
    }

    @Test("Write summary extracts shortened file path")
    func testWriteSummary() {
        let d = ToolRegistry.descriptor(for: "write")
        let summary = d.summaryExtractor("{\"file_path\": \"/path/to/config.json\"}")
        #expect(summary == "config.json")
    }

    @Test("Edit summary extracts shortened file path")
    func testEditSummary() {
        let d = ToolRegistry.descriptor(for: "edit")
        let summary = d.summaryExtractor("{\"file_path\": \"/path/to/server.py\"}")
        #expect(summary == "server.py")
    }

    @Test("Bash summary extracts and truncates command")
    func testBashSummary() {
        let d = ToolRegistry.descriptor(for: "bash")
        let summary = d.summaryExtractor("{\"command\": \"git status --short\"}")
        #expect(summary == "git status --short")
    }

    @Test("Bash summary truncates long commands")
    func testBashSummaryLong() {
        let d = ToolRegistry.descriptor(for: "bash")
        let longCmd = String(repeating: "x", count: 100)
        let summary = d.summaryExtractor("{\"command\": \"\(longCmd)\"}")
        #expect(summary.count <= 43)
        #expect(summary.hasSuffix("..."))
    }

    @Test("Search summary includes pattern and path")
    func testSearchSummaryWithPath() {
        let d = ToolRegistry.descriptor(for: "search")
        let summary = d.summaryExtractor("{\"pattern\": \"TODO\", \"path\": \"./src\"}")
        #expect(summary == "\"TODO\" in src")
    }

    @Test("Search summary pattern only when path is dot")
    func testSearchSummaryDotPath() {
        let d = ToolRegistry.descriptor(for: "search")
        let summary = d.summaryExtractor("{\"pattern\": \"TODO\", \"path\": \".\"}")
        #expect(summary == "\"TODO\"")
    }

    @Test("Find/Glob summary extracts pattern")
    func testFindGlobSummary() {
        let d = ToolRegistry.descriptor(for: "glob")
        let summary = d.summaryExtractor("{\"pattern\": \"**/*.swift\"}")
        #expect(summary == "**/*.swift")
    }

    @Test("BrowseTheWeb summary extracts navigate action with URL")
    func testBrowseNavigateSummary() {
        let d = ToolRegistry.descriptor(for: "browsetheweb")
        let summary = d.summaryExtractor("{\"action\": \"navigate\", \"url\": \"https://example.com\"}")
        #expect(summary == "navigate: https://example.com")
    }

    @Test("BrowseTheWeb summary extracts click action with selector")
    func testBrowseClickSummary() {
        let d = ToolRegistry.descriptor(for: "browsetheweb")
        let summary = d.summaryExtractor("{\"action\": \"click\", \"selector\": \"#submit\"}")
        #expect(summary == "click: #submit")
    }

    @Test("OpenURL summary extracts and truncates URL")
    func testOpenURLSummary() {
        let d = ToolRegistry.descriptor(for: "openurl")
        let summary = d.summaryExtractor("{\"url\": \"https://example.com\"}")
        #expect(summary == "https://example.com")
    }

    @Test("OpenURL summary truncates long URLs")
    func testOpenURLSummaryLong() {
        let d = ToolRegistry.descriptor(for: "openurl")
        let longUrl = "https://example.com/" + String(repeating: "x", count: 100)
        let summary = d.summaryExtractor("{\"url\": \"\(longUrl)\"}")
        #expect(summary.count <= 53)
        #expect(summary.hasSuffix("..."))
    }

    @Test("WebFetch summary shows domain and prompt")
    func testWebFetchSummary() {
        let d = ToolRegistry.descriptor(for: "webfetch")
        let summary = d.summaryExtractor("{\"url\": \"https://docs.anthropic.com/overview\", \"prompt\": \"What models?\"}")
        #expect(summary.contains("docs.anthropic.com"))
        #expect(summary.contains("What models?"))
    }

    @Test("WebFetch summary shows domain only when no prompt")
    func testWebFetchSummaryNoPrompt() {
        let d = ToolRegistry.descriptor(for: "webfetch")
        let summary = d.summaryExtractor("{\"url\": \"https://example.com\"}")
        #expect(summary == "example.com")
    }

    @Test("WebSearch summary shows quoted query")
    func testWebSearchSummary() {
        let d = ToolRegistry.descriptor(for: "websearch")
        let summary = d.summaryExtractor("{\"query\": \"Swift async await\"}")
        #expect(summary == "\"Swift async await\"")
    }

    @Test("WebSearch summary truncates long queries")
    func testWebSearchSummaryLong() {
        let d = ToolRegistry.descriptor(for: "websearch")
        let longQuery = String(repeating: "x", count: 100)
        let summary = d.summaryExtractor("{\"query\": \"\(longQuery)\"}")
        #expect(summary.contains("..."))
    }

    @Test("Task summary extracts description")
    func testTaskSummary() {
        let d = ToolRegistry.descriptor(for: "task")
        let summary = d.summaryExtractor("{\"description\": \"Search for config files\"}")
        #expect(summary == "Search for config files")
    }

    @Test("Task summary falls back to prompt")
    func testTaskSummaryFallback() {
        let d = ToolRegistry.descriptor(for: "task")
        let summary = d.summaryExtractor("{\"prompt\": \"Do the thing\"}")
        #expect(summary == "Do the thing")
    }

    @Test("Unknown tool summary is empty")
    func testUnknownSummary() {
        let d = ToolRegistry.descriptor(for: "unknowntool")
        let summary = d.summaryExtractor("{\"anything\": \"value\"}")
        #expect(summary == "")
    }

    // MARK: - Tool Set Tests

    @Test("commandToolNames contains all expected tools")
    func testCommandToolNames() {
        let expected: Set<String> = ["read", "write", "edit", "bash", "search", "glob", "find", "browsetheweb", "openurl", "webfetch", "websearch", "task", "remember"]
        #expect(ToolRegistry.commandToolNames == expected)
    }

    @Test("isCommandTool returns true for command tools")
    func testIsCommandTool() {
        #expect(ToolRegistry.isCommandTool("read"))
        #expect(ToolRegistry.isCommandTool("bash"))
        #expect(ToolRegistry.isCommandTool("Read")) // case insensitive
    }

    @Test("isCommandTool returns false for special tools")
    func testIsCommandToolFalse() {
        #expect(!ToolRegistry.isCommandTool("askuserquestion"))
        #expect(!ToolRegistry.isCommandTool("spawnsubagent"))
        #expect(!ToolRegistry.isCommandTool("renderappui"))
        #expect(!ToolRegistry.isCommandTool("taskmanager"))
    }

    // MARK: - Viewer Factory Tests

    @Test("Command tools have viewer factories")
    func testViewerFactories() {
        for name in ["read", "write", "edit", "bash", "search", "find", "glob", "browsetheweb", "openurl", "webfetch", "websearch"] {
            let d = ToolRegistry.descriptor(for: name)
            #expect(d.viewerFactory != nil, "Expected viewer factory for \(name)")
        }
    }

    @Test("Special tools without expanded view have nil viewer factory")
    func testSpecialToolsNilFactory() {
        let d = ToolRegistry.descriptor(for: "askuserquestion")
        #expect(d.viewerFactory == nil)
    }

    @Test("Unknown tools have nil viewer factory")
    func testUnknownToolNilFactory() {
        let d = ToolRegistry.descriptor(for: "unknowntool")
        #expect(d.viewerFactory == nil)
    }
}
