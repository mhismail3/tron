import SwiftUI

// MARK: - Generic Result Viewer

struct GenericResultViewer: View {
    let result: String
    @Binding var isExpanded: Bool

    var body: some View {
        LineNumberedContentView(
            content: result,
            maxCollapsedLines: 12,
            isExpanded: $isExpanded,
            maxCollapsedHeight: 200
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
