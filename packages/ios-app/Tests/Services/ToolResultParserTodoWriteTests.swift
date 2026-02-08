import Testing
import Foundation
@testable import TronMobile

@Suite("ToolResultParser TodoWrite Tests")
struct ToolResultParserTodoWriteTests {

    // MARK: - Running State Tests

    @Test("Running tool with nil result returns updating status")
    func testParseTodoWriteRunningReturnsUpdatingStatus() {
        let tool = ToolUseData(
            toolName: "TodoWrite",
            toolCallId: "call_1",
            arguments: "{\"tasks\":[{\"subject\":\"Fix bug\",\"status\":\"in_progress\"}]}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTodoWrite(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .updating)
        #expect(chipData?.newCount == 0)
        #expect(chipData?.doneCount == 0)
        #expect(chipData?.totalCount == 0)
        #expect(chipData?.toolCallId == "call_1")
    }

    @Test("Running tool with empty arguments returns updating status")
    func testParseTodoWriteRunningEmptyArgsReturnsUpdatingStatus() {
        let tool = ToolUseData(
            toolName: "TodoWrite",
            toolCallId: "call_2",
            arguments: "",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTodoWrite(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .updating)
    }

    // MARK: - Completed State Tests

    @Test("Completed tool with counts returns updated status with parsed counts")
    func testParseTodoWriteCompletedWithCountsReturnsUpdatedStatus() {
        let tool = ToolUseData(
            toolName: "TodoWrite",
            toolCallId: "call_3",
            arguments: "{}",
            status: .success,
            result: "3 completed, 2 in progress, 1 pending"
        )

        let chipData = ToolResultParser.parseTodoWrite(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .updated)
        #expect(chipData?.doneCount == 3)
        #expect(chipData?.newCount == 3) // 2 in_progress + 1 pending
        #expect(chipData?.totalCount == 6)
    }

    @Test("Completed tool with result but no count match returns updated with zero counts")
    func testParseTodoWriteCompletedNoCountsReturnsUpdated() {
        let tool = ToolUseData(
            toolName: "TodoWrite",
            toolCallId: "call_4",
            arguments: "{}",
            status: .success,
            result: "Tasks updated successfully"
        )

        let chipData = ToolResultParser.parseTodoWrite(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .updated)
        #expect(chipData?.newCount == 0)
        #expect(chipData?.doneCount == 0)
        #expect(chipData?.totalCount == 0)
    }

    @Test("Error status tool with result returns updated status")
    func testParseTodoWriteErrorStatusReturnsUpdated() {
        let tool = ToolUseData(
            toolName: "TodoWrite",
            toolCallId: "call_5",
            arguments: "{}",
            status: .error,
            result: "Error: invalid task format"
        )

        let chipData = ToolResultParser.parseTodoWrite(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .updated)
    }

    @Test("Success status with nil result returns updating status")
    func testParseTodoWriteSuccessNoResultReturnsUpdating() {
        let tool = ToolUseData(
            toolName: "TodoWrite",
            toolCallId: "call_6",
            arguments: "{}",
            status: .success,
            result: nil
        )

        let chipData = ToolResultParser.parseTodoWrite(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .updating)
    }
}
