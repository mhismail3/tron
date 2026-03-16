import SwiftUI

// MARK: - Browse The Web Tool Viewer
// Updated name: BrowseTheWebTool (was AgentWebBrowser)

struct BrowserToolViewer: View {
    let action: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(result)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


