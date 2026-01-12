import SwiftUI
import UIKit

/// Browser preview sheet that displays live browser screenshots.
/// Presented as a medium-height sheet, dismissible by swipe.
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
        NavigationStack {
            ZStack {
                Color.tronSurface.ignoresSafeArea()

                if let image = frameImage {
                    // Browser frame display
                    browserFrameView(image: image)
                } else {
                    // Loading/connecting state
                    loadingView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        // Live indicator
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCloseBrowser()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                            Text("Close")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.tronError)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private func browserFrameView(image: UIImage) -> some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
        }
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
            // Extract domain from URL
            if let urlObj = URL(string: url) {
                return urlObj.host ?? "Browser"
            }
            return "Browser"
        }
        return "Browser"
    }
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
