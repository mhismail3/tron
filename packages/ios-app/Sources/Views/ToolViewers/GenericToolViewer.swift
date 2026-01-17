import SwiftUI

// MARK: - Generic Result Viewer

struct GenericResultViewer: View {
    let result: String
    @Binding var isExpanded: Bool

    private var displayText: String {
        if isExpanded || result.count <= 500 {
            return result
        }
        return String(result.prefix(500)) + "..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if result.count > 500 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.system(size: 11, design: .monospaced))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tronTextMuted)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.tronSurface)
                }
            }
        }
    }
}
