import SwiftUI

// MARK: - Computer Use Result Viewer

struct ComputerUseResultViewer: View {
    let result: String

    var body: some View {
        LineNumberedContentView(
            content: result,
            fontSize: 11,
            lineNumFontSize: 9,
            lineHeight: 16
        )
    }
}
