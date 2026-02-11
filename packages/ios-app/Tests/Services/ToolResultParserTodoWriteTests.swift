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
        #expect(chipData?.chipSummary == "Creating task...")
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
        #expect(chipData?.chipSummary == "Listing tasks...")
    }

    // MARK: - Completed State Tests

    @Test("Completed create with title shows quoted title in summary")
    func testParseTaskManagerCompletedCreateWithTitle() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_3",
            arguments: "{\"action\":\"create\",\"title\":\"Fix bug\"}",
            status: .success,
            result: "Created task task_abc: Fix bug [pending]"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .completed)
        #expect(chipData?.chipSummary == "Created \"Fix bug\"")
        #expect(chipData?.fullResult == "Created task task_abc: Fix bug [pending]")
    }

    @Test("Completed list with count extracts task count for summary")
    func testParseTaskManagerCompletedListExtractsCount() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_3b",
            arguments: "{\"action\":\"list\"}",
            status: .success,
            result: "Tasks (3/5):\n[ ] task1: First\n[>] task2: Second\n[x] task3: Third"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "3 tasks")
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
            result: "No tasks found."
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.action == "list")
    }

    @Test("Extracts projectTitle as fallback for taskTitle")
    func testParseTaskManagerProjectTitleFallback() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_6",
            arguments: "{\"action\":\"create_project\",\"projectTitle\":\"My Project\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.taskTitle == "My Project")
        #expect(chipData?.chipSummary == "Creating project...")
    }

    @Test("Stores full result and arguments for detail sheet")
    func testParseTaskManagerStoresFullResultAndArguments() {
        let args = "{\"action\":\"get\",\"taskId\":\"task_abc\"}"
        let result = "# Fix bug\nID: task_abc | Status: pending | Priority: medium\n\nDescription here"
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_8",
            arguments: args,
            status: .success,
            result: result
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.fullResult == result)
        #expect(chipData?.arguments == args)
    }

    @Test("Search action extracts result count for summary")
    func testParseTaskManagerSearchExtractsCount() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_9",
            arguments: "{\"action\":\"search\",\"query\":\"bug\"}",
            status: .success,
            result: "Search results for \"bug\" (3):\n  task1: Fix login bug [pending]"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "3 results")
    }

    @Test("Long title is truncated in chip summary")
    func testParseTaskManagerLongTitleTruncated() {
        let longTitle = String(repeating: "x", count: 60)
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_10",
            arguments: "{\"action\":\"create\",\"title\":\"\(longTitle)\"}",
            status: .success,
            result: "Created task task_abc: \(longTitle) [pending]"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary.count ?? 0 <= 55)
        #expect(chipData?.chipSummary.contains("...") == true)
    }

    @Test("Running state summaries for all actions")
    func testParseTaskManagerRunningSummaries() {
        let actions = [
            ("create", "Creating task..."),
            ("update", "Updating task..."),
            ("delete", "Deleting task..."),
            ("list", "Listing tasks..."),
            ("search", "Searching tasks..."),
            ("get", "Getting task..."),
            ("create_project", "Creating project..."),
            ("update_project", "Updating project..."),
            ("list_projects", "Listing projects..."),
            ("log_time", "Logging time..."),
            ("unknown_action", "Managing tasks...")
        ]

        for (action, expected) in actions {
            let tool = ToolUseData(
                toolName: "TaskManager",
                toolCallId: "call_\(action)",
                arguments: "{\"action\":\"\(action)\"}",
                status: .running,
                result: nil
            )

            let chipData = ToolResultParser.parseTaskManager(from: tool)
            #expect(chipData?.chipSummary == expected, "Expected '\(expected)' for action '\(action)'")
        }
    }
}
