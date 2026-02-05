import Testing
import Foundation
@testable import TronMobile

/// Tests for AdaptTypes and ToolResultParser.parseAdapt
@Suite("AdaptTypes Tests")
struct AdaptTypesTests {

    // MARK: - AdaptChipData Tests

    @Test("AdaptChipData stores all fields")
    func testAdaptChipDataFields() {
        let data = AdaptChipData(
            toolCallId: "tool_adapt_1",
            action: .deploy,
            status: .running,
            resultContent: nil,
            isError: false
        )

        #expect(data.toolCallId == "tool_adapt_1")
        #expect(data.action == .deploy)
        #expect(data.status == .running)
        #expect(data.resultContent == nil)
        #expect(data.isError == false)
    }

    @Test("AdaptChipData is Equatable")
    func testAdaptChipDataEquatable() {
        let data1 = AdaptChipData(
            toolCallId: "tool_1",
            action: .deploy,
            status: .success,
            resultContent: "Deployed",
            isError: false
        )
        let data2 = AdaptChipData(
            toolCallId: "tool_1",
            action: .deploy,
            status: .success,
            resultContent: "Deployed",
            isError: false
        )
        let data3 = AdaptChipData(
            toolCallId: "tool_2",
            action: .rollback,
            status: .failed,
            resultContent: "Error",
            isError: true
        )

        #expect(data1 == data2)
        #expect(data1 != data3)
    }

    @Test("AdaptAction has all cases")
    func testAdaptActionCases() {
        let deploy = AdaptAction.deploy
        let status = AdaptAction.status
        let rollback = AdaptAction.rollback

        #expect(deploy.rawValue == "deploy")
        #expect(status.rawValue == "status")
        #expect(rollback.rawValue == "rollback")
    }

    @Test("AdaptStatus has all cases")
    func testAdaptStatusCases() {
        let running = AdaptStatus.running
        let success = AdaptStatus.success
        let failed = AdaptStatus.failed

        #expect(running.rawValue == "running")
        #expect(success.rawValue == "success")
        #expect(failed.rawValue == "failed")
    }

    // MARK: - ToolResultParser.parseAdapt Tests

    @Test("Parser extracts deploy action from arguments")
    func testParserExtractsDeployAction() {
        let tool = ToolUseData(
            toolName: "Adapt",
            toolCallId: "call_adapt_1",
            arguments: "{\"action\": \"deploy\"}",
            status: .running,
            result: nil,
            durationMs: nil
        )

        let data = ToolResultParser.parseAdapt(from: tool)

        #expect(data != nil)
        #expect(data?.action == .deploy)
        #expect(data?.status == .running)
        #expect(data?.toolCallId == "call_adapt_1")
    }

    @Test("Parser extracts status action from arguments")
    func testParserExtractsStatusAction() {
        let tool = ToolUseData(
            toolName: "Adapt",
            toolCallId: "call_adapt_2",
            arguments: "{\"action\": \"status\"}",
            status: .success,
            result: "Last deployment:\n  Status: success",
            durationMs: 50
        )

        let data = ToolResultParser.parseAdapt(from: tool)

        #expect(data != nil)
        #expect(data?.action == .status)
        #expect(data?.status == .success)
        #expect(data?.resultContent == "Last deployment:\n  Status: success")
    }

    @Test("Parser extracts rollback action from arguments")
    func testParserExtractsRollbackAction() {
        let tool = ToolUseData(
            toolName: "Adapt",
            toolCallId: "call_adapt_3",
            arguments: "{\"action\": \"rollback\"}",
            status: .success,
            result: "Rollback initiated.",
            durationMs: 100
        )

        let data = ToolResultParser.parseAdapt(from: tool)

        #expect(data != nil)
        #expect(data?.action == .rollback)
        #expect(data?.status == .success)
    }

    @Test("Parser maps error tool status to failed")
    func testParserMapsErrorStatus() {
        let tool = ToolUseData(
            toolName: "Adapt",
            toolCallId: "call_adapt_4",
            arguments: "{\"action\": \"deploy\"}",
            status: .error,
            result: "Build/test failed:\nFAIL src/foo.test.ts",
            durationMs: 30000
        )

        let data = ToolResultParser.parseAdapt(from: tool)

        #expect(data != nil)
        #expect(data?.status == .failed)
        #expect(data?.isError == true)
        #expect(data?.resultContent?.contains("FAIL") == true)
    }

    @Test("Parser defaults to deploy when action missing")
    func testParserDefaultsToDeployWhenMissing() {
        let tool = ToolUseData(
            toolName: "Adapt",
            toolCallId: "call_adapt_5",
            arguments: "{}",
            status: .running,
            result: nil,
            durationMs: nil
        )

        let data = ToolResultParser.parseAdapt(from: tool)

        #expect(data != nil)
        #expect(data?.action == .deploy)
    }

    @Test("Parser handles success status correctly")
    func testParserMapsSuccessStatus() {
        let tool = ToolUseData(
            toolName: "Adapt",
            toolCallId: "call_adapt_6",
            arguments: "{\"action\": \"deploy\"}",
            status: .success,
            result: "Build and tests passed. Deployment swap starts in 3 seconds.",
            durationMs: 120000
        )

        let data = ToolResultParser.parseAdapt(from: tool)

        #expect(data != nil)
        #expect(data?.status == .success)
        #expect(data?.isError == false)
    }
}

// MARK: - ChatSheet Adapt Integration Tests

@Suite("ChatSheet Adapt Tests")
struct ChatSheetAdaptTests {

    @Test("Adapt detail sheet has unique id per toolCallId")
    func testAdaptDetailSheetUniqueId() {
        let data1 = AdaptChipData(
            toolCallId: "adapt_1",
            action: .deploy,
            status: .running,
            resultContent: nil,
            isError: false
        )
        let data2 = AdaptChipData(
            toolCallId: "adapt_2",
            action: .status,
            status: .success,
            resultContent: "ok",
            isError: false
        )

        let sheet1 = ChatSheet.adaptDetail(data1)
        let sheet2 = ChatSheet.adaptDetail(data2)

        #expect(sheet1.id != sheet2.id)
        #expect(sheet1.id.contains("adapt_1"))
        #expect(sheet2.id.contains("adapt_2"))
    }

    @Test("Adapt detail sheet equals same data")
    func testAdaptDetailSheetEquality() {
        let data = AdaptChipData(
            toolCallId: "adapt_1",
            action: .deploy,
            status: .success,
            resultContent: "Done",
            isError: false
        )

        let sheet1 = ChatSheet.adaptDetail(data)
        let sheet2 = ChatSheet.adaptDetail(data)

        #expect(sheet1 == sheet2)
    }
}

// MARK: - SheetCoordinator Adapt Tests

@Suite("SheetCoordinator Adapt Tests")
@MainActor
struct SheetCoordinatorAdaptTests {

    @Test("showAdaptDetail creates correct sheet")
    func testShowAdaptDetailCreatesSheet() {
        let coordinator = SheetCoordinator()
        let data = AdaptChipData(
            toolCallId: "adapt_123",
            action: .deploy,
            status: .running,
            resultContent: nil,
            isError: false
        )

        coordinator.showAdaptDetail(data)

        if case .adaptDetail(let sheetData) = coordinator.activeSheet {
            #expect(sheetData.toolCallId == "adapt_123")
            #expect(sheetData.action == .deploy)
        } else {
            Issue.record("Expected adaptDetail sheet")
        }
    }
}
