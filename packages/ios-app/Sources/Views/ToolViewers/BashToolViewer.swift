import SwiftUI

// MARK: - Bash Result Viewer

struct BashResultViewer: View {
    let command: String
    let output: String
    @Binding var isExpanded: Bool

    var body: some View {
        LineNumberedContentView(
            content: output,
            maxCollapsedLines: 8,
            isExpanded: $isExpanded,
            fontSize: 11,
            lineNumFontSize: 9,
            maxCollapsedHeight: 140,
            lineHeight: 16
        )
    }
}
