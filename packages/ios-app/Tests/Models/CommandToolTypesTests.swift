import Testing
import Foundation
import SwiftUI
@testable import TronMobile

/// Tests for CommandToolTypes
/// Verifies data model, status enum, and tool registry
@Suite("CommandToolTypes Tests")
struct CommandToolTypesTests {

    // MARK: - CommandToolStatus Tests

    @Test("CommandToolStatus cases are equatable")
    func testCommandToolStatusEquatable() {
        #expect(CommandToolStatus.running == CommandToolStatus.running)
        #expect(CommandToolStatus.success == CommandToolStatus.success)
        #expect(CommandToolStatus.error == CommandToolStatus.error)
        #expect(CommandToolStatus.running != CommandToolStatus.success)
    }

    // MARK: - CommandToolChipData Tests

    @Test("CommandToolChipData stores all fields correctly")
    func testCommandToolChipDataFields() {
        let data = CommandToolChipData(
            id: "call_123",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "example.swift",
            status: .success,
            durationMs: 45,
            arguments: "{\"file_path\": \"/path/to/file.swift\"}",
            result: "file contents here",
            isResultTruncated: false
        )

        #expect(data.id == "call_123")
        #expect(data.toolName == "Read")
        #expect(data.normalizedName == "read")
        #expect(data.icon == "doc.text")
        #expect(data.displayName == "Read")
        #expect(data.summary == "example.swift")
        #expect(data.status == .success)
        #expect(data.durationMs == 45)
        #expect(data.arguments == "{\"file_path\": \"/path/to/file.swift\"}")
        #expect(data.result == "file contents here")
        #expect(data.isResultTruncated == false)
    }

    @Test("CommandToolChipData is Identifiable using id")
    func testCommandToolChipDataIdentifiable() {
        let data = CommandToolChipData(
            id: "unique_id",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .green,
            displayName: "Bash",
            summary: "git status",
            status: .running,
            durationMs: nil,
            arguments: "{}",
            result: nil,
            isResultTruncated: false
        )

        // id property should match the id passed in
        #expect(data.id == "unique_id")
    }

    @Test("CommandToolChipData is Equatable")
    func testCommandToolChipDataEquatable() {
        let data1 = CommandToolChipData(
            id: "call_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: "content",
            isResultTruncated: false
        )

        let data2 = CommandToolChipData(
            id: "call_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: "content",
            isResultTruncated: false
        )

        let data3 = CommandToolChipData(
            id: "call_2",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: "content",
            isResultTruncated: false
        )

        #expect(data1 == data2)
        #expect(data1 != data3)
    }

    @Test("CommandToolChipData handles nil optional fields")
    func testCommandToolChipDataNilOptionals() {
        let data = CommandToolChipData(
            id: "call_1",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .green,
            displayName: "Bash",
            summary: "running...",
            status: .running,
            durationMs: nil,
            arguments: "{}",
            result: nil,
            isResultTruncated: false
        )

        #expect(data.durationMs == nil)
        #expect(data.result == nil)
    }

    // MARK: - CommandToolRegistry Tests

    @Test("Registry returns correct config for Read tool")
    func testRegistryReadConfig() {
        let config = CommandToolRegistry.config(for: "read")

        #expect(config.icon == "doc.text")
        #expect(config.displayName == "Read")
    }

    @Test("Registry returns correct config for Write tool")
    func testRegistryWriteConfig() {
        let config = CommandToolRegistry.config(for: "write")

        #expect(config.icon == "doc.badge.plus")
        #expect(config.displayName == "Write")
    }

    @Test("Registry returns correct config for Edit tool")
    func testRegistryEditConfig() {
        let config = CommandToolRegistry.config(for: "edit")

        #expect(config.icon == "pencil.line")
        #expect(config.displayName == "Edit")
    }

    @Test("Registry returns correct config for Bash tool")
    func testRegistryBashConfig() {
        let config = CommandToolRegistry.config(for: "bash")

        #expect(config.icon == "terminal")
        #expect(config.displayName == "Bash")
    }

