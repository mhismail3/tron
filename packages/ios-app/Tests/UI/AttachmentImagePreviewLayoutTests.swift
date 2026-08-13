import CoreGraphics
import Testing
@testable import TronMobile

@Suite("Attachment image preview layout")
struct AttachmentImagePreviewLayoutTests {
    @Test("landscape photos fill their rounded fitted frame without cropping")
    func landscapePhotoFrame() {
        let frame = AttachmentImagePreviewLayout.fittedImageFrame(
            imageSize: CGSize(width: 1_000, height: 500),
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        #expect(abs(frame.width - 400) < 0.001)
        #expect(abs(frame.height - 200) < 0.001)
        #expect(abs(frame.midX - 200) < 0.001)
        #expect(abs(frame.midY - 200) < 0.001)
    }

    @Test("portrait photos remain centered clear of preview chrome")
    func portraitPhotoFrame() {
        let frame = AttachmentImagePreviewLayout.fittedImageFrame(
            imageSize: CGSize(width: 500, height: 1_000),
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        #expect(abs(frame.width - 152) < 0.001)
        #expect(abs(frame.height - 304) < 0.001)
        #expect(abs(frame.midX - 200) < 0.001)
        #expect(abs(frame.midY - 200) < 0.001)
    }

    @Test("fitted photos own rounded corners until zoom begins")
    func zoomCornerRadius() {
        #expect(
            AttachmentImagePreviewLayout.photoCornerRadius(zoomScale: 1, minimumScale: 1)
                == AttachmentImagePreviewLayout.fittedPhotoCornerRadius
        )
        #expect(AttachmentImagePreviewLayout.photoCornerRadius(zoomScale: 1.1, minimumScale: 1) == 0)
        #expect(AttachmentImagePreviewLayout.dismissButtonDiameter >= 44)
    }
}
