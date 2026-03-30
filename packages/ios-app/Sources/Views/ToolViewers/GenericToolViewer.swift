import SwiftUI

// MARK: - Generic Result Viewer

struct GenericResultViewer: View {
    let result: String

    var body: some View {
        LineNumberedContentView(
            content: result
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
