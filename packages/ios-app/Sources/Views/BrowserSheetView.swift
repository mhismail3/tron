import SwiftUI
import UIKit

/// Browser preview sheet that displays live browser screenshots.
@available(iOS 26.0, *)
struct BrowserSheetView: View {
    let frameImage: UIImage?
    let currentUrl: String?
    let isStreaming: Bool
    let onCloseBrowser: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var urlDisplayText: String {
        if let url = currentUrl, !url.isEmpty,
           let urlObj = URL(string: url) {
            return urlObj.host ?? "Browser"
        }
        return "Browser"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image = frameImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding()
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                            .scaleEffect(1.5)
                        Text("Waiting for browser...")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if isStreaming {
                            Circle()
                                .fill(.tronError)
                                .frame(width: 8, height: 8)
                        }
                        Text(urlDisplayText)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCloseBrowser()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

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