    @Test("Registry returns correct config for Grep tool")
    func testRegistryGrepConfig() {
        let config = CommandToolRegistry.config(for: "grep")

        #expect(config.icon == "magnifyingglass")
        #expect(config.displayName == "Grep")
    }

    @Test("Registry returns correct config for Glob tool")
    func testRegistryGlobConfig() {
        let config = CommandToolRegistry.config(for: "glob")

        #expect(config.icon == "doc.text.magnifyingglass")
        #expect(config.displayName == "Glob")
    }

    @Test("Registry returns correct config for Find tool")
    func testRegistryFindConfig() {
        let config = CommandToolRegistry.config(for: "find")

        #expect(config.icon == "doc.text.magnifyingglass")
        #expect(config.displayName == "Find")
    }

    @Test("Registry returns correct config for Ls tool")
    func testRegistryLsConfig() {
        let config = CommandToolRegistry.config(for: "ls")

        #expect(config.icon == "folder")
        #expect(config.displayName == "Ls")
    }

    @Test("Registry returns correct config for Browser tool")
    func testRegistryBrowserConfig() {
        let config = CommandToolRegistry.config(for: "browser")

        #expect(config.icon == "globe")
        #expect(config.displayName == "Browser")
    }

    @Test("Registry returns correct config for Search tool")
    func testRegistrySearchConfig() {
        let config = CommandToolRegistry.config(for: "search")

        #expect(config.icon == "magnifyingglass")
        #expect(config.displayName == "Search")
    }

    @Test("Registry returns correct config for OpenURL tool")
    func testRegistryOpenURLConfig() {
        let config = CommandToolRegistry.config(for: "openurl")

        #expect(config.icon == "safari")
        #expect(config.displayName == "Open URL")
    }

    @Test("Registry returns correct config for WebFetch tool")
    func testRegistryWebFetchConfig() {
        let config = CommandToolRegistry.config(for: "webfetch")

        #expect(config.icon == "arrow.down.doc")
        #expect(config.displayName == "WebFetch")
    }

    @Test("Registry returns correct config for WebSearch tool")
    func testRegistryWebSearchConfig() {
        let config = CommandToolRegistry.config(for: "websearch")

        #expect(config.icon == "magnifyingglass.circle")
        #expect(config.displayName == "WebSearch")
    }

    @Test("Registry returns correct config for Task tool")
    func testRegistryTaskConfig() {
        let config = CommandToolRegistry.config(for: "task")

        #expect(config.icon == "arrow.triangle.branch")
        #expect(config.displayName == "Task")
    }

    @Test("Registry returns fallback config for unknown tool")
    func testRegistryUnknownToolConfig() {
        let config = CommandToolRegistry.config(for: "unknowntool")

        #expect(config.icon == "gearshape")
        #expect(config.displayName == "Unknowntool")
    }

    @Test("Registry is case-insensitive")
    func testRegistryCaseInsensitive() {
        let config1 = CommandToolRegistry.config(for: "READ")
        let config2 = CommandToolRegistry.config(for: "Read")
        let config3 = CommandToolRegistry.config(for: "read")

        #expect(config1.displayName == config2.displayName)
        #expect(config2.displayName == config3.displayName)
    }

    @Test("Registry provides all command tool names")
    func testRegistryAllCommandTools() {
        let commandTools = CommandToolRegistry.allCommandTools

        // Should include all standard command tools
        #expect(commandTools.contains("read"))
        #expect(commandTools.contains("write"))
        #expect(commandTools.contains("edit"))
        #expect(commandTools.contains("bash"))
        #expect(commandTools.contains("search"))
        #expect(commandTools.contains("glob"))
        #expect(commandTools.contains("find"))
        #expect(commandTools.contains("browsetheweb"))
        #expect(commandTools.contains("openurl"))
        #expect(commandTools.contains("webfetch"))
        #expect(commandTools.contains("websearch"))
        #expect(commandTools.contains("task"))
    }

