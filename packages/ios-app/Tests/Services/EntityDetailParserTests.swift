import Testing
import Foundation
@testable import TronMobile

@Suite("EntityDetail Parser Tests")
struct EntityDetailParserTests {

    // MARK: - Task Parsing

    @Test("Parses task with all fields")
    func testParseFullTask() {
        let result = """
        Created task task_abc: Add 2FA [pending]

        # Add 2FA
        ID: task_abc | Status: pending

        Implement two-factor authentication
        Active form: Adding 2FA support
        Parent: parent_xyz
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z

        Notes:
        [2026-02-11] Initial setup notes

        Subtasks (2):
          [x] task_sub1: Research 2FA providers
          [ ] task_sub2: Implement TOTP

        Recent activity:
          2026-02-11: created
          2026-02-11: status_changed - pending → in_progress
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "create")

        #expect(entity != nil)
        #expect(entity?.title == "Add 2FA")
        #expect(entity?.id == "task_abc")
        #expect(entity?.status == "pending")
        #expect(entity?.description == "Implement two-factor authentication")
        #expect(entity?.activeForm == "Adding 2FA support")
        #expect(entity?.createdAt == "2026-02-11T10:00:00Z")
        #expect(entity?.updatedAt == "2026-02-11T10:00:00Z")
        #expect(entity?.notes?.contains("Initial setup notes") == true)

        #expect(entity?.subtasks.count == 2)
        #expect(entity?.subtasks[0].mark == "x")
        #expect(entity?.subtasks[0].id == "task_sub1")
        #expect(entity?.subtasks[0].title == "Research 2FA providers")
        #expect(entity?.subtasks[1].mark == " ")

        #expect(entity?.activity.count == 2)
        #expect(entity?.activity[0].date == "2026-02-11")
        #expect(entity?.activity[0].action == "created")
        #expect(entity?.activity[1].detail == "pending → in_progress")
    }

    @Test("Parses minimal task")
    func testParseMinimalTask() {
        let result = """
        # Simple task
        ID: task_min | Status: pending
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "get")

