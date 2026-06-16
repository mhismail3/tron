import PhotosUI
import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class AttachmentMenuSheetTests: XCTestCase {
    private var noImageCapability: AttachmentCapability {
        AttachmentCapability(
            supportsImages: false,
            supportsPdfContent: false,
            supportsTextFiles: true,
            maxImageBytes: 0,
            maxDocumentBytes: 20_971_520
        )
    }

    private func render<V: View>(_ view: V) {
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    private func attachmentMenuSheet(capability: AttachmentCapability = .default) -> AttachmentMenuSheet {
        AttachmentMenuSheet(
            capability: capability,
            selectedImages: .constant([]),
            onCameraImageCaptured: { _ in },
            onDocumentPicked: { _, _, _ in },
            onDocumentSizeExceeded: nil
        )
    }

    func testDefaultAttachmentMenuExposesFunctionalAttachmentActionsOnly() {
        XCTAssertEqual(
            AttachmentMenuAction.availableActions(for: .default),
            [.camera, .photoLibrary, .files]
        )
    }

    func testAttachmentMenuHidesImageActionsWhenModelDoesNotSupportImages() {
        XCTAssertEqual(
            AttachmentMenuAction.availableActions(for: noImageCapability),
            [.files]
        )
    }

    func testAttachmentMenuActionTitlesAreTheApprovedSliceOneCommands() {
        XCTAssertEqual(AttachmentMenuAction.allCases.map(\.title), [
            "Take Photo",
            "Photo Library",
            "Choose File"
        ])
    }

    func testCompactActionSheetLayoutKeepsDefaultAttachmentActionsInOneRow() {
        let actionCount = AttachmentMenuAction.availableActions(for: .default).count

        XCTAssertEqual(actionCount, 3)
        XCTAssertEqual(CompactActionSheetLayout.columns(forItemCount: actionCount).count, 3)
        XCTAssertEqual(CompactActionSheetLayout.rowCount(forItemCount: actionCount), 1)
    }

    func testCompactActionSheetLayoutExpandsAfterThreeActions() {
        let singleRowHeight = CompactActionSheetLayout.sheetHeight(forItemCount: 3)
        let twoRowHeight = CompactActionSheetLayout.sheetHeight(forItemCount: 4)

        XCTAssertEqual(CompactActionSheetLayout.rowCount(forItemCount: 1), 1)
        XCTAssertEqual(CompactActionSheetLayout.rowCount(forItemCount: 3), 1)
        XCTAssertEqual(CompactActionSheetLayout.rowCount(forItemCount: 4), 2)
        XCTAssertGreaterThan(twoRowHeight, singleRowHeight)
    }

    func testAttachmentMenuSheetConstructs() {
        render(attachmentMenuSheet())
        render(attachmentMenuSheet(capability: noImageCapability))
    }

    func testCameraCaptureSheetConstructs() {
        render(
            CameraCaptureSheet(onImageCaptured: { _ in })
                .frame(width: 470, height: 760)
        )
    }

    func testAttachmentMenuSheetScreenshot() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TRON_ATTACHMENT_MENU_SCREENSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set TRON_ATTACHMENT_MENU_SCREENSHOT_PATH to capture the attachment menu screenshot.")
        }

        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        let actionCount = AttachmentMenuAction.availableActions(for: .default).count
        window.frame = CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: CompactActionSheetLayout.sheetHeight(forItemCount: actionCount)
        )
        let host = UIHostingController(
            rootView: attachmentMenuSheet()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tronBackground)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pngData = try XCTUnwrap(image.pngData())
        let attachment = XCTAttachment(data: pngData, uniformTypeIdentifier: "public.png")
        attachment.name = "phase1_slice_1_attachment_menu_sheet"
        attachment.lifetime = .keepAlways
        add(attachment)

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL)
        window.isHidden = true
    }
}
