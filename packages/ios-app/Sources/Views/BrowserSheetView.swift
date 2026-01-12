import SwiftUI
import UIKit

/// Browser preview sheet that displays live browser screenshots.
/// Presented as a fixed-height sheet sized to the browser viewport.
@available(iOS 26.0, *)
struct BrowserSheetView: View {
    /// The latest browser frame image (decoded from base64)
    let frameImage: UIImage?
    /// Current URL being displayed
    let currentUrl: String?
    /// Whether browser is actively streaming
    let isStreaming: Bool
    /// Action to close the browser session
    let onCloseBrowser: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header bar
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                // Browser content - constrained to remaining space
                if let image = frameImage {
                    browserFrameView(image: image)
                        .frame(maxHeight: .infinity)
                } else {
                    loadingView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.tronSurface)
        .presentationDetents([.browserSheet])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(false)
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            // URL/title in center-left
            HStack(spacing: 8) {
                if isStreaming {
                    Circle()
                        .fill(.tronError)
                        .frame(width: 8, height: 8)
                }
                Text(urlDisplayText)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)
            }

            Spacer()

            // Close button (icon only)
            Button {
                onCloseBrowser()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tronTextMuted)
            }
        }
    }

    private func browserFrameView(image: UIImage) -> some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                .scaleEffect(1.5)

            Text("Waiting for browser...")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronTextMuted)

            Text("Screenshots will appear here when the agent uses browser tools")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tronTextMuted.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var urlDisplayText: String {
        if let url = currentUrl, !url.isEmpty {
            if let urlObj = URL(string: url) {
                return urlObj.host ?? "Browser"
            }
            return "Browser"
        }
        return "Browser"
    }
}

// MARK: - Custom Detent for Browser Sheet

@available(iOS 26.0, *)
extension PresentationDetent {
    /// Custom detent sized for browser viewport (roughly 60% of screen)
    static let browserSheet = Self.fraction(0.55)
}

// MARK: - Preview

#Preview {
    if #available(iOS 26.0, *) {
        BrowserSheetView(
            frameImage: nil,
            currentUrl: "https://example.com",
            isStreaming: true,
            onCloseBrowser: {}
        )
    }
}
