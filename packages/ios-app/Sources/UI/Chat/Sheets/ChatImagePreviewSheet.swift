import SwiftUI
import UIKit

/// Standard chat sheet for inspecting one or more image attachments without
/// leaving the conversation. The bytes are already local, while decoding stays
/// off the main actor so paging through large images cannot stall the chat.
struct ChatImagePreviewSheet: View {
    let preview: ChatImagePreviewData

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: String
    @State private var isSelectedImageZoomed = false

    init(preview: ChatImagePreviewData) {
        self.preview = preview
        _selectedItemID = State(initialValue: preview.initialItemID)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                TabView(selection: $selectedItemID) {
                    ForEach(Array(preview.items.enumerated()), id: \.element.id) { index, item in
                        ChatImagePreviewPage(
                            item: item,
                            shouldLoad: abs(index - selectedIndex) <= 1,
                            onZoomStateChange: { isZoomed in
                                guard selectedItemID == item.id else { return }
                                isSelectedImageZoomed = isZoomed
                            }
                        )
                        .ignoresSafeArea(.container, edges: .all)
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(.container, edges: .all)
                .clipShape(viewportShape)
                .contentShape(viewportShape)
                .padding(8)
                .accessibilityValue(pageAccessibilityValue)

                previewChrome(topInset: geometry.safeAreaInsets.top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .all)
        .onChange(of: selectedItemID) { _, _ in
            isSelectedImageZoomed = false
        }
        .adaptivePresentationDetents([.medium], ipadSizing: .compactForm)
        .presentationContentInteraction(.scrolls)
    }

    private var viewportShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private func previewChrome(topInset: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(sheetTitle)
                .font(TronTypography.button)
                .foregroundStyle(.tronEmerald)
                .frame(maxWidth: .infinity, minHeight: 52)
                .opacity(isSelectedImageZoomed ? 0 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.16),
                    value: isSelectedImageZoomed
                )
                .accessibilityHidden(isSelectedImageZoomed)
                .allowsHitTesting(false)

            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(Color.tronEmerald.opacity(0.08)).interactive(),
                in: .circle
            )
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, max(10, topInset + 8))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var selectedIndex: Int {
        preview.items.firstIndex { $0.id == selectedItemID } ?? preview.initialIndex
    }

    private var sheetTitle: String {
        guard preview.items.count > 1 else { return preview.title }
        return "Photo \(selectedIndex + 1) of \(preview.items.count)"
    }

    private var pageAccessibilityValue: String {
        guard preview.items.count > 1 else { return "1 photo" }
        return "Photo \(selectedIndex + 1) of \(preview.items.count)"
    }
}

private struct ChatImagePreviewPage: View {
    let item: ChatImagePreviewItem
    let shouldLoad: Bool
    let onZoomStateChange: (Bool) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    NativeZoomableImagePreview(
                        image: image,
                        accessibilityLabel: item.accessibilityLabel,
                        onZoomStateChange: onZoomStateChange
                    )
                    .transition(.opacity)
                } else if didFail {
                    unavailableState
                } else {
                    SheetLoadingState(label: "Loading photo…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: decodeRequest(for: geometry.size)) {
                await loadImage(fitting: geometry.size)
            }
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(TronTypography.sans(size: 30, weight: .medium))
                .foregroundStyle(.tronWarning)
            Text("Photo unavailable")
                .font(TronTypography.sans(
                    size: TronTypography.sizeBody,
                    weight: .semibold
                ))
                .foregroundStyle(.tronTextPrimary)
            Text("The saved image could not be decoded.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private func decodeRequest(for availableSize: CGSize) -> PreviewDecodeRequest {
        PreviewDecodeRequest(
            itemID: item.id,
            width: Int(availableSize.width.rounded()),
            height: Int(availableSize.height.rounded()),
            shouldLoad: shouldLoad
        )
    }

    @MainActor
    private func loadImage(fitting availableSize: CGSize) async {
        guard shouldLoad else {
            image = nil
            didFail = false
            return
        }

        didFail = false
        let boundedSize = CGSize(
            width: max(availableSize.width, 320),
            height: max(availableSize.height, 320)
        )
        let decoded = await DecodedImageView.decodeImage(
            item.data,
            fitting: boundedSize,
            scale: min(max(displayScale, 1), 3)
        )
        guard !Task.isCancelled else { return }
        if reduceMotion || image != nil {
            image = decoded
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                image = decoded
            }
        }
        didFail = decoded == nil
    }
}

private struct PreviewDecodeRequest: Hashable {
    let itemID: String
    let width: Int
    let height: Int
    let shouldLoad: Bool
}

/// Geometry contract for the immersive media viewport. The scroll view owns
/// the complete sheet rectangle; at fitted scale, equal top and bottom chrome
/// protection keeps the photo centered in the sheet rather than below its
/// controls. Zoom then expands naturally into those protected regions without
/// resizing (and therefore resetting) the native zoom view mid-gesture.
enum ImagePreviewViewportLayout {
    static func fittedImageFrame(imageSize: CGSize, in viewportBounds: CGRect) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportBounds.width > 0,
              viewportBounds.height > 0 else {
            return viewportBounds
        }

