import SwiftUI

// MARK: - Computer Use Result Viewer

struct ComputerUseResultViewer: View {
    let result: String
    @Binding var isExpanded: Bool

    var body: some View {
        LineNumberedContentView(
            content: result,
            maxCollapsedLines: 6,
            isExpanded: $isExpanded,
            fontSize: 11,
            lineNumFontSize: 9,
            maxCollapsedHeight: 100,
            lineHeight: 16
        )
    }
}
