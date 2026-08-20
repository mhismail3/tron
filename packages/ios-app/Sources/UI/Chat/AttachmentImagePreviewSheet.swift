import SwiftUI
import UIKit

/// The historical chat photo preview: one medium-height, edge-to-edge media
/// sheet with native pinch/double-tap zoom and concentric sheet corners.
struct AttachmentImagePreviewSheet: View {
    let image: UIImage
    var title = "Photo"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                AttachmentZoomableImagePreview(
                    image: image,
                    onZoomStateChange: { isZoomed = $0 }
                )
                .ignoresSafeArea(.container, edges: .all)
                .clipShape(viewportShape)
                .contentShape(viewportShape)
                .padding(AttachmentImagePreviewLayout.viewportInset)
                .accessibilityLabel("Preview photo")

                previewChrome
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .all)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        // The system presentation owns the device-relative outer radius. The
        // inset media viewport follows it concentrically instead of imposing a
        // fixed app radius that can diverge on different phones.
        .presentationCornerRadius(nil)
        .presentationContentInteraction(.scrolls)
    }

    private var viewportShape: ConcentricRectangle {
        ConcentricRectangle(
            uniformTopCorners: .concentric(
                minimum: .fixed(AttachmentImagePreviewLayout.minimumViewportTopCornerRadius)
            ),
            uniformBottomCorners: .concentric
        )
    }

    private var previewChrome: some View {
        let edgeInset = AttachmentImagePreviewLayout.chromeEdgeInset

        return ZStack(alignment: .topTrailing) {
            Text(title)
                .font(TronTypography.button)
                .foregroundStyle(Color.tronEmerald)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, AttachmentImagePreviewLayout.dismissButtonDiameter + edgeInset)
                .frame(
                    maxWidth: .infinity,
                    minHeight: AttachmentImagePreviewLayout.dismissButtonDiameter
                )
                .opacity(isZoomed ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isZoomed)
                .accessibilityHidden(isZoomed)
                .allowsHitTesting(false)

            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronEmerald)
                    .frame(
                        width: AttachmentImagePreviewLayout.dismissButtonDiameter,
                        height: AttachmentImagePreviewLayout.dismissButtonDiameter
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(Color.tronEmerald.opacity(0.08)).interactive(),
                in: .circle
            )
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, edgeInset)
        .padding(.top, edgeInset)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Geometry contract retained from the pre-gateway image preview.
enum AttachmentImagePreviewLayout {
    static let topChromeCornerReferenceRadius: CGFloat = 40
    static let viewportInset: CGFloat = 8
    static let dismissButtonDiameter: CGFloat = 44
    static let fittedPhotoCornerRadius: CGFloat = 18
    static let minimumViewportTopCornerRadius: CGFloat = 32

    static var chromeEdgeInset: CGFloat {
        max(0, topChromeCornerReferenceRadius - dismissButtonDiameter * 0.5)
    }

    static func photoCornerRadius(zoomScale: CGFloat, minimumScale: CGFloat) -> CGFloat {
        zoomScale <= minimumScale + 0.01 ? fittedPhotoCornerRadius : 0
    }

    /// Keeps a fitted photo centered with equal clearance for the overlay chrome.
    /// The returned frame has the photo's aspect ratio, so its pixels fill its
    /// rounded rectangle without cropping.
    static func fittedImageFrame(imageSize: CGSize, in viewportBounds: CGRect) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportBounds.width > 0,
              viewportBounds.height > 0 else {
            return viewportBounds
        }

        let desiredChromeInset = min(68, max(48, viewportBounds.height * 0.10))
        let verticalInset = min(desiredChromeInset, max(0, (viewportBounds.height - 1) * 0.5))
        let fittedBounds = viewportBounds.insetBy(dx: 0, dy: verticalInset)
        let scale = min(
            fittedBounds.width / imageSize.width,
            fittedBounds.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: viewportBounds.midX - size.width * 0.5,
            y: viewportBounds.midY - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }
}

private struct AttachmentZoomableImagePreview: UIViewRepresentable {
    let image: UIImage
    let onZoomStateChange: (Bool) -> Void

    func makeUIView(context: Context) -> AttachmentImageZoomScrollView {
        AttachmentImageZoomScrollView()
    }

    func updateUIView(_ scrollView: AttachmentImageZoomScrollView, context: Context) {
        scrollView.onZoomStateChange = onZoomStateChange
        scrollView.setImage(image)
    }
}

private final class AttachmentImageZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onZoomStateChange: ((Bool) -> Void)?

    private let zoomContentView = UIView()
    private let imageView = UIImageView()
    private var viewportSize = CGSize.zero
    private var reportedZoomState = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        clipsToBounds = true

        zoomContentView.backgroundColor = .clear
        addSubview(zoomContentView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = AttachmentImagePreviewLayout.fittedPhotoCornerRadius
        imageView.layer.cornerCurve = .continuous
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = "Preview photo"
        imageView.accessibilityHint = "Pinch or double tap to zoom"
        zoomContentView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        setZoomScale(minimumZoomScale, animated: false)
        contentOffset = .zero
        imageView.image = image
        reportZoomState(false)
        updatePanOwnership()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        if viewportSize != bounds.size {
            viewportSize = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            zoomContentView.transform = .identity
            zoomContentView.frame = bounds
            contentSize = bounds.size
            contentOffset = .zero
            reportZoomState(false)
            updatePanOwnership()
        }
        imageView.frame = imageView.image.map {
            AttachmentImagePreviewLayout.fittedImageFrame(imageSize: $0.size, in: zoomContentView.bounds)
        } ?? zoomContentView.bounds
        updateImageCornerMask()
        centerZoomContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomContentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateImageCornerMask()
        centerZoomContent()
        updatePanOwnership()
        reportZoomState(zoomScale > minimumZoomScale + 0.01)
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        reportZoomState(scale > minimumZoomScale + 0.01)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportZoomState(zoomScale > minimumZoomScale + 0.01)
    }

    private func reportZoomState(_ isZoomed: Bool) {
        guard isZoomed != reportedZoomState else { return }
        reportedZoomState = isZoomed
        onZoomStateChange?(isZoomed)
    }

    private func updatePanOwnership() {
        // At fitted scale the native sheet keeps drag-to-dismiss ownership.
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale + 0.01
    }

    private func updateImageCornerMask() {
        imageView.layer.cornerRadius = AttachmentImagePreviewLayout.photoCornerRadius(
            zoomScale: zoomScale,
            minimumScale: minimumZoomScale
        )
    }

    private func centerZoomContent() {
        let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
        let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
        zoomContentView.center = CGPoint(
            x: contentSize.width * 0.5 + offsetX,
            y: contentSize.height * 0.5 + offsetY
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        let targetScale = min(2.5, maximumZoomScale)
        let location = recognizer.location(in: zoomContentView)
        let targetSize = CGSize(
            width: bounds.width / targetScale,
            height: bounds.height / targetScale
        )
        zoom(
            to: CGRect(
                x: location.x - targetSize.width * 0.5,
                y: location.y - targetSize.height * 0.5,
                width: targetSize.width,
                height: targetSize.height
            ),
            animated: true
        )
    }
}
