import Testing
import Foundation
@testable import TronMobile

@Suite("ToolResultParser TaskManager Tests")
struct ToolResultParserTaskManagerTests {

    // MARK: - Running State Tests

    @Test("Running tool with nil result returns running status")
    func testParseTaskManagerRunningReturnsRunningStatus() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_1",
            arguments: "{\"action\":\"create\",\"title\":\"Fix bug\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .running)
        #expect(chipData?.action == "create")
        #expect(chipData?.taskTitle == "Fix bug")
        #expect(chipData?.toolCallId == "call_1")
    }

    @Test("Running tool with empty arguments returns running status with default action")
    func testParseTaskManagerRunningEmptyArgsReturnsRunning() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_2",
            arguments: "",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .running)
        #expect(chipData?.action == "list")
    }

    // MARK: - Completed State Tests

    @Test("Completed tool with result returns completed status with summary")
    func testParseTaskManagerCompletedWithResult() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_3",
            arguments: "{\"action\":\"create\",\"title\":\"Fix bug\"}",
            status: .success,
            result: "Created task #1: Fix bug\nStatus: pending"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .completed)
        #expect(chipData?.resultSummary == "Created task #1: Fix bug")
    }

    @Test("Completed tool with nil result returns running status")
    func testParseTaskManagerCompletedNoResultReturnsRunning() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_4",
            arguments: "{\"action\":\"list\"}",
            status: .success,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .running)
    }

    @Test("Action defaults to list when not specified")
    func testParseTaskManagerDefaultAction() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_5",
            arguments: "{}",
            status: .success,
            result: "No tasks found"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.action == "list")
    }

    @Test("Extracts projectTitle as fallback for taskTitle")
    func testParseTaskManagerProjectTitleFallback() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_6",
            arguments: "{\"action\":\"create\",\"projectTitle\":\"My Project\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.taskTitle == "My Project")
    }

    @Test("Long result summary is truncated")
    func testParseTaskManagerLongResultTruncated() {
        let longLine = String(repeating: "x", count: 100)
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_7",
            arguments: "{\"action\":\"list\"}",
            status: .success,
            result: longLine
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.resultSummary?.count ?? 0 <= 84)
        #expect(chipData?.resultSummary?.hasSuffix("...") == true)
    }
}
