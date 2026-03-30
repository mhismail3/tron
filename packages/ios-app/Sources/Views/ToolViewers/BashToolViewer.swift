import SwiftUI

// MARK: - Bash Result Viewer

struct BashResultViewer: View {
    let command: String
    let output: String

    var body: some View {
        LineNumberedContentView(
            content: output,
            fontSize: 11,
            lineNumFontSize: 9,
            lineHeight: 16
        )
    }
}
