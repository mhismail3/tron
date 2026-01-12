import SwiftUI
import UIKit

/// Floating browser preview window that displays live browser frame streaming.
/// Draggable and resizable, with glass-morphism styling.
@available(iOS 26.0, *)
struct FloatingBrowserView: View {
    /// The latest browser frame image (decoded from base64 JPEG)
    let frameImage: UIImage?
    /// Current URL being displayed
    let currentUrl: String?
    /// Action to close the browser window
    let onClose: () -> Void

    /// Position offset for dragging
    @State private var offset: CGSize = .zero
    /// Accumulated offset from previous drags
    @State private var lastOffset: CGSize = .zero
    /// Current scale for resizing
    @State private var scale: CGFloat = 1.0
    /// Last scale from previous pinch
    @State private var lastScale: CGFloat = 1.0
    /// Whether the window is minimized
    @State private var isMinimized = false

    // Default size
    private let defaultWidth: CGFloat = 280
    private let defaultHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar

            // Browser content
            if !isMinimized {
                browserContent
            }
        }
        .frame(
            width: isMinimized ? 180 : defaultWidth * scale,
            height: isMinimized ? 44 : (defaultHeight * scale) + 44
        )
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .offset(x: offset.width + lastOffset.width, y: offset.height + lastOffset.height)
        .gesture(dragGesture)
        .gesture(magnificationGesture)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isMinimized)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: offset)
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Browser icon
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            // URL or status
            Text(urlDisplayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Minimize/expand button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isMinimized.toggle()
                }
            } label: {
                Image(systemName: isMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.primary.opacity(0.05))
    }

    private var browserContent: some View {
        Group {
            if let image = frameImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(Color.black)
            } else {
                // Placeholder when no frames yet
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.8))
            }
        }
    }

    private var urlDisplayText: String {
        if let url = currentUrl, !url.isEmpty {
            // Extract domain from URL
            if let urlObj = URL(string: url) {
                return urlObj.host ?? url
            }
            return url
        }
        return "Browser"
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = value.translation
            }
            .onEnded { value in
                lastOffset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = .zero
                snapToEdgeIfNeeded()
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(max(newScale, 0.5), 2.0)  // Limit scale between 0.5x and 2x
            }
            .onEnded { value in
                lastScale = scale
            }
    }

    private func snapToEdgeIfNeeded() {
        // Get screen bounds
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }

        let screenWidth = window.bounds.width
        let screenHeight = window.bounds.height
        let currentWidth = isMinimized ? 180 : defaultWidth * scale
        let currentHeight = isMinimized ? 44 : (defaultHeight * scale) + 44

        // Calculate current center position
        let centerX = screenWidth / 2 + lastOffset.width
        let centerY = screenHeight / 2 + lastOffset.height

        var newOffset = lastOffset

        // Snap to edges with margin
        let margin: CGFloat = 16

        // Horizontal snapping
        if centerX < screenWidth * 0.3 {
            // Snap to left
            newOffset.width = -(screenWidth / 2) + (currentWidth / 2) + margin
        } else if centerX > screenWidth * 0.7 {
            // Snap to right
            newOffset.width = (screenWidth / 2) - (currentWidth / 2) - margin
        }

        // Vertical snapping
        if centerY < screenHeight * 0.3 {
            // Snap to top
            newOffset.height = -(screenHeight / 2) + (currentHeight / 2) + margin + 60  // Account for safe area
        } else if centerY > screenHeight * 0.7 {
            // Snap to bottom
            newOffset.height = (screenHeight / 2) - (currentHeight / 2) - margin - 100  // Account for input bar
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            lastOffset = newOffset
        }
    }
}

// MARK: - Preview

#Preview {
    if #available(iOS 26.0, *) {
        ZStack {
            Color.black.opacity(0.8)

            FloatingBrowserView(
                frameImage: nil,
                currentUrl: "https://example.com",
                onClose: {}
            )
        }
    }
}
