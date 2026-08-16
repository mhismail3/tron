import SwiftUI

struct ExtensionWidgetView: View {
    let widget: ExtensionWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(TronFont.mono(12)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.10)
        .padding(.horizontal, 12)
    }
}
