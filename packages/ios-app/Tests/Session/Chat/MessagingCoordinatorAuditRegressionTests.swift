import XCTest
import PhotosUI
import SwiftUI
@testable import TronMobile

/// Focused regression coverage for the Slice 4 audit findings around local
/// chat affordances. Kept separate from the broad coordinator suite so the
/// budget guard can keep flagging oversized test files.
@MainActor
final class MessagingCoordinatorAuditRegressionTests: XCTestCase {
    var coordinator: MessagingCoordinator!
    var mockContext: MockMessagingContext!

    override func setUp() async throws {
        mockContext = MockMessagingContext()
        coordinator = MessagingCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    func testSendMessageClearsServerSendFailureOnLaterSuccessfulSend() async {
        mockContext.inputText = "Prompt that fails"
        mockContext.sendPromptShouldFail = true
        await coordinator.sendMessage(context: mockContext)
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("agent.prompt.send.failed"))

        mockContext.inputText = "Prompt that succeeds"
        mockContext.sendPromptShouldFail = false
        await coordinator.sendMessage(context: mockContext)

        XCTAssertFalse(mockContext.localErrorDedupKeys.contains("agent.prompt.send.failed"))
        XCTAssertTrue(mockContext.clearLocalNotificationsCalled)
    }

    func testSendMessageFailureClearsProcessingFlagsAndShowsLocalNotification() async {
        mockContext.inputText = "Prompt that fails before server acceptance"
        let attachment = Attachment(
            type: .image,
            data: Data([0x01, 0x02]),
            mimeType: "image/jpeg",
            fileName: "retry.jpg",
            originalSize: 2
        )
        mockContext.attachments = [attachment]
        mockContext.currentTurn = 4
        mockContext.sendPromptShouldFail = true

        await coordinator.sendMessage(context: mockContext)

        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, false)
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("agent.prompt.send.failed"))
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not send message")
        XCTAssertEqual(mockContext.inputText, "Prompt that fails before server acceptance")
        XCTAssertEqual(mockContext.attachments, [attachment])
        XCTAssertEqual(mockContext.currentTurn, 4)
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
        XCTAssertEqual(mockContext.removedMessageIds.count, 1)
    }

    func testSendFailurePreservesDraftEditedWhileSubscriptionSuspends() async {
        mockContext.inputText = "original prompt"
        mockContext.suspendLiveEventSubscription = true
        mockContext.sendPromptShouldFail = true
        let subscriptionSuspended = expectation(description: "subscription suspended")
        mockContext.onLiveEventSubscriptionSuspended = { subscriptionSuspended.fulfill() }

        let send = Task { @MainActor in
            await self.coordinator.sendMessage(context: self.mockContext)
        }
        await fulfillment(of: [subscriptionSuspended], timeout: 1.0)
        mockContext.inputText = "newer draft"
        mockContext.resumeAllLiveEventSubscriptions()
        await send.value

        XCTAssertEqual(mockContext.sendPromptCallCount, 1)
        XCTAssertEqual(mockContext.lastSentText, "original prompt")
        XCTAssertEqual(mockContext.inputText, "newer draft")
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testAcceptedSendPreservesDraftEditedWhileSubscriptionSuspends() async {
        mockContext.inputText = "original prompt"
        mockContext.suspendLiveEventSubscription = true
        let subscriptionSuspended = expectation(description: "subscription suspended")
        mockContext.onLiveEventSubscriptionSuspended = { subscriptionSuspended.fulfill() }

        let send = Task { @MainActor in
            await self.coordinator.sendMessage(context: self.mockContext)
        }
        await fulfillment(of: [subscriptionSuspended], timeout: 1.0)
        mockContext.inputText += "newer draft"
        mockContext.resumeAllLiveEventSubscriptions()
        await send.value

        XCTAssertEqual(mockContext.sendPromptCallCount, 1)
        XCTAssertEqual(mockContext.lastSentText, "original prompt")
        XCTAssertEqual(mockContext.inputText, "newer draft")
        XCTAssertEqual(mockContext.appendedMessages.first?.content.textContent, "original prompt")
    }

    func testAcceptedTextSendLeavesPendingPhotoSelectionWithProcessingOwner() async {
        mockContext.inputText = "send while photo conversion is pending"
        mockContext.selectedImages = [PhotosPickerItem(itemIdentifier: "pending-photo")]
        mockContext.suspendLiveEventSubscription = true
        let subscriptionSuspended = expectation(description: "subscription suspended")
        mockContext.onLiveEventSubscriptionSuspended = { subscriptionSuspended.fulfill() }

        let send = Task { @MainActor in
            await self.coordinator.sendMessage(context: self.mockContext)
        }
        await fulfillment(of: [subscriptionSuspended], timeout: 1.0)
        mockContext.resumeAllLiveEventSubscriptions()
        await send.value

        XCTAssertEqual(mockContext.sendPromptCallCount, 1)
        XCTAssertNil(mockContext.lastSentAttachments)
        XCTAssertEqual(mockContext.selectedImages.map(\.itemIdentifier), ["pending-photo"])
    }

    func testAcceptedSendConsumesOnlySnapshottedAttachments() async {
        let submitted = Attachment(
            type: .image,
            data: Data([0x01]),
            mimeType: "image/jpeg",
            fileName: "submitted.jpg",
            originalSize: 1
        )
        let newerDraft = Attachment(
            type: .image,
            data: Data([0x02]),
            mimeType: "image/jpeg",
            fileName: "newer-draft.jpg",
            originalSize: 1
        )
        mockContext.inputText = "send the prepared attachment"
        mockContext.attachments = [submitted]
        mockContext.suspendLiveEventSubscription = true
        let subscriptionSuspended = expectation(description: "subscription suspended")
        mockContext.onLiveEventSubscriptionSuspended = { subscriptionSuspended.fulfill() }

        let send = Task { @MainActor in
            await self.coordinator.sendMessage(context: self.mockContext)
        }
        await fulfillment(of: [subscriptionSuspended], timeout: 1.0)
        mockContext.attachments.append(newerDraft)
        mockContext.resumeAllLiveEventSubscriptions()
        await send.value

        XCTAssertEqual(mockContext.lastSentAttachments?.map(\.fileName), ["submitted.jpg"])
        XCTAssertEqual(mockContext.attachments, [newerDraft])
    }

    func testRetryMessageDoesNotSendWhenLiveEventSubscriptionFails() async {
        mockContext.ensureLiveEventSubscriptionShouldFail = true

        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertFalse(mockContext.sendPromptCalled)
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertTrue(mockContext.showErrorCalled)
    }

    func testRetryMessageSharesProcessingAndStreamingSetupWithoutConsumingComposer() async {
        mockContext.inputText = "draft stays put"

        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertTrue(mockContext.isProcessing)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, true)
        XCTAssertTrue(mockContext.streamingManagerResetCalled)
        XCTAssertEqual(mockContext.lastSessionActivityPrompt, "retry this prompt")
        XCTAssertEqual(mockContext.inputText, "draft stays put")
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testRetryMessageClearsStaleRetryErrorAfterSuccess() async {
        mockContext.sendPromptShouldFail = true
        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("turn.retry.failed"))

        mockContext.sendPromptShouldFail = false
        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertFalse(mockContext.localErrorDedupKeys.contains("turn.retry.failed"))
        XCTAssertTrue(mockContext.clearLocalNotificationsCalled)
    }

    func testRetryMessageFailureClearsProcessingFlagsAndShowsLocalNotification() async {
        mockContext.inputText = "draft stays put"
        mockContext.sendPromptShouldFail = true

        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(mockContext.lastSentText, "retry this prompt")
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, false)
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("turn.retry.failed"))
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not retry")
        XCTAssertEqual(mockContext.inputText, "draft stays put")
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testRapidStopRequestsIssueOneAbortAndAwaitTerminalLifecycle() async {
        mockContext.agentPhase = .processing
        mockContext.suspendAbort = true
        let abortSuspended = expectation(description: "abort suspended")
        mockContext.onAbortSuspended = { abortSuspended.fulfill() }

        let firstStop = Task { @MainActor in
            await self.coordinator.abortAgent(context: self.mockContext)
        }
        await fulfillment(of: [abortSuspended], timeout: 1.0)
        await coordinator.abortAgent(context: mockContext)

        XCTAssertEqual(mockContext.abortAgentCallCount, 1)
        XCTAssertEqual(mockContext.agentPhase, .stopping)
        XCTAssertNil(mockContext.lastSessionProcessingValue)

        mockContext.resumeAllAborts()
        await firstStop.value

        XCTAssertEqual(mockContext.agentPhase, .stopping)
    }

    func testUnmatchedStopPreservesActiveTurnAndCanBeRetried() async {
        mockContext.agentPhase = .processing
        mockContext.abortResult = false

        await coordinator.abortAgent(context: mockContext)

        XCTAssertEqual(mockContext.abortAgentCallCount, 1)
        XCTAssertEqual(mockContext.agentPhase, .processing)
        XCTAssertNil(mockContext.lastSessionProcessingValue)
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)

        mockContext.abortResult = true
        await coordinator.abortAgent(context: mockContext)

        XCTAssertEqual(mockContext.abortAgentCallCount, 2)
        XCTAssertEqual(mockContext.agentPhase, .stopping)
    }

    func testCancelledStopWaiterDoesNotStrandStoppingPhase() async {
        mockContext.agentPhase = .processing
        mockContext.suspendAbort = true
        let abortSuspended = expectation(description: "abort suspended")
        mockContext.onAbortSuspended = { abortSuspended.fulfill() }

        let stop = Task { @MainActor in
            await self.coordinator.abortAgent(context: self.mockContext)
        }
        await fulfillment(of: [abortSuspended], timeout: 1.0)
        stop.cancel()
        mockContext.resumeAllAborts()
        await stop.value

        XCTAssertEqual(mockContext.abortAgentCallCount, 1)
        XCTAssertEqual(mockContext.agentPhase, .processing)
    }

    func testStopDuringPromptAdmissionRunsOnceAfterAcknowledgement() async {
        mockContext.inputText = "prompt awaiting acknowledgement"
        mockContext.suspendSendPrompt = true
        let promptSuspended = expectation(description: "prompt suspended")
        mockContext.onSendPromptSuspended = { promptSuspended.fulfill() }

        let send = Task { @MainActor in
            await self.coordinator.sendMessage(context: self.mockContext)
        }
        await fulfillment(of: [promptSuspended], timeout: 1.0)
        await coordinator.abortAgent(context: mockContext)
        await coordinator.abortAgent(context: mockContext)

        XCTAssertEqual(mockContext.abortAgentCallCount, 0)
        XCTAssertEqual(mockContext.agentPhase, .processing)

        mockContext.resumeAllSendPrompts()
        await send.value

        XCTAssertEqual(mockContext.abortAgentCallCount, 1)
        XCTAssertEqual(mockContext.agentPhase, .stopping)
    }

    func testQueuedStopIsDiscardedWhenPromptAdmissionFails() async {
        mockContext.inputText = "prompt rejected before acceptance"
        mockContext.suspendSendPrompt = true
        mockContext.sendPromptShouldFail = true
        let promptSuspended = expectation(description: "prompt suspended")
        mockContext.onSendPromptSuspended = { promptSuspended.fulfill() }

        let send = Task { @MainActor in
            await self.coordinator.sendMessage(context: self.mockContext)
        }
        await fulfillment(of: [promptSuspended], timeout: 1.0)
        await coordinator.abortAgent(context: mockContext)
        mockContext.resumeAllSendPrompts()
        await send.value

        XCTAssertEqual(mockContext.abortAgentCallCount, 0)
        XCTAssertEqual(mockContext.agentPhase, .idle)
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
    }
}