    @Test("Registry isCommandTool returns true for command tools")
    func testRegistryIsCommandToolTrue() {
        #expect(CommandToolRegistry.isCommandTool("read"))
        #expect(CommandToolRegistry.isCommandTool("bash"))
        #expect(CommandToolRegistry.isCommandTool("search"))
        #expect(CommandToolRegistry.isCommandTool("edit"))
    }

    @Test("Registry isCommandTool returns false for special tools")
    func testRegistryIsCommandToolFalse() {
        // These are handled specially and should NOT be command tools
        #expect(!CommandToolRegistry.isCommandTool("askuserquestion"))
        #expect(!CommandToolRegistry.isCommandTool("spawnsubagent"))
        #expect(!CommandToolRegistry.isCommandTool("waitforsubagent"))
        #expect(!CommandToolRegistry.isCommandTool("renderappui"))
        #expect(!CommandToolRegistry.isCommandTool("todowrite"))
        #expect(!CommandToolRegistry.isCommandTool("notifyapp"))
    }

    // MARK: - CommandToolChipData Factory Tests

    @Test("Factory creates chip data from ToolUseData for Read tool")
    func testFactoryCreatesReadChipData() {
        let toolUse = ToolUseData(
            toolName: "Read",
            toolCallId: "call_read_1",
            arguments: "{\"file_path\": \"/Users/test/example.swift\"}",
            status: .success,
            result: "import Foundation\nstruct Example {}",
            durationMs: 25
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.id == "call_read_1")
        #expect(chipData?.toolName == "Read")
        #expect(chipData?.normalizedName == "read")
        #expect(chipData?.displayName == "Read")
        #expect(chipData?.icon == "doc.text")
        #expect(chipData?.summary == "example.swift")
        #expect(chipData?.status == .success)
        #expect(chipData?.durationMs == 25)
    }

    @Test("Factory creates chip data from ToolUseData for Bash tool")
    func testFactoryCreatesBashChipData() {
        let toolUse = ToolUseData(
            toolName: "Bash",
            toolCallId: "call_bash_1",
            arguments: "{\"command\": \"git status --short\"}",
            status: .running,
            result: nil,
            durationMs: nil
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.normalizedName == "bash")
        #expect(chipData?.displayName == "Bash")
        #expect(chipData?.icon == "terminal")
        #expect(chipData?.summary == "git status --short")
        #expect(chipData?.status == .running)
    }

    @Test("Factory creates chip data with error status")
    func testFactoryCreatesErrorChipData() {
        let toolUse = ToolUseData(
            toolName: "Read",
            toolCallId: "call_error_1",
            arguments: "{\"file_path\": \"/nonexistent/file.txt\"}",
            status: .error,
            result: "Error: File not found",
            durationMs: 5
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.status == .error)
        #expect(chipData?.result == "Error: File not found")
    }

