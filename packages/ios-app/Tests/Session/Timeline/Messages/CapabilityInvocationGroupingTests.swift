import XCTest
@testable import TronMobile

final class CapabilityInvocationGroupingTests: XCTestCase {
    func testSingleCapabilityInvocationStaysUngrouped() {
        let messages = [
            textMessage("Before"),
            capabilityMessage(id: "call-1", operation: "worker_list"),
            textMessage("After")
        ]

        let items = CapabilityInvocationGrouping.renderItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .message(let capability) = items[1],
              case .capabilityInvocation(let invocation) = capability.content else {
            return XCTFail("Expected single capability invocation to render as a normal message")
        }
        XCTAssertEqual(invocation.id, "call-1")
    }

    func testAdjacentCapabilityInvocationsCollapseIntoOneGroup() {
        let messages = [
            textMessage("Before"),
            capabilityMessage(id: "call-1", operation: "worker_discover"),
            capabilityMessage(id: "call-2", operation: "worker_inspect", status: .running),
            capabilityMessage(id: "call-3", operation: "worker_inbox", status: .error),
            textMessage("After")
        ]

        let items = CapabilityInvocationGrouping.renderItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .capabilityGroup(let group) = items[1] else {
            return XCTFail("Expected adjacent capability invocations to collapse into one group")
        }
        XCTAssertEqual(group.invocations.map(\.id), ["call-1", "call-2", "call-3"])
        XCTAssertEqual(group.data.title, "Using 3 capabilities")
        XCTAssertEqual(group.data.inlineStatusText, "2/3 done")
        XCTAssertEqual(group.data.displayStatus, .running)
    }

    func testTextAndThinkingSplitCapabilityGroups() {
        let messages = [
            capabilityMessage(id: "call-1", operation: "worker_list"),
            capabilityMessage(id: "call-2", operation: "worker_runs"),
            thinkingMessage("Inspecting the results"),
            capabilityMessage(id: "call-3", operation: "worker_inspect"),
            capabilityMessage(id: "call-4", operation: "worker_inbox")
        ]

        let items = CapabilityInvocationGrouping.renderItems(from: messages)

        XCTAssertEqual(items.count, 3)
        guard case .capabilityGroup(let first) = items[0],
              case .message(let thinking) = items[1],
              case .capabilityGroup(let second) = items[2] else {
            return XCTFail("Expected thinking content to split capability batches")
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
        let data = CapabilityInvocationGroupData(invocations: [
            invocation(id: "call-1", operation: "worker_list", status: .success),
            invocation(id: "call-2", operation: "worker_invoke", status: .error)
        ])

        XCTAssertEqual(data.title, "Used 2 capabilities")
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

    private func capabilityMessage(
        id: String,
        operation: String,
        status: CapabilityInvocationStatus = .success
    ) -> ChatMessage {
        ChatMessage(role: .assistant, content: .capabilityInvocation(invocation(id: id, operation: operation, status: status)))
    }

    private func invocation(
        id: String,
        operation: String,
        status: CapabilityInvocationStatus
    ) -> CapabilityInvocationData {
        CapabilityInvocationData(
            id: id,
            status: status,
            arguments: #"{"operation":"\#(operation)"}"#,
            durationMs: status == .running ? nil : 25,
            identity: CapabilityIdentity(modelPrimitiveName: "execute", operationName: operation)
        )
    }
}
