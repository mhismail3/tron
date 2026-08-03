import XCTest
@testable import TronMobile

final class ToolInvocationGroupingTests: XCTestCase {
    func testSingleToolInvocationStaysUngrouped() {
        let messages = [
            textMessage("Before"),
            toolMessage(id: "call-1", toolName: "worker_list"),
            textMessage("After")
        ]

        let items = ToolInvocationGrouping.renderItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .message(let tool) = items[1],
              case .toolInvocation(let invocation) = tool.content else {
            return XCTFail("Expected single tool invocation to render as a normal message")
        }
        XCTAssertEqual(invocation.id, "call-1")
    }

    func testAdjacentToolInvocationsCollapseIntoOneGroup() {
        let messages = [
            textMessage("Before"),
            toolMessage(id: "call-1", toolName: "worker_discover"),
            toolMessage(id: "call-2", toolName: "worker_inspect", status: .running),
            toolMessage(id: "call-3", toolName: "worker_inbox", status: .error),
            textMessage("After")
        ]

        let items = ToolInvocationGrouping.renderItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .toolGroup(let group) = items[1] else {
            return XCTFail("Expected adjacent tool invocations to collapse into one group")
        }
        XCTAssertEqual(group.invocations.map(\.id), ["call-1", "call-2", "call-3"])
        XCTAssertEqual(group.data.title, "Using 3 tools")
        XCTAssertEqual(group.data.inlineStatusText, "2/3 done")
        XCTAssertEqual(group.data.displayStatus, .running)
    }

    func testTextAndThinkingSplitToolGroups() {
        let messages = [
            toolMessage(id: "call-1", toolName: "worker_list"),
            toolMessage(id: "call-2", toolName: "worker_runs"),
            thinkingMessage("Inspecting the results"),
            toolMessage(id: "call-3", toolName: "worker_inspect"),
            toolMessage(id: "call-4", toolName: "worker_inbox")
        ]

        let items = ToolInvocationGrouping.renderItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .toolGroup(let first) = items[0],
              case .message(let thinking) = items[1],
              case .toolGroup(let second) = items[2] else {
            return XCTFail("Expected thinking content to split tool batches")
        }
        XCTAssertEqual(first.invocations.map(\.id), ["call-1", "call-2"])
        XCTAssertEqual(second.invocations.map(\.id), ["call-3", "call-4"])
        if case .thinking(let content, _, _, _) = thinking.content {
            XCTAssertEqual(content, "Inspecting the results")
        } else {
            XCTFail("Expected thinking message")
        }
    }

    func testCompletedGroupReportsFailuresWithoutStayingActive() {
        let data = ToolInvocationGroupData(invocations: [
            invocation(id: "call-1", toolName: "worker_list", status: .success),
            invocation(id: "call-2", toolName: "worker_invoke", status: .error)
        ])

        XCTAssertEqual(data.title, "Used 2 tools")
        XCTAssertEqual(data.inlineStatusText, "1 failed")
        XCTAssertEqual(data.displayStatus, .error)
    }

    private func textMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    private func thinkingMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: .thinking(visible: text, isExpanded: false, isStreaming: false, kind: .reasoningSummary)
        )
    }

    private func toolMessage(
        id: String,
        toolName: String,
        status: ToolInvocationStatus = .success
    ) -> ChatMessage {
        ChatMessage(role: .assistant, content: .toolInvocation(invocation(id: id, toolName: toolName, status: status)))
    }

    private func invocation(
        id: String,
        toolName: String,
        status: ToolInvocationStatus
    ) -> ToolInvocationData {
        ToolInvocationData(
            id: id,
            status: status,
            arguments: "{}",
            durationMs: status == .running ? nil : 25,
            identity: ToolIdentity(toolName: toolName)
        )
    }
}