    @Test("Factory extracts Grep summary correctly")
    func testFactoryExtractsGrepSummary() {
        let toolUse = ToolUseData(
            toolName: "Grep",
            toolCallId: "call_grep_1",
            arguments: "{\"pattern\": \"TODO\", \"path\": \"./src\"}",
            status: .success,
            result: "Found 5 matches",
            durationMs: 100
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        // Summary should show pattern in path format
        #expect(chipData?.summary.contains("TODO") == true)
    }

    @Test("Factory extracts Edit summary correctly")
    func testFactoryExtractsEditSummary() {
        let toolUse = ToolUseData(
            toolName: "Edit",
            toolCallId: "call_edit_1",
            arguments: "{\"file_path\": \"/path/to/config.json\"}",
            status: .success,
            result: "Edited successfully",
            durationMs: 30
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.summary == "config.json")
    }

    @Test("Factory returns nil for special tools")
    func testFactoryReturnsNilForSpecialTools() {
        let toolUse = ToolUseData(
            toolName: "AskUserQuestion",
            toolCallId: "call_ask_1",
            arguments: "{}",
            status: .running,
            result: nil,
            durationMs: nil
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData == nil)
    }

    @Test("Factory truncates long commands in summary")
    func testFactoryTruncatesLongSummary() {
        let longCommand = String(repeating: "x", count: 100)
        let toolUse = ToolUseData(
            toolName: "Bash",
            toolCallId: "call_bash_long",
            arguments: "{\"command\": \"\(longCommand)\"}",
            status: .running,
            result: nil,
            durationMs: nil
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        // Summary should be truncated (40 chars + "...")
        #expect(chipData!.summary.count <= 43)
        #expect(chipData!.summary.hasSuffix("..."))
    }

    @Test("Factory unescapes JSON escaped paths correctly")
    func testFactoryUnescapesJSONPaths() {
        // JSON escapes forward slashes as \/
        let toolUse = ToolUseData(
            toolName: "Ls",
            toolCallId: "call_ls_1",
            arguments: "{\"path\": \"\\/Users\\/moose\\/Downloads\\/test\"}",
            status: .success,
            result: "file1.txt\nfile2.txt",
            durationMs: 44
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        // Summary should have unescaped slashes
        #expect(chipData?.summary == "/Users/moose/Downloads/test")
        #expect(!chipData!.summary.contains("\\/"))
    }

    @Test("Factory unescapes JSON escaped file paths for Read")
    func testFactoryUnescapesReadFilePath() {
        let toolUse = ToolUseData(
            toolName: "Read",
            toolCallId: "call_read_escaped",
            arguments: "{\"file_path\": \"\\/path\\/to\\/file.swift\"}",
            status: .success,
            result: "content",
            durationMs: 10
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        // Summary is shortened to filename only
        #expect(chipData?.summary == "file.swift")
    }

    @Test("Factory unescapes JSON escaped URLs")
    func testFactoryUnescapesURLs() {
        let toolUse = ToolUseData(
            toolName: "WebFetch",
            toolCallId: "call_webfetch_1",
            arguments: "{\"url\": \"https:\\/\\/example.com\\/path\\/to\\/page\"}",
            status: .success,
            result: "page content",
            durationMs: 200
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.summary == "https://example.com/path/to/page")
        #expect(!chipData!.summary.contains("\\/"))
    }
}

// MARK: - ChatSheet CommandTool Integration Tests

@Suite("ChatSheet CommandTool Tests")
struct ChatSheetCommandToolTests {

    @Test("CommandTool sheet has unique id per toolCallId")
    func testCommandToolSheetUniqueId() {
        let data1 = CommandToolChipData(
            id: "tool_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: "content",
            isResultTruncated: false
        )

        let data2 = CommandToolChipData(
            id: "tool_2",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: "content",
            isResultTruncated: false
        )

        let sheet1 = ChatSheet.commandToolDetail(data1)
        let sheet2 = ChatSheet.commandToolDetail(data2)

        #expect(sheet1.id != sheet2.id)
        #expect(sheet1.id.contains("tool_1"))
        #expect(sheet2.id.contains("tool_2"))
    }

    @Test("CommandTool sheet equals same data")
    func testCommandToolSheetEquality() {
        let data = CommandToolChipData(
            id: "tool_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .green,
            displayName: "Read",
            summary: "file.swift",
            status: .success,
            durationMs: 10,
            arguments: "{}",
            result: "content",
            isResultTruncated: false
        )

        let sheet1 = ChatSheet.commandToolDetail(data)
        let sheet2 = ChatSheet.commandToolDetail(data)

        #expect(sheet1 == sheet2)
    }
}

// MARK: - SheetCoordinator CommandTool Tests

@Suite("SheetCoordinator CommandTool Tests")
@MainActor
struct SheetCoordinatorCommandToolTests {

    @Test("showCommandToolDetail creates correct sheet")
    func testShowCommandToolDetailCreatesSheet() {
        let coordinator = SheetCoordinator()
        let data = CommandToolChipData(
            id: "tool_123",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .green,
            displayName: "Bash",
            summary: "git status",
            status: .success,
            durationMs: 50,
            arguments: "{\"command\": \"git status\"}",
            result: "M README.md",
            isResultTruncated: false
        )

        coordinator.showCommandToolDetail(data)

        if case .commandToolDetail(let sheetData) = coordinator.activeSheet {
            #expect(sheetData.id == "tool_123")
            #expect(sheetData.displayName == "Bash")
        } else {
            Issue.record("Expected commandToolDetail sheet")
        }
    }
}

// MARK: - ResultTruncation Tests

@Suite("ResultTruncation Tests")
struct ResultTruncationTests {

    @Test("Truncation does not modify short content")
    func testTruncationShortContent() {
        let shortContent = "Line 1\nLine 2\nLine 3"
        let (result, wasTruncated) = ResultTruncation.truncate(shortContent)

        #expect(result == shortContent)
        #expect(wasTruncated == false)
    }

    @Test("Truncation handles empty string")
    func testTruncationEmptyString() {
        let (result, wasTruncated) = ResultTruncation.truncate("")

        #expect(result == "")
        #expect(wasTruncated == false)
    }

    @Test("Truncation truncates by line count")
    func testTruncationByLineCount() {
        // Create content with more lines than maxLines (100)
        let lines = (1...150).map { "Line \($0)" }
        let longContent = lines.joined(separator: "\n")

        let (result, wasTruncated) = ResultTruncation.truncate(longContent)

        #expect(wasTruncated == true)
        #expect(result.contains("[Output truncated for performance]"))

        // Count lines in result (excluding truncation message)
        let resultLines = result.components(separatedBy: "\n")
        // Should have 100 lines + 2 empty lines + truncation message line
        #expect(resultLines.count <= 103)
    }

    @Test("Truncation truncates by character count")
    func testTruncationByCharacterCount() {
        // Create content with more characters than maxCharacters (8000)
        let longContent = String(repeating: "x", count: 10_000)

        let (result, wasTruncated) = ResultTruncation.truncate(longContent)

        #expect(wasTruncated == true)
        #expect(result.contains("[Output truncated for performance]"))
        // Result should be around maxCharacters + truncation message length
        #expect(result.count < 8_100)
    }

    @Test("Truncation constants are reasonable")
    func testTruncationConstants() {
        #expect(ResultTruncation.maxLines == 35)
        #expect(ResultTruncation.maxCharacters == 2_800)
        #expect(ResultTruncation.truncationMessage.contains("truncated"))
    }

    @Test("Factory truncates large results")
    func testFactoryTruncatesLargeResults() {
        // Create a large result that exceeds limits
        let largeResult = (1...200).map { "Line \($0): Some content here" }.joined(separator: "\n")

        let toolUse = ToolUseData(
            toolName: "Read",
            toolCallId: "call_large",
            arguments: "{\"file_path\": \"/path/to/large.txt\"}",
            status: .success,
            result: largeResult,
            durationMs: 100
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.isResultTruncated == true)
        #expect(chipData?.result?.contains("[Output truncated") == true)
    }

    @Test("Factory does not truncate small results")
    func testFactoryDoesNotTruncateSmallResults() {
        let smallResult = "Line 1\nLine 2\nLine 3"

        let toolUse = ToolUseData(
            toolName: "Read",
            toolCallId: "call_small",
            arguments: "{\"file_path\": \"/path/to/small.txt\"}",
            status: .success,
            result: smallResult,
            durationMs: 10
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.isResultTruncated == false)
        #expect(chipData?.result == smallResult)
    }

    @Test("Factory handles nil result without truncation flag")
    func testFactoryHandlesNilResult() {
        let toolUse = ToolUseData(
            toolName: "Bash",
            toolCallId: "call_running",
            arguments: "{\"command\": \"sleep 10\"}",
            status: .running,
            result: nil,
            durationMs: nil
        )

        let chipData = CommandToolChipData(from: toolUse)

        #expect(chipData != nil)
        #expect(chipData?.isResultTruncated == false)
        #expect(chipData?.result == nil)
    }
}
