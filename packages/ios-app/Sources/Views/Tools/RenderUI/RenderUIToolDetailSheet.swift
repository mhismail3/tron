import SwiftUI

/// Tool detail sheet for RenderUI showing the rendered web content.
@available(iOS 26.0, *)
struct RenderUIToolDetailSheet: View {
    let toolCallId: String
    let arguments: [String: Any]?
    let output: String?
    let status: ToolStatus
    let duration: TimeInterval?

    private var canvasId: String? {
        arguments?["canvasId"] as? String
    }

    private var title: String? {
        arguments?["title"] as? String
    }

    private var url: String? {
        if let details = arguments?["_details"] as? [String: Any] {
            return details["url"] as? String
        }
        return nil
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "RenderUI",
            iconName: "rectangle.on.rectangle",
            accent: .tronEmerald
        ) {
            VStack(spacing: 16) {
                if let urlStr = url, let url = URL(string: urlStr) {
                    WebViewWrapper(url: url)
                        .frame(minHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let canvasId {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Canvas: \(canvasId)")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
        }
    }
}
