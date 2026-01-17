import SwiftUI

// MARK: - Bash Result Viewer

struct BashResultViewer: View {
    let command: String
    let output: String
    @Binding var isExpanded: Bool

    private var lines: [String] {
        output.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        isExpanded ? lines : Array(lines.prefix(8))
    }

    /// Calculate optimal width for line numbers based on total lines
    private var lineNumWidth: CGFloat {
        let maxNum = lines.count
        let digits = String(maxNum).count
        return CGFloat(max(digits * 8, 14)) // ~8pt per digit, min 14pt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Output lines
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 0) {
                            // Line number
                            Text("\(index + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)

                            // Line content
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: isExpanded ? .infinity : 140)

            // Expand/collapse button
            if lines.count > 8 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more (\(lines.count) lines)")
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
