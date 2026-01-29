import SwiftUI

// MARK: - Find Result Viewer (also used for Glob)
// Shows a list of matched file paths

struct FindResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    private var files: [String] {
        result.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File count header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.cyan)

                Text("\(files.count) files found")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // File list - show all
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { file in
                    HStack(spacing: 8) {
                        Image(systemName: fileIcon(for: file))
                            .font(TronTypography.codeSM)
                            .foregroundStyle(fileIconColor(for: file))
                            .frame(width: 14)

                        Text(file)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func fileIcon(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go":
            return "doc.text"
        case "json", "yaml", "yml", "xml":
            return "doc.badge.gearshape"
        case "md":
            return "doc.richtext"
        case "css", "scss":
            return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo"
        default:
            return "doc"
        }
    }

    private func fileIconColor(for path: String) -> Color {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        default: return .tronTextMuted
        }
    }
}

// MARK: - Search Tool Viewer
// Shows search results from unified Search tool (text + AST modes)
// Previously called GrepResultViewer

struct SearchToolViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    private var lines: [String] {
        result.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Match count header
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.purple)

                Text("\(lines.count) matches")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                if !pattern.isEmpty {
                    Text("for \"\(pattern)\"")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // Results - show all
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextSecondary)
                            .frame(minHeight: 16, alignment: .leading)
                            .padding(.leading, 8)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

