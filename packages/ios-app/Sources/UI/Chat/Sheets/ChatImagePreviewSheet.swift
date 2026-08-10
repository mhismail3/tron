import SwiftUI
import UIKit

/// Standard chat sheet for inspecting an image attachment without leaving the
/// conversation. The bytes are already local, while decoding remains off the
/// main actor so opening a large image cannot stall transcript interaction.
struct ChatImagePreviewSheet: View {
    let preview: ChatImagePreviewData

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        SettingsPageContainer(title: preview.title, scrollsContent: false) {
            GeometryReader { geometry in
                ZStack {
                    if let image {
                        NativeZoomableImagePreview(
                            image: image,
                            accessibilityLabel: preview.accessibilityLabel
                        )
                        .transition(.opacity)
                    } else if didFail {
                        unavailableState
                    } else {
                        SheetLoadingState(label: "Loading photo…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .task(id: preview.id) {
                    await loadImage(fitting: geometry.size)
                }
            }
        }
        .adaptivePresentationDetents([.large], ipadSizing: .largeForm)
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

    @MainActor
    private func loadImage(fitting availableSize: CGSize) async {
        didFail = false
        image = nil
        let boundedSize = CGSize(
            width: max(availableSize.width, 320),
            height: max(availableSize.height, 320)
        )
        let decoded = await DecodedImageView.decodeImage(
            preview.data,
            fitting: boundedSize,
            scale: min(max(displayScale, 1), 3)
        )
        guard !Task.isCancelled else { return }
        if reduceMotion {
            image = decoded
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                image = decoded
            }
        }
        didFail = decoded == nil
    }
}

/// UIKit owns zoom physics, panning, centering, and double-tap behavior. This
/// gives the preview native gesture arbitration inside SwiftUI's sheet rather
/// than maintaining a second hand-written gesture state machine.
private struct NativeZoomableImagePreview: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String

    func makeUIView(context: Context) -> ImageZoomScrollView {
        ImageZoomScrollView()
    }

    func updateUIView(_ scrollView: ImageZoomScrollView, context: Context) {
        scrollView.setImage(image, accessibilityLabel: accessibilityLabel)
    }
}

private final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let zoomContentView = UIView()
    private let imageView = UIImageView()
    private var viewportSize = CGSize.zero

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

        zoomContentView.backgroundColor = .clear
        addSubview(zoomContentView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
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
        imageView.image = image
        imageView.accessibilityLabel = accessibilityLabel
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
            imageView.frame = zoomContentView.bounds
            contentSize = bounds.size
        }
        centerZoomContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        zoomContentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerZoomContent()
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
