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
        ID: task_abc | Status: pending | Priority: high

        Implement two-factor authentication
        Active form: Adding 2FA support
        Project: Auth Refactor (proj_xyz)
        Area: Security (area_123)
        Due: 2026-03-01
        Deferred until: 2026-02-15
        Time: 0/120min
        Tags: security, auth
        Source: agent
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z

        Notes:
        [2026-02-11] Initial setup notes

        Subtasks (2):
          [x] task_sub1: Research 2FA providers
          [ ] task_sub2: Implement TOTP

        Blocked by: task_dep1, task_dep2
        Blocks: task_dep3

        Recent activity:
          2026-02-11: created
          2026-02-11: status_changed - pending → in_progress
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "create")

        #expect(entity != nil)
        #expect(entity?.entityType == .task)
        #expect(entity?.title == "Add 2FA")
        #expect(entity?.id == "task_abc")
        #expect(entity?.status == "pending")
        #expect(entity?.priority == "high")
        #expect(entity?.description == "Implement two-factor authentication")
        #expect(entity?.activeForm == "Adding 2FA support")
        #expect(entity?.projectName == "Auth Refactor (proj_xyz)")
        #expect(entity?.areaName == "Security (area_123)")
        #expect(entity?.dueDate == "2026-03-01")
        #expect(entity?.deferredUntil == "2026-02-15")
        #expect(entity?.estimatedMinutes == 120)
        #expect(entity?.actualMinutes == 0)
        #expect(entity?.tags == ["security", "auth"])
        #expect(entity?.source == "agent")
        #expect(entity?.createdAt == "2026-02-11T10:00:00Z")
        #expect(entity?.updatedAt == "2026-02-11T10:00:00Z")
        #expect(entity?.notes?.contains("Initial setup notes") == true)

        #expect(entity?.subtasks.count == 2)
        #expect(entity?.subtasks[0].mark == "x")
        #expect(entity?.subtasks[0].id == "task_sub1")
        #expect(entity?.subtasks[0].title == "Research 2FA providers")
        #expect(entity?.subtasks[1].mark == " ")

        #expect(entity?.blockedBy == ["task_dep1", "task_dep2"])
        #expect(entity?.blocks == ["task_dep3"])

        #expect(entity?.activity.count == 2)
        #expect(entity?.activity[0].date == "2026-02-11")
        #expect(entity?.activity[0].action == "created")
        #expect(entity?.activity[1].detail == "pending → in_progress")
    }

    @Test("Parses minimal task")
    func testParseMinimalTask() {
        let result = """
        # Simple task
        ID: task_min | Status: pending | Priority: medium
        Source: agent
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "get")

        #expect(entity != nil)
        #expect(entity?.entityType == .task)
        #expect(entity?.title == "Simple task")
        #expect(entity?.id == "task_min")
        #expect(entity?.status == "pending")
        #expect(entity?.priority == "medium")
        #expect(entity?.description == nil)
        #expect(entity?.tags.isEmpty == true)
        #expect(entity?.subtasks.isEmpty == true)
        #expect(entity?.blockedBy.isEmpty == true)
        #expect(entity?.activity.isEmpty == true)
    }

    @Test("Parses task from update action with action prefix")
    func testParseUpdateTask() {
        let result = """
        Updated task task_abc: Fix bug [in_progress]

        # Fix bug
        ID: task_abc | Status: in_progress | Priority: high
        Source: agent
        Started: 2026-02-11T11:00:00Z
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T11:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "update")

        #expect(entity != nil)
        #expect(entity?.entityType == .task)
        #expect(entity?.title == "Fix bug")
        #expect(entity?.status == "in_progress")
        #expect(entity?.priority == "high")
        #expect(entity?.startedAt == "2026-02-11T11:00:00Z")
    }

    @Test("Parses task from delete action with pre-deletion snapshot")
    func testParseDeleteTask() {
        let result = """
        Deleted task task_abc: Old task

        # Old task
        ID: task_abc | Status: completed | Priority: low
        Tags: cleanup
        Source: agent
        Completed: 2026-02-10T15:00:00Z
        Created: 2026-02-09T10:00:00Z
        Updated: 2026-02-10T15:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "delete")

        #expect(entity != nil)
        #expect(entity?.entityType == .task)
        #expect(entity?.title == "Old task")
        #expect(entity?.status == "completed")
        #expect(entity?.completedAt == "2026-02-10T15:00:00Z")
        #expect(entity?.tags == ["cleanup"])
    }

    @Test("Parses task with time tracking from log_time")
    func testParseLogTimeTask() {
        let result = """
        Logged 15min on task_abc. Total: 15min/30min

        # Review PR
        ID: task_abc | Status: in_progress | Priority: medium
        Time: 15/30min
        Source: agent
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:15:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "log_time")

        #expect(entity != nil)
        #expect(entity?.entityType == .task)
        #expect(entity?.title == "Review PR")
        #expect(entity?.estimatedMinutes == 30)
        #expect(entity?.actualMinutes == 15)
    }

    // MARK: - Project Parsing

    @Test("Parses project with tasks")
    func testParseProjectWithTasks() {
        let result = """
        Created project proj_abc: Auth Overhaul

        # Auth Overhaul
        ID: proj_abc | Status: active | 1/3 tasks

        Rewrite the authentication system
        Area: Engineering (area_eng)
        Tags: security, backend
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z

        Tasks (3):
          [x] task_1: Set up OAuth [high]
          [>] task_2: Implement JWT
          [ ] task_3: Write tests [low]
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "create_project")

        #expect(entity != nil)
        #expect(entity?.entityType == .project)
        #expect(entity?.title == "Auth Overhaul")
        #expect(entity?.id == "proj_abc")
        #expect(entity?.status == "active")
        #expect(entity?.taskCount == 3)
        #expect(entity?.completedTaskCount == 1)
        #expect(entity?.description == "Rewrite the authentication system")
        #expect(entity?.areaName == "Engineering (area_eng)")
        #expect(entity?.tags == ["security", "backend"])

        #expect(entity?.tasks.count == 3)
        #expect(entity?.tasks[0].mark == "x")
        #expect(entity?.tasks[0].id == "task_1")
        #expect(entity?.tasks[0].title == "Set up OAuth")
        #expect(entity?.tasks[0].extra == "[high]")
        #expect(entity?.tasks[1].mark == ">")
        #expect(entity?.tasks[2].mark == " ")
        #expect(entity?.tasks[2].extra == "[low]")
    }

    @Test("Parses minimal project")
    func testParseMinimalProject() {
        let result = """
        # Empty Project
        ID: proj_min | Status: active | 0/0 tasks
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "get_project")

        #expect(entity != nil)
        #expect(entity?.entityType == .project)
        #expect(entity?.title == "Empty Project")
        #expect(entity?.taskCount == 0)
        #expect(entity?.completedTaskCount == 0)
        #expect(entity?.tasks.isEmpty == true)
    }

    // MARK: - Area Parsing

    @Test("Parses area with counts")
    func testParseAreaWithCounts() {
        let result = """
        Created area area_abc: Security [active]

        # Security
        ID: area_abc | Status: active
        2 projects, 5 tasks (3 active)

        Ongoing security and compliance work
        Tags: infra, compliance
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "create_area")

        #expect(entity != nil)
        #expect(entity?.entityType == .area)
        #expect(entity?.title == "Security")
        #expect(entity?.id == "area_abc")
        #expect(entity?.status == "active")
        #expect(entity?.projectCount == 2)
        #expect(entity?.taskCount == 5)
        #expect(entity?.activeTaskCount == 3)
        #expect(entity?.description == "Ongoing security and compliance work")
        #expect(entity?.tags == ["infra", "compliance"])
        #expect(entity?.createdAt == "2026-02-11T10:00:00Z")
    }

    @Test("Parses minimal area")
    func testParseMinimalArea() {
        let result = """
        # Quality
        ID: area_min | Status: active
        0 projects, 0 tasks (0 active)
        Created: 2026-02-11T10:00:00Z
        Updated: 2026-02-11T10:00:00Z
        """

        let entity = ToolResultParser.parseEntityDetail(from: result, action: "get_area")

        #expect(entity != nil)
        #expect(entity?.entityType == .area)
        #expect(entity?.title == "Quality")
        #expect(entity?.projectCount == 0)
        #expect(entity?.taskCount == 0)
        #expect(entity?.activeTaskCount == 0)
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

    @Test("Returns nil for list_projects action")
    func testReturnsNilForListProjectsAction() {
        let entity = ToolResultParser.parseEntityDetail(from: "Projects (2):", action: "list_projects")
        #expect(entity == nil)
    }

    @Test("Returns nil for list_areas action")
    func testReturnsNilForListAreasAction() {
        let entity = ToolResultParser.parseEntityDetail(from: "Areas (1):", action: "list_areas")
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
        let taskActions = ["create", "update", "get", "delete", "log_time"]
        for action in taskActions {
            let result = """
            # Test
            ID: task_abc | Status: pending | Priority: medium
            Source: agent
            Created: 2026-02-11T10:00:00Z
            Updated: 2026-02-11T10:00:00Z
            """
            let entity = ToolResultParser.parseEntityDetail(from: result, action: action)
            #expect(entity?.entityType == .task, "Expected .task for action '\(action)'")
        }
    }

    @Test("Detects project entity type from project actions")
    func testDetectsProjectEntityType() {
        let projectActions = ["create_project", "update_project", "get_project", "delete_project"]
        for action in projectActions {
            let result = """
            # Test
            ID: proj_abc | Status: active | 0/0 tasks
            Created: 2026-02-11T10:00:00Z
            Updated: 2026-02-11T10:00:00Z
            """
            let entity = ToolResultParser.parseEntityDetail(from: result, action: action)
            #expect(entity?.entityType == .project, "Expected .project for action '\(action)'")
        }
    }

    @Test("Detects area entity type from area actions")
    func testDetectsAreaEntityType() {
        let areaActions = ["create_area", "update_area", "get_area", "delete_area"]
        for action in areaActions {
            let result = """
            # Test
            ID: area_abc | Status: active
            0 projects, 0 tasks (0 active)
            Created: 2026-02-11T10:00:00Z
            Updated: 2026-02-11T10:00:00Z
            """
            let entity = ToolResultParser.parseEntityDetail(from: result, action: action)
            #expect(entity?.entityType == .area, "Expected .area for action '\(action)'")
        }
    }

    // MARK: - Integration with parseTaskManager

    @Test("parseTaskManager attaches entityDetail for create action")
    func testParseTaskManagerAttachesEntityDetail() {
        let result = """
        Created task task_abc: Fix bug [pending]

        # Fix bug
        ID: task_abc | Status: pending | Priority: high
        Source: agent
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
        #expect(chipData?.entityDetail?.entityType == .task)
        #expect(chipData?.entityDetail?.title == "Fix bug")
        #expect(chipData?.entityDetail?.priority == "high")
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
}
