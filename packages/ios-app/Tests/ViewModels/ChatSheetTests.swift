import Testing
import Foundation
@testable import TronMobile

/// Tests for ChatSheet enum and SheetCoordinator
/// Verifies sheet identification, presentation, and dismissal logic
@Suite("ChatSheet Tests")
struct ChatSheetTests {

    // MARK: - ChatSheet Enum Identity Tests

    @Test("Settings sheet has consistent id")
    func testSettingsSheetId() {
        let sheet = ChatSheet.settings

        #expect(sheet.id == "settings")
    }

    @Test("Compaction detail has consistent id")
    func testCompactionDetailId() {
        let data1 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let data2 = CompactionDetailData(tokensBefore: 200, tokensAfter: 100, reason: "other", summary: "sum")

        let sheet1 = ChatSheet.compactionDetail(data1)
        let sheet2 = ChatSheet.compactionDetail(data2)

        // All compaction sheets share same id (only one can show at a time)
        #expect(sheet1.id == sheet2.id)
        #expect(sheet1.id == "compaction")
    }

    @Test("User interaction sheet has consistent id")
    func testUserInteractionId() {
        let sheet = ChatSheet.userInteraction

        #expect(sheet.id == "userInteraction")
    }

    @Test("Notification delivery sheets with different data have different ids")
    func testNotificationDeliveryDifferentDataHaveDifferentIds() {
        let data1 = NotificationDeliveryData(
            invocationId: "invocation1",
            title: "Title 1",
            body: "Body",
            sheetContent: nil,
            status: .sending
        )
        let data2 = NotificationDeliveryData(
            invocationId: "invocation2",
            title: "Title 2",
            body: "Body",
            sheetContent: nil,
            status: .sending
        )

        let sheet1 = ChatSheet.notificationDelivery(data1)
        let sheet2 = ChatSheet.notificationDelivery(data2)

        #expect(sheet1.id != sheet2.id)
    }

    @Test("Thinking detail has consistent id regardless of content")
    func testThinkingDetailId() {
        let sheet1 = ChatSheet.thinkingDetail("content 1")
        let sheet2 = ChatSheet.thinkingDetail("content 2")

        #expect(sheet1.id == sheet2.id)
        #expect(sheet1.id == "thinking")
    }

    @Test("All sheet cases have unique base ids")
    func testAllCasesHaveUniqueBaseIds() {
        let compactionData = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let notifyData = NotificationDeliveryData(
            invocationId: "capability",
            title: "Title",
            body: "Body",
            sheetContent: nil,
            status: .sending
        )
        let capabilityData = testCapabilityInvocation(id: "capability_call", status: .success)
        let providerErrorData = ProviderErrorDetailData(
            provider: "test",
            category: "rate_limit",
            message: "Too many requests",
            suggestion: nil,
            retryable: true,
            statusCode: 429,
            errorType: nil,
            model: nil
        )

        let sheets: [ChatSheet] = [
            .settings,
            .compactionDetail(compactionData),
            .userInteraction,
            .notificationDelivery(notifyData),
            .thinkingDetail("content"),
            .capabilityInvocationDetail(capabilityData),
            .providerErrorDetail(providerErrorData)
        ]

        // Extract base ids (before any dynamic suffix)
        var baseIds = Set<String>()
        for sheet in sheets {
            let id = sheet.id
            // For ids with dynamic parts, get the prefix
            let baseId = id.components(separatedBy: "-").first ?? id
            baseIds.insert(baseId)
        }

        // Each case should have a unique base id
        #expect(baseIds.count == sheets.count)
    }

    // MARK: - CompactionDetailData Tests

    @Test("CompactionDetailData stores all fields")
    func testCompactionDetailDataFields() {
        let data = CompactionDetailData(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "Context limit reached",
            summary: "Summary text"
        )

        #expect(data.tokensBefore == 100000)
        #expect(data.tokensAfter == 50000)
        #expect(data.reason == "Context limit reached")
        #expect(data.summary == "Summary text")
    }

    @Test("CompactionDetailData with nil summary")
    func testCompactionDetailDataNilSummary() {
        let data = CompactionDetailData(
            tokensBefore: 80000,
            tokensAfter: 40000,
            reason: "Manual",
            summary: nil
        )

        #expect(data.summary == nil)
    }

    @Test("CompactionDetailData equatable")
    func testCompactionDetailDataEquatable() {
        let data1 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let data2 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "test", summary: nil)
        let data3 = CompactionDetailData(tokensBefore: 100, tokensAfter: 50, reason: "different", summary: nil)

        #expect(data1 == data2)
        #expect(data1 != data3)
    }
}

// MARK: - SheetCoordinator Tests

@Suite("SheetCoordinator Tests")
@MainActor
struct SheetCoordinatorTests {

    // MARK: - Initial State

