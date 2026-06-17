import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class AttachmentMenuTests: XCTestCase {
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

    func testAttachmentMenuActionTitlesAreTheApprovedCommands() {
        XCTAssertEqual(AttachmentMenuAction.allCases.map(\.title), [
            "Camera",
            "Photos",
            "Files"
        ])
    }

    func testNativeAttachmentMenuButtonConstructs() {
        render(
            GlassAttachmentButton(
                isDisabled: false,
                attachmentCapability: .default,
                onSelect: { _ in },
                buttonSize: 40
            )
        )
        render(
            GlassAttachmentButton(
                isDisabled: true,
                attachmentCapability: noImageCapability,
                onSelect: { _ in },
                buttonSize: 40
            )
        )
    }

    func testCameraCaptureSheetConstructs() {
        render(
            CameraCaptureSheet(onImageCaptured: { _ in })
                .frame(width: 470, height: 760)
        )
    }
}
