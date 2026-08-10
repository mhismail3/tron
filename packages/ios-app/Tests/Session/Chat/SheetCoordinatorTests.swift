import XCTest
@testable import TronMobile

/// Tests for SheetCoordinator — lifecycle, callbacks, convenience methods
@MainActor
final class SheetCoordinatorLifecycleTests: XCTestCase {

    // MARK: - Present / Dismiss

    func testPresentSetsActiveSheet() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        XCTAssertEqual(coordinator.activeSheet, .settings)
        XCTAssertTrue(coordinator.isPresented)
    }

    func testDismissClearsActiveSheet() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss()
        XCTAssertNil(coordinator.activeSheet)
        XCTAssertFalse(coordinator.isPresented)
    }

    // MARK: - Replacement ownership

    func testReplacementDoesNotRetainPreviousSheetPayload() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.present(.thinkingDetail("details"))
        XCTAssertEqual(coordinator.activeSheet, .thinkingDetail("details"))
    }

    func testDismissRetainsNoSheetPayload() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss()
        XCTAssertNil(coordinator.activeSheet)
    }

    // MARK: - onDismiss Callback

    func testDismissCallsOnDismissCallback() {
        let coordinator = SheetCoordinator()
        var callbackFired = false
        coordinator.present(.settings) {
            callbackFired = true
        }
        coordinator.dismiss()
        XCTAssertTrue(callbackFired, "onDismiss callback should be called when dismiss() is invoked")
    }

    func testDismissNilsOutOnDismissAfterCalling() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings) { }
        coordinator.dismiss()
        XCTAssertNil(coordinator.onDismiss, "onDismiss should be cleared after dismissal")
    }

    func testDismissWithNilOnDismissDoesNotCrash() {
        let coordinator = SheetCoordinator()
        coordinator.present(.settings)
        coordinator.dismiss() // No onDismiss set — should not crash
    }

    // MARK: - Convenience Methods

    func testShowSettings() {
        let coordinator = SheetCoordinator()
        coordinator.showSettings()
        XCTAssertEqual(coordinator.activeSheet, .settings)
    }

    func testShowSessionContext() {
        let coordinator = SheetCoordinator()
        coordinator.showSessionContext()
        XCTAssertEqual(coordinator.activeSheet, .sessionContext)
    }

    func testShowThinkingDetail() {
        let coordinator = SheetCoordinator()
        coordinator.showThinkingDetail("Thinking")
        XCTAssertEqual(coordinator.activeSheet, .thinkingDetail("Thinking"))
    }

    func testShowImagePreviewUsesLoadedAttachmentIdentityAndBytes() throws {
        let coordinator = SheetCoordinator()
        let attachmentId = UUID()
        let attachment = Attachment(
            id: attachmentId,
            type: .image,
            data: Data([0x01, 0x02, 0x03]),
            mimeType: "image/jpeg",
            fileName: "camera-photo.jpg"
        )

        coordinator.showImagePreview(ChatImagePreviewData(attachment: attachment))

        guard case .imagePreview(let preview) = coordinator.activeSheet else {
            return XCTFail("Expected image preview sheet")
        }
        XCTAssertEqual(preview.id, "attachment-\(attachmentId.uuidString)")
        XCTAssertEqual(preview.items.map(\.data), [attachment.data])
        XCTAssertEqual(preview.initialItemID, preview.items[0].id)
        XCTAssertEqual(preview.initialIndex, 0)
        XCTAssertEqual(preview.title, "Photo")
        XCTAssertEqual(preview.items[0].accessibilityLabel, "Preview camera-photo.jpg")
    }

    func testImagePreviewGalleryKeepsSiblingPhotosAndSelectedOrder() throws {
        let first = Attachment(
            type: .image,
            data: Data([0x01]),
            mimeType: "image/jpeg",
            fileName: "first.jpg"
        )
        let document = Attachment(
            type: .document,
            data: Data([0x02]),
            mimeType: "text/plain",
            fileName: "notes.txt"
        )
        let second = Attachment(
            type: .image,
            data: Data([0x03]),
            mimeType: "image/jpeg",
            fileName: "second.jpg"
        )

        let preview = ChatImagePreviewData(
            attachments: [first, document, second],
            selected: second
        )

        XCTAssertEqual(preview.items.map(\.id), [
            "attachment-\(first.id.uuidString)",
            "attachment-\(second.id.uuidString)",
        ])
        XCTAssertEqual(preview.initialItemID, "attachment-\(second.id.uuidString)")
        XCTAssertEqual(preview.initialIndex, 1)
        XCTAssertEqual(preview.items.map(\.data), [first.data, second.data])
    }

    func testImagePreviewTitleReturnsOnlyAfterZoomEndsAtFittedScale() {
        var state = ImagePreviewZoomTitleState()

        XCTAssertNil(state.zoomChanged(scale: 1, minimumScale: 1))
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.zoomChanged(scale: 1.02, minimumScale: 1), true)
        XCTAssertTrue(state.isHidden)

        // Returning to fitted scale during an active pinch must not flash the
        // title before the gesture settles.
        XCTAssertNil(state.zoomChanged(scale: 1, minimumScale: 1))
        XCTAssertTrue(state.isHidden)
        XCTAssertEqual(state.zoomEnded(scale: 1, minimumScale: 1), false)
        XCTAssertFalse(state.isHidden)
    }

    func testImagePreviewFitIsCenteredInTheCompleteSheetViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 574, height: 644)
        let portrait = CGSize(width: 3_024, height: 4_032)

        let frame = ImagePreviewViewportLayout.fittedImageFrame(
            imageSize: portrait,
            in: viewport
        )

        XCTAssertEqual(frame.midX, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, viewport.midY, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX)
        XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX)
        XCTAssertGreaterThan(frame.minY, viewport.minY)
        XCTAssertLessThan(frame.maxY, viewport.maxY)
        XCTAssertEqual(frame.width / frame.height, 0.75, accuracy: 0.001)

        // At ordinary pinch scale the centered fitted image naturally expands
        // into both chrome regions without changing the scroll-view viewport.
        XCTAssertGreaterThan(frame.height * 1.30, viewport.height)
    }

    func testImagePreviewFitKeepsLandscapePhotosCentered() {
        let viewport = CGRect(x: 0, y: 0, width: 574, height: 644)
        let landscape = CGSize(width: 4_032, height: 3_024)

        let frame = ImagePreviewViewportLayout.fittedImageFrame(
            imageSize: landscape,
            in: viewport
        )

        XCTAssertEqual(frame.midX, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, viewport.midY, accuracy: 0.001)
        XCTAssertEqual(frame.width, viewport.width, accuracy: 0.001)
        XCTAssertEqual(frame.width / frame.height, 4.0 / 3.0, accuracy: 0.001)
    }

    func testImagePreviewChromeAndViewportStayConcentricWithTheSheet() {
        XCTAssertEqual(
            ImagePreviewViewportLayout.viewportCornerRadius
                + ImagePreviewViewportLayout.viewportInset,
            ImagePreviewViewportLayout.sheetCornerRadius,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ImagePreviewViewportLayout.chromeEdgeInset
                + ImagePreviewViewportLayout.dismissButtonDiameter * 0.5,
            ImagePreviewViewportLayout.sheetCornerRadius,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(ImagePreviewViewportLayout.dismissButtonDiameter, 44)
    }

    func testImagePreviewUsesOneOuterCornerMaskWhileZoomed() {
        XCTAssertEqual(
            ImagePreviewViewportLayout.photoCornerRadius(
                zoomScale: 1,
                minimumScale: 1
            ),
            ImagePreviewViewportLayout.fittedPhotoCornerRadius,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ImagePreviewViewportLayout.photoCornerRadius(
                zoomScale: 1.02,
                minimumScale: 1
            ),
            0,
            accuracy: 0.001
        )
    }

    func testUserInputWaitsForCurrentSheetThenPresents() throws {
        let coordinator = SheetCoordinator()
        let request = UserInputRequest(
            invocationId: "question-1",
            questions: [UserInputQuestion(
                header: "Format",
                id: "format",
                question: "Which format?",
                options: [
                    UserInputOption(label: "Markdown", description: "Markdown file"),
                    UserInputOption(label: "HTML", description: "HTML file")
                ]
            )],
            answers: [],
            status: .pending
        )
        coordinator.showSettings()

        coordinator.showUserInput(request)

        XCTAssertEqual(coordinator.activeSheet, .settings)
        coordinator.presentationDidDismiss()
        XCTAssertEqual(coordinator.activeSheet, .userInput(request))
    }

    func testResolvedUserInputDoesNotPresentAfterAnotherSheetDismisses() {
        let coordinator = SheetCoordinator()
        let request = UserInputRequest(
            invocationId: "question-1",
            questions: [],
            answers: [],
            status: .pending
        )
        coordinator.showSettings()
        coordinator.showUserInput(request)

        coordinator.clearUserInput()
        coordinator.presentationDidDismiss()

        XCTAssertNil(coordinator.activeSheet)
    }

    func testPendingUserInputDraftSurvivesSheetDismissalUntilSubmission() throws {
        let coordinator = SheetCoordinator()
        let request = UserInputRequest(
            invocationId: "question-draft",
            questions: [UserInputQuestion(
                header: "Format",
                id: "format",
                question: "Which format?",
                options: [
                    UserInputOption(label: "Markdown", description: "Markdown file"),
                    UserInputOption(label: "HTML", description: "HTML file"),
                ]
            )],
            answers: [],
            status: .pending
        )
        var draft = coordinator.userInputDraft(for: request)
        draft.selectedLabels["format"] = "Markdown"
        coordinator.updateUserInputDraft(draft, invocationId: request.invocationId)

        coordinator.showUserInput(request)
        coordinator.dismiss()

        XCTAssertEqual(
            coordinator.userInputDraft(for: request).selectedLabels["format"],
            "Markdown"
        )
        coordinator.clearUserInputDraft(invocationId: request.invocationId)
        XCTAssertNil(coordinator.userInputDraft(for: request).selectedLabels["format"])
    }

}
