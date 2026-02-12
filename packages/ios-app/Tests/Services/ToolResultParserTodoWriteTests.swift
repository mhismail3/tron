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

    // MARK: - Task Actions: <verb> task "<name>"

    @Test("Task create shows verb type name format")
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
        #expect(chipData?.chipSummary == "Created task \"Fix bug\"")
        #expect(chipData?.fullResult == "Created task task_abc: Fix bug [pending]")
    }

    @Test("Task update extracts name from result")
    func testParseTaskManagerUpdateExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_upd",
            arguments: "{\"action\":\"update\",\"taskId\":\"task_abc\",\"status\":\"completed\"}",
            status: .success,
            result: "Updated task task_abc: Fix bug [completed]"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Updated task \"Fix bug\"")
    }

    @Test("Task delete extracts name from result")
    func testParseTaskManagerDeleteExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_del",
            arguments: "{\"action\":\"delete\",\"taskId\":\"task_abc\"}",
            status: .success,
            result: "Deleted task task_abc: Fix bug"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Deleted task \"Fix bug\"")
    }

    @Test("Task get extracts name from header")
    func testParseTaskManagerGetExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_get",
            arguments: "{\"action\":\"get\",\"taskId\":\"task_abc\"}",
            status: .success,
            result: "# Fix bug\nID: task_abc | Status: pending | Priority: medium"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Task \"Fix bug\"")
    }

    // MARK: - Project Actions: <verb> project "<name>"

    @Test("Project create shows name from args")
    func testParseTaskManagerProjectCreateShowsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_cp",
            arguments: "{\"action\":\"create_project\",\"projectTitle\":\"Auth Refactor\"}",
            status: .success,
            result: "Created project proj_abc: Auth Refactor"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Created project \"Auth Refactor\"")
    }

    @Test("Project delete extracts name from result")
    func testParseTaskManagerProjectDeleteExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_dp",
            arguments: "{\"action\":\"delete_project\",\"projectId\":\"proj_abc\"}",
            status: .success,
            result: "Deleted project proj_abc: Auth Refactor"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Deleted project \"Auth Refactor\"")
    }

    @Test("Project get extracts name from header")
    func testParseTaskManagerProjectGetExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_gp",
            arguments: "{\"action\":\"get_project\",\"projectId\":\"proj_abc\"}",
            status: .success,
            result: "# Auth Refactor\nID: proj_abc | Status: active | 2/5 tasks"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Project \"Auth Refactor\"")
    }

    // MARK: - Area Actions: <verb> area "<name>"

    @Test("Area create shows name from args")
    func testParseTaskManagerAreaCreateShowsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_ca",
            arguments: "{\"action\":\"create_area\",\"areaTitle\":\"Security\"}",
            status: .success,
            result: "Created area area_abc: Security [active]"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Created area \"Security\"")
    }

    @Test("Area delete extracts name from result")
    func testParseTaskManagerAreaDeleteExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_da",
            arguments: "{\"action\":\"delete_area\",\"areaId\":\"area_abc\"}",
            status: .success,
            result: "Deleted area area_abc: Security"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Deleted area \"Security\"")
    }

    @Test("Area get extracts name from header")
    func testParseTaskManagerAreaGetExtractsName() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_ga",
            arguments: "{\"action\":\"get_area\",\"areaId\":\"area_abc\"}",
            status: .success,
            result: "# Security\nID: area_abc | Status: active"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "Area \"Security\"")
    }

    // MARK: - List/Search Actions

    @Test("Completed list with count extracts task count")
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

    @Test("Search action extracts result count")
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

    @Test("Completed list_areas extracts area count")
    func testParseTaskManagerCompletedListAreasExtractsCount() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_la",
            arguments: "{\"action\":\"list_areas\"}",
            status: .success,
            result: "Areas (3)\n  - Security\n  - Quality\n  - Operations"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "3 areas")
    }

    @Test("List with 1 item uses singular form")
    func testParseTaskManagerSingularCount() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_s1",
            arguments: "{\"action\":\"list_areas\"}",
            status: .success,
            result: "Areas (1):\n  area_abc: Security [active]"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary == "1 area")
    }

    // MARK: - Edge Cases

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

    @Test("Extracts areaTitle as fallback for taskTitle")
    func testParseTaskManagerAreaTitleFallback() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_area",
            arguments: "{\"action\":\"create_area\",\"areaTitle\":\"Security\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.taskTitle == "Security")
        #expect(chipData?.chipSummary == "Creating area...")
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

    @Test("Long name is truncated in chip summary")
    func testParseTaskManagerLongTitleTruncated() {
        let longTitle = String(repeating: "x", count: 60)
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_10",
            arguments: "{\"action\":\"create_project\",\"projectTitle\":\"\(longTitle)\"}",
            status: .success,
            result: "Created project proj_abc: \(longTitle)"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.chipSummary.contains("...") == true)
        #expect(chipData?.chipSummary.hasPrefix("Created project \"") == true)
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
            ("get_project", "Getting project..."),
            ("delete_project", "Deleting project..."),
            ("create_area", "Creating area..."),
            ("update_area", "Updating area..."),
            ("get_area", "Getting area..."),
            ("delete_area", "Deleting area..."),
            ("list_areas", "Listing areas..."),
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