        let desiredChromeInset = min(
            68,
            max(48, viewportBounds.height * 0.10)
        )
        let verticalInset = min(
            desiredChromeInset,
            max(0, (viewportBounds.height - 1) * 0.5)
        )
        let fittedBounds = viewportBounds.insetBy(dx: 0, dy: verticalInset)
        let scale = min(
            fittedBounds.width / imageSize.width,
            fittedBounds.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: viewportBounds.midX - size.width * 0.5,
            y: viewportBounds.midY - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }
}

/// UIKit owns zoom physics, panning, centering, and double-tap behavior. At
/// minimum zoom the inner pan recognizer stands down so the surrounding native
/// page view can swipe between sibling photos. Once zoomed, panning belongs to
/// the photo until it returns to its fitted scale.
private struct NativeZoomableImagePreview: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    let onZoomStateChange: (Bool) -> Void

    func makeUIView(context: Context) -> ImageZoomScrollView {
        ImageZoomScrollView()
    }

    func updateUIView(_ scrollView: ImageZoomScrollView, context: Context) {
        scrollView.onZoomStateChange = onZoomStateChange
        scrollView.setImage(image, accessibilityLabel: accessibilityLabel)
    }
}

/// Gesture-phase state keeps the title hidden while a pinch bounces back to
/// fitted scale, revealing it only after the user lets go at 1x.
struct ImagePreviewZoomTitleState: Equatable {
    private(set) var isHidden = false

    mutating func zoomChanged(scale: CGFloat, minimumScale: CGFloat) -> Bool? {
        guard scale > minimumScale + 0.01, !isHidden else { return nil }
        isHidden = true
        return true
    }

    mutating func zoomEnded(scale: CGFloat, minimumScale: CGFloat) -> Bool? {
        let shouldHide = scale > minimumScale + 0.01
        guard shouldHide != isHidden else { return nil }
        isHidden = shouldHide
        return shouldHide
    }

    mutating func reset() -> Bool? {
        guard isHidden else { return nil }
        isHidden = false
        return false
    }
}

private final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onZoomStateChange: ((Bool) -> Void)?

    private let zoomContentView = UIView()
    private let imageView = UIImageView()
    private var viewportSize = CGSize.zero
    private var titleState = ImagePreviewZoomTitleState()

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
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous

        zoomContentView.backgroundColor = .clear
        addSubview(zoomContentView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 16
        imageView.layer.cornerCurve = .continuous
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityHint = "Pinch or double tap to zoom"
        zoomContentView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    func setImage(_ image: UIImage, accessibilityLabel: String) {
        guard imageView.image !== image || imageView.accessibilityLabel != accessibilityLabel else {
            return
        }
        setZoomScale(minimumZoomScale, animated: false)
        contentOffset = .zero
        imageView.image = image
        imageView.accessibilityLabel = accessibilityLabel
        reportTitleState(titleState.reset())
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
            reportTitleState(titleState.reset())
            updatePanOwnership()
        }
        imageView.frame = fittedImageFrame(in: zoomContentView.bounds)
        centerZoomContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomContentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerZoomContent()
        reportTitleState(titleState.zoomChanged(
            scale: zoomScale,
            minimumScale: minimumZoomScale
        ))
        let pinchState = pinchGestureRecognizer?.state
        let pinchIsActive = pinchState == .began || pinchState == .changed
        if !pinchIsActive, zoomScale <= minimumZoomScale + 0.01 {
            reportTitleState(titleState.zoomEnded(
                scale: zoomScale,
                minimumScale: minimumZoomScale
            ))
        }
        updatePanOwnership()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        reportTitleState(titleState.zoomEnded(
            scale: scale,
            minimumScale: minimumZoomScale
        ))
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportTitleState(titleState.zoomEnded(
            scale: zoomScale,
            minimumScale: minimumZoomScale
        ))
    }

    private func reportTitleState(_ changedState: Bool?) {
        guard let changedState else { return }
        onZoomStateChange?(changedState)
    }

    private func updatePanOwnership() {
        let isZoomed = zoomScale > minimumZoomScale + 0.01
        panGestureRecognizer.isEnabled = isZoomed
    }

    private func fittedImageFrame(in containerBounds: CGRect) -> CGRect {
        guard let image = imageView.image else {
            return containerBounds
        }
        return ImagePreviewViewportLayout.fittedImageFrame(
            imageSize: image.size,
            in: containerBounds
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

    @objc
    private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
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
        zoom(to: CGRect(
            x: location.x - targetSize.width * 0.5,
            y: location.y - targetSize.height * 0.5,
            width: targetSize.width,
            height: targetSize.height
        ), animated: true)
    }
}
