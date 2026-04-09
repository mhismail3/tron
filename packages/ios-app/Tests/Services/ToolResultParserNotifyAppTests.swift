import Testing
import Foundation
@testable import TronMobile

@Suite("ToolResultParser NotifyApp Tests")
struct ToolResultParserNotifyAppTests {

    // MARK: - Empty args during tool_generating

    @Test("Running tool with empty arguments returns sending status")
    func emptyArgsRunningReturnsSending() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_1",
            arguments: "",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .sending)
    }

    @Test("Running tool with empty arguments has placeholder title")
    func emptyArgsRunningHasPlaceholderTitle() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_2",
            arguments: "",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.title == "Sending notification...")
    }

    @Test("Running tool with empty arguments has empty body")
    func emptyArgsRunningHasEmptyBody() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_3",
            arguments: "",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.body == "")
    }

    @Test("Success tool with empty arguments returns nil")
    func emptyArgsSuccessReturnsNil() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_4",
            arguments: "",
            status: .success,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData == nil)
    }

    @Test("Error tool with empty arguments returns nil")
    func emptyArgsErrorReturnsNil() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_5",
            arguments: "",
            status: .error,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData == nil)
    }

    // MARK: - Existing behavior preservation

    @Test("Running tool with valid arguments returns sending with title")
    func validArgsRunningReturnsSending() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_6",
            arguments: "{\"title\":\"Build Complete\",\"body\":\"All tests passed\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .sending)
        #expect(chipData?.title == "Build Complete")
        #expect(chipData?.body == "All tests passed")
    }

    @Test("Success tool with valid arguments returns sent")
    func validArgsSuccessReturnsSent() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_7",
            arguments: "{\"title\":\"Build Complete\",\"body\":\"All tests passed\"}",
            status: .success,
            result: "Notification sent to 1 device"
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .sent)
        #expect(chipData?.title == "Build Complete")
        #expect(chipData?.body == "All tests passed")
    }

    @Test("Error tool with valid arguments returns failed with error message")
    func validArgsErrorReturnsFailed() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_8",
            arguments: "{\"title\":\"Build Complete\",\"body\":\"All tests passed\"}",
            status: .error,
            result: "No devices registered"
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData != nil)
        #expect(chipData?.status == .failed)
        #expect(chipData?.errorMessage == "No devices registered")
    }

    @Test("Success tool extracts successCount from structured details")
    func successExtractsCountFromDetails() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_9",
            arguments: "{\"title\":\"Done\",\"body\":\"OK\"}",
            status: .success,
            result: "Notification sent",
            details: [
                "successCount": AnyCodable(2),
                "failureCount": AnyCodable(0)
            ]
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.successCount == 2)
        #expect(chipData?.failureCount == 0)
    }

    @Test("Success tool with missing details has nil counts")
    func successMissingDetailsHasNilCounts() {
        // Server always provides structured details; if details is absent
        // (e.g., historical events), counts are nil — no regex fallback.
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_10",
            arguments: "{\"title\":\"Done\",\"body\":\"OK\"}",
            status: .success,
            result: "Notification sent to 3 devices"
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.successCount == nil)
        #expect(chipData?.failureCount == nil)
    }

    @Test("Success tool with zero counts in details")
    func successZeroCountsInDetails() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_zero",
            arguments: "{\"title\":\"Done\",\"body\":\"OK\"}",
            status: .success,
            result: "No devices",
            details: [
                "successCount": AnyCodable(0),
                "failureCount": AnyCodable(0),
                "totalCount": AnyCodable(0)
            ]
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.successCount == 0)
        #expect(chipData?.failureCount == 0)
    }

    @Test("Success tool with partial failure counts")
    func successPartialFailureCounts() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_partial",
            arguments: "{\"title\":\"Done\",\"body\":\"OK\"}",
            status: .success,
            result: "Sent to 2 of 3 devices",
            details: [
                "successCount": AnyCodable(2),
                "failureCount": AnyCodable(1),
                "totalCount": AnyCodable(3)
            ]
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.successCount == 2)
        #expect(chipData?.failureCount == 1)
    }

    @Test("Tool with sheetContent preserves it")
    func sheetContentPreserved() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_11",
            arguments: "{\"title\":\"Done\",\"body\":\"OK\",\"sheetContent\":\"## Summary\\nAll good\"}",
            status: .success,
            result: "Sent"
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.sheetContent == "## Summary\nAll good")
    }

    @Test("Tool preserves toolCallId")
    func toolCallIdPreserved() {
        let tool = ToolUseData(
            toolName: "NotifyApp",
            toolCallId: "call_unique_123",
            arguments: "{\"title\":\"Done\",\"body\":\"OK\"}",
            status: .running,
            result: nil
        )

        let chipData = ToolResultParser.parseNotifyApp(from: tool)
        #expect(chipData?.toolCallId == "call_unique_123")
    }
}