    @Test("Initial state has no active sheet")
    func testInitialStateNoActiveSheet() {
        let coordinator = SheetCoordinator()

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Initial state has no dismiss callback")
    func testInitialStateNoDismissCallback() {
        let coordinator = SheetCoordinator()

        #expect(coordinator.onDismiss == nil)
    }

    // MARK: - Present Tests

    @Test("Present sets active sheet")
    func testPresentSetsActiveSheet() {
        let coordinator = SheetCoordinator()

        coordinator.present(.settings)

        #expect(coordinator.activeSheet == .settings)
    }

    @Test("Present with onDismiss stores callback")
    func testPresentWithOnDismissStoresCallback() {
        let coordinator = SheetCoordinator()
        var callbackCalled = false

        coordinator.present(.settings) {
            callbackCalled = true
        }

        // Callback should be stored
        #expect(coordinator.onDismiss != nil)

        // Call it to verify
        coordinator.onDismiss?()
        #expect(callbackCalled)
    }

    @Test("Present replaces current sheet")
    func testPresentReplacesCurrentSheet() {
        let coordinator = SheetCoordinator()

        coordinator.present(.settings)
        coordinator.present(.userInteraction)

        #expect(coordinator.activeSheet == .userInteraction)
    }

    @Test("Present replaces onDismiss callback")
    func testPresentReplacesOnDismissCallback() {
        let coordinator = SheetCoordinator()
        var firstCalled = false
        var secondCalled = false

        coordinator.present(.settings) { firstCalled = true }
        coordinator.present(.userInteraction) { secondCalled = true }

        coordinator.onDismiss?()

        #expect(!firstCalled)
        #expect(secondCalled)
    }

    // MARK: - Dismiss Tests

    @Test("Dismiss clears active sheet")
    func testDismissClearsActiveSheet() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)

        coordinator.dismiss()

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Dismiss when no sheet is no-op")
    func testDismissWhenNoSheetIsNoOp() {
        let coordinator = SheetCoordinator()

        coordinator.dismiss()

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Dismiss if active clears matching sheet")
    func testDismissIfActiveClearsMatchingSheet() {
        let coordinator = SheetCoordinator()
        coordinator.showUserInteraction()

        coordinator.dismissIfActive(.userInteraction)

        #expect(coordinator.activeSheet == nil)
    }

    @Test("Dismiss if active leaves other sheets alone")
    func testDismissIfActiveLeavesOtherSheetsAlone() {
        let coordinator = SheetCoordinator()
        coordinator.showSettings()

        coordinator.dismissIfActive(.userInteraction)

        #expect(coordinator.activeSheet == .settings)
    }

    @Test("Dismiss does not clear onDismiss callback")
    func testDismissCallsAndClearsOnDismissCallback() {
        let coordinator = SheetCoordinator()
        var callbackCalled = false

        coordinator.present(.settings) { callbackCalled = true }
        coordinator.dismiss()

        // dismiss() should call the callback and clear it
        #expect(callbackCalled)
        #expect(coordinator.onDismiss == nil)
    }

    // MARK: - Convenience Method Tests

    @Test("showSettings creates settings sheet")
    func testShowSettingsCreatesSettingsSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showSettings()

        #expect(coordinator.activeSheet == .settings)
    }

    @Test("showCompactionDetail creates compaction sheet with data")
    func testShowCompactionDetailCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showCompactionDetail(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "Context limit",
            summary: "Summary"
        )

        if case .compactionDetail(let data) = coordinator.activeSheet {
            #expect(data.tokensBefore == 100000)
            #expect(data.tokensAfter == 50000)
            #expect(data.reason == "Context limit")
            #expect(data.summary == "Summary")
        } else {
            Issue.record("Expected compactionDetail sheet")
        }
    }

    @Test("showUserInteraction creates ask user question sheet")
    func testShowUserInteractionCreatesSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showUserInteraction()

        #expect(coordinator.activeSheet == .userInteraction)
    }

    @Test("showNotificationDelivery creates notification delivery sheet with data")
    func testShowNotificationDeliveryCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()
        let data = NotificationDeliveryData(
            invocationId: "invocation123",
            title: "Notification",
            body: "Body text",
            sheetContent: nil,
            status: .sending
        )

        coordinator.showNotificationDelivery(data)

        if case .notificationDelivery(let sheetData) = coordinator.activeSheet {
            #expect(sheetData.invocationId == "invocation123")
            #expect(sheetData.title == "Notification")
        } else {
            Issue.record("Expected notificationDelivery sheet")
        }
    }

    @Test("showThinkingDetail creates thinking sheet with content")
    func testShowThinkingDetailCreatesCorrectSheet() {
        let coordinator = SheetCoordinator()

        coordinator.showThinkingDetail("Thinking content here")

        if case .thinkingDetail(let content) = coordinator.activeSheet {
            #expect(content == "Thinking content here")
        } else {
            Issue.record("Expected thinkingDetail sheet")
        }
    }

    // MARK: - Binding Helper Tests

    @Test("isPresented returns true when sheet active")
    func testIsPresentedTrueWhenActive() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)

        #expect(coordinator.isPresented)
    }

    @Test("isPresented returns false when no sheet")
    func testIsPresentedFalseWhenNoSheet() {
        let coordinator = SheetCoordinator()

        #expect(!coordinator.isPresented)
    }
}