        #expect(entity != nil)
        #expect(entity?.title == "Simple task")
        #expect(entity?.id == "task_min")
        #expect(entity?.status == "pending")
        #expect(entity?.description == nil)
        #expect(entity?.subtasks.isEmpty == true)
        #expect(entity?.activity.isEmpty == true)
    }

    @Test("Parses task from update action with action prefix")
    func testParseUpdateTask() {
        let result = """
        Updated task task_abc: Fix bug [in_progress]

        # Fix bug
        ID: task_abc | Status: in_progress
        Started: 2026-02-11T11:00:00Z
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T11:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "update")

        #expect(entity != nil)
        #expect(entity?.title == "Fix bug")
        #expect(entity?.status == "in_progress")
        #expect(entity?.startedAt == "2026-02-11T11:00:00Z")
    }

    @Test("Parses task from delete action with pre-deletion snapshot")
    func testParseDeleteTask() {
        let result = """
        Deleted task task_abc: Old task

        # Old task
        ID: task_abc | Status: completed
        Completed: 2026-02-10T15:00:00Z
        Created: 2026-02-09T10:00:00Z
        Updated: 2026-02-10T15:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "delete")

        #expect(entity != nil)
        #expect(entity?.title == "Old task")
        #expect(entity?.status == "completed")
        #expect(entity?.completedAt == "2026-02-10T15:00:00Z")
    }

    // MARK: - Edge Cases

    @Test("Returns nil for list action")
    func testReturnsNilForListAction() {
        let result = "Tasks (3/5):\n[ ] task1: First\n[>] task2: Second"
        let entity = ToolResultParser.parseEntityDetail(from: result, action: "list")
        #expect(entity == nil)
    }

    @Test("Returns nil for search action")
    func testReturnsNilForSearchAction() {
        let result = "Search results for \"bug\" (2):\n  task1: Fix bug [pending]"
        let entity = ToolResultParser.parseEntityDetail(from: result, action: "search")
        #expect(entity == nil)
    }

    @Test("Returns nil for malformed input")
    func testReturnsNilForMalformedInput() {
        let entity = ToolResultParser.parseEntityDetail(from: "random garbage", action: "get")
        #expect(entity == nil)
    }

    @Test("Returns nil for empty input")
    func testReturnsNilForEmptyInput() {
        let entity = ToolResultParser.parseEntityDetail(from: "", action: "get")
        #expect(entity == nil)
    }

    // MARK: - Entity type detection from action

    @Test("Detects task entity type from task actions")
    func testDetectsTaskEntityType() {
        let taskActions = ["create", "update", "get", "delete"]
        for action in taskActions {
            let result = """
            # Test
            ID: task_abc | Status: pending
            Created: 2026-02-11T10:00:00Z
            Updated: 2026-02-11T10:00:00Z
            """
            let entity = ToolResultParser.parseEntityDetail(from: result, action: action)
            #expect(entity != nil, "Expected entity for action '\(action)'")
        }
    }

    // MARK: - Integration with parseTaskManager

    @Test("parseTaskManager attaches entityDetail for create action")
    func testParseTaskManagerAttachesEntityDetail() {
        let result = """
        Created task task_abc: Fix bug [pending]

        # Fix bug
        ID: task_abc | Status: pending
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z
        """

        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_1",
            arguments: "{\"action\":\"create\",\"title\":\"Fix bug\"}",
            status: .success,
            result: result
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.entityDetail != nil)
        #expect(chipData?.entityDetail?.title == "Fix bug")
    }

    @Test("parseTaskManager returns nil entityDetail for list action")
    func testParseTaskManagerNilEntityDetailForList() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_2",
            arguments: "{\"action\":\"list\"}",
            status: .success,
            result: "Tasks (1/1):\n[ ] task_abc: Test"
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.entityDetail == nil)
    }

    @Test("parseTaskManager returns nil entityDetail for running state")
    func testParseTaskManagerNilEntityDetailWhenRunning() {
        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_3",
            arguments: "{\"action\":\"create\",\"title\":\"Test\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.entityDetail == nil)
    }

    // MARK: - JSON Entity Parsing (Rust agent format)

    @Test("Parses full task from JSON")
    func testParseTaskFromJSON() {
        let result = """
        {
          "id": "task_abc",
          "title": "Add 2FA",
          "status": "pending",
          "description": "Implement two-factor auth",
          "createdAt": "2026-02-11T10:00:00Z",
          "updatedAt": "2026-02-11T10:00:00Z"
        }
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "create")

        #expect(entity != nil)
        #expect(entity?.title == "Add 2FA")
        #expect(entity?.id == "task_abc")
        #expect(entity?.status == "pending")
        #expect(entity?.description == "Implement two-factor auth")
    }

    @Test("Parses delete confirmation from JSON")
    func testParseDeleteConfirmationFromJSON() {
        let result = """
        {
          "success": true,
          "taskId": "task_abc"
        }
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "delete")

        #expect(entity != nil)
        #expect(entity?.id == "task_abc")
        #expect(entity?.status == "confirmed")
    }

    @Test("Returns nil for JSON with no id or success")
    func testReturnsNilForEmptyJSON() {
        let result = """
        {
          "random": "stuff"
        }
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "get")
        #expect(entity == nil)
    }

    // MARK: - JSON List Parsing (Rust agent format)

    @Test("Parses task list from JSON")
    func testParseTaskListFromJSON() {
        let result = """
        {
          "tasks": [
            {"id": "task_1", "title": "Fix bug", "status": "pending"},
            {"id": "task_2", "title": "Add tests", "status": "in_progress"},
            {"id": "task_3", "title": "Done task", "status": "completed"}
          ],
          "count": 3
        }
        """

        let listResult = ToolResultParser.parseListResult(from: result, action: "list")

        if case .tasks(let items) = listResult {
            #expect(items.count == 3)
            #expect(items[0].taskId == "task_1")
            #expect(items[0].title == "Fix bug")
            #expect(items[0].mark == " ")
            #expect(items[0].status == "pending")
            #expect(items[1].mark == ">")
            #expect(items[2].mark == "x")
        } else {
            Issue.record("Expected .tasks but got \(String(describing: listResult))")
        }
    }

    @Test("Parses search results from JSON")
    func testParseSearchResultsFromJSON() {
        let result = """
        {
          "tasks": [
            {"id": "task_1", "title": "Fix auth bug", "status": "pending"},
            {"id": "task_2", "title": "Auth tests", "status": "completed"}
          ],
          "count": 2
        }
        """

        let listResult = ToolResultParser.parseListResult(from: result, action: "search")

        if case .searchResults(let items) = listResult {
            #expect(items.count == 2)
            #expect(items[0].itemId == "task_1")
            #expect(items[0].title == "Fix auth bug")
            #expect(items[0].status == "pending")
        } else {
            Issue.record("Expected .searchResults but got \(String(describing: listResult))")
        }
    }

    @Test("Parses empty task list from JSON")
    func testParseEmptyTaskListFromJSON() {
        let result = """
        {
          "tasks": [],
          "count": 0
        }
        """

        let listResult = ToolResultParser.parseListResult(from: result, action: "list")

        if case .empty(let msg) = listResult {
            #expect(msg == "No tasks found.")
        } else {
            Issue.record("Expected .empty but got \(String(describing: listResult))")
        }
    }

    @Test("parseTaskManager attaches listResult for list action with JSON")
    func testParseTaskManagerAttachesListResultForJSON() {
        let result = """
        {
          "tasks": [
            {"id": "task_1", "title": "Fix bug", "status": "pending"}
          ],
          "count": 1
        }
        """

        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_json_list",
            arguments: "{\"action\":\"list\"}",
            status: .success,
            result: result
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.listResult != nil)
        #expect(chipData?.entityDetail == nil)
        if case .tasks(let items) = chipData?.listResult {
            #expect(items.count == 1)
            #expect(items[0].taskId == "task_1")
        } else {
            Issue.record("Expected .tasks list result")
        }
    }

    @Test("parseTaskManager attaches entityDetail for create action with JSON")
    func testParseTaskManagerAttachesEntityDetailForJSON() {
        let result = """
        {
          "id": "task_abc",
          "title": "New task",
          "status": "pending"
        }
        """

        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_json_create",
            arguments: "{\"action\":\"create\",\"title\":\"New task\"}",
            status: .success,
            result: result
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.entityDetail != nil)
        #expect(chipData?.entityDetail?.title == "New task")
        #expect(chipData?.entityDetail?.id == "task_abc")
        #expect(chipData?.listResult == nil)
    }

    // MARK: - Batch Result Parsing

    @Test("parseTaskManager attaches batchResult for batch_create")
    func testParseTaskManagerBatchCreate() {
        let result = """
        {
          "affected": 5,
          "ids": ["task_1", "task_2", "task_3", "task_4", "task_5"]
        }
        """

        let tool = ToolUseData(
            toolName: "TaskManager",
            toolCallId: "call_batch",
            arguments: "{\"action\":\"batch_create\",\"items\":[]}",
            status: .success,
            result: result
        )

        let chipData = ToolResultParser.parseTaskManager(from: tool)
        #expect(chipData?.batchResult != nil)
        #expect(chipData?.batchResult?.affected == 5)
        #expect(chipData?.batchResult?.ids.count == 5)
        #expect(chipData?.entityDetail == nil)
        #expect(chipData?.listResult == nil)
        #expect(chipData?.chipSummary == "Created 5 tasks")
    }

    @Test("parseBatchResult returns nil for non-batch actions")
    func testParseBatchResultNilForEntityActions() {
        let result = """
        { "id": "task_abc", "title": "Test", "status": "pending" }
        """
        let batch = TaskResultParser.parseBatchResult(from: result, action: "create")
        #expect(batch == nil)
    }
}
